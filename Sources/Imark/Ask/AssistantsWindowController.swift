import AppKit

/// Settings ▸ Assistants…: who Ask can send a question to.
///
/// The command-line agents are found, not added: Claude Code and Codex show up
/// here once they are installed, and only their model (and Claude Code's
/// spending cap) are Imark's to set.
/// An API is added from a short list of the usual addresses; its key goes into
/// the Keychain and the field never shows it again. Its model is typed, or
/// picked from the list Get Models fetched from the server.
///
/// The window edits a copy, and only Save writes it: settings, keys, removed
/// assistants. Cancel, Escape or the close button with something changed ask
/// first. Written as each field was left, Escape after typing in the model
/// field kept what was typed.
final class AssistantsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSComboBoxDelegate {
    static let shared = AssistantsWindowController()

    private let table = NSTableView()
    private let detail = NSView()
    private let remove = NSButton()
    private var list: [Assistant] = []
    private var selectedID: String?

    /// The assistants as they were saved when the window took them, and the
    /// copy it edits. What differs is what Save writes; the rest is left to
    /// whatever changed it meanwhile.
    private var saved: [Assistant] = []
    private var draft: [Assistant] = []
    /// Keys typed, by assistant, for the Keychain on Save.
    private var typedKeys: [String: String] = [:]
    /// Saved assistants removed in the window, whose keys go on Save.
    private var removedIDs: Set<String> = []
    private(set) var discardSheet: DiscardSheet?
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Whose fields are on the right. Not always the selection: selecting a
    /// row in code tells the table first, and a commit then would write one
    /// assistant's fields into the next — adding an API while another was
    /// shown gave the new one the old one's name and address.
    private var shownID: String?

    // The fields of the assistant on the right. Rebuilt with the selection;
    // readable by the tests.
    private var titleField: NSTextField?
    /// The line under the name: what it is, or for an agent, what is missing.
    private var headingNote: NSTextField?
    private(set) var nameField: NSTextField?
    private(set) var addressField: NSTextField?
    private(set) var keyField: NSSecureTextField?
    /// Claude Code's model, from the names it takes.
    private var modelBox: NSComboBox?
    /// An API's model, typed or picked from the list under it.
    private(set) var modelField: NSTextField?
    private(set) var suggestions = SuggestionList()
    private(set) var modelNote: NSTextField?
    private(set) var getModelsButton: NSButton?
    private var toolsNote: NSTextField?
    private(set) var capField: NSTextField?
    /// A command-line agent's executable, and what running it said.
    private(set) var pathField: NSTextField?
    private(set) var pathNote: NSTextField?
    /// `--version` of each path tried, "" while it runs, nil when it did not
    /// answer.
    private var versions: [String: String?] = [:]
    private(set) var contextField: NSTextField?
    private var toolsPopup: NSPopUpButton?
    private var enabledBox: NSButton?

    // The lists Get Models fetched, by assistant, read from the cache once;
    // what went wrong the last time; which are on their way.
    private var lists: [String: ModelCatalog.Saved] = [:]
    private var looked: Set<String> = []
    private var failures: [String: String] = [:]
    private var loading: Set<String> = []
    /// What the list under the model field shows: every model, or the ones
    /// matching what is being typed.
    private(set) var shownModels: [ModelInfo] = []
    private var modelFilter = ""
    private var clickMonitor: Any?

    private struct Preset {
        let name: String
        let kind: Assistant.Kind
        let address: String
        let model: String
    }

    private let presets = [
        Preset(name: "OpenAI", kind: .openAI, address: "https://api.openai.com/v1", model: ""),
        Preset(name: "OpenRouter", kind: .openAI, address: "https://openrouter.ai/api/v1", model: ""),
        Preset(name: "LM Studio", kind: .openAI, address: "http://localhost:1234/v1", model: ""),
        Preset(name: "Ollama", kind: .openAI, address: "http://localhost:11434/v1", model: ""),
        Preset(name: "Other OpenAI-compatible API", kind: .openAI, address: "", model: ""),
        Preset(name: "Anthropic API", kind: .anthropic, address: AnthropicTransport.defaultBaseURL, model: ""),
    ]

    private init() {
        let window = AssistantsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Assistants"
        window.minSize = NSSize(width: 720, height: 500)
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.cancel() }
        window.onSave = { [weak self] in self?.save() }
        window.listIsOpen = { [weak self] in self?.suggestions.isOpen == true }
        build()
        load()
        window.center()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clicked(event)
            return event
        }
        suggestions.onPick = { [weak self] item in self?.pickModel(item.value) }
        suggestions.describe = { [weak self] item in
            self?.shownModels.first { $0.id == item.value }.flatMap(ModelCatalog.summary(of:))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillCloseSomewhere(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Over the window it was asked from, Settings or a document's Ask panel,
    /// as a child window: kept above that window and moved with it, the way
    /// Settings sits over the document. It opened in the middle of the screen
    /// and stayed there, wherever Settings went.
    static func show(over parent: NSWindow? = nil) {
        // Already open, with changes perhaps: brought forward as it is, not
        // read again over them, and not moved. Open is not the same as on
        // screen: a child goes when its parent is minimised.
        if !shared.isOpen {
            shared.load()
            if let parent { shared.centre(over: parent) }
        }
        shared.showWindow(nil)
        shared.isOpen = true
        shared.sit(over: parent)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var isOpen = false

    private func sit(over parent: NSWindow?) {
        guard let window, window.parent !== parent else { return }
        window.parent?.removeChildWindow(window)
        parent?.addChildWindow(window, ordered: .above)
    }

    private func centre(over parent: NSWindow) {
        guard let window else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2,
                                      y: parent.frame.midY - size.height / 2))
    }

    /// Closing a window orders its child windows out without closing them, and
    /// this one would go with Settings or the document, still open, with its
    /// changes in it and nothing on screen to save them from. It moves to the
    /// document in front, or stays on its own.
    @objc private func windowWillCloseSomewhere(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing !== window,
              closing === window?.parent else { return }
        sit(over: NSApp.orderedWindows.first {
            $0 !== closing && $0.isVisible && $0.windowController is DocumentWindowController
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasChanges else { return true }
        confirmDiscard()
        return false
    }

    /// Whatever was not saved goes with the window.
    func windowWillClose(_ notification: Notification) {
        suggestions.close()
        load()
        isOpen = false
        sit(over: nil)
    }

    func windowDidResignKey(_ notification: Notification) { suggestions.close() }

    // MARK: - Layout

    private func build() {
        let column = NSTableColumn(identifier: .init("assistant"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add an assistant")!, target: self, action: #selector(addPressed(_:)))
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove the assistant")
        remove.target = self
        remove.action = #selector(removePressed)
        for button in [add, remove] {
            button.bezelStyle = .smallSquare
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0

        let sidebar = NSStackView(views: [scroll, buttons])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true

        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: effect.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let root = NSView()
        for view in [effect, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: 220),
            detail.leadingAnchor.constraint(equalTo: effect.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        for button in [cancelButton, saveButton] {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        }
        let actions = NSStackView(views: [cancelButton, saveButton])
        actions.spacing = 12
        actions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        window?.contentView = root
    }

    /// What clicking a row in the list does; for the tests.
    func select(_ id: String) {
        guard let row = list.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Takes the assistants as they are saved, dropping whatever the window
    /// had not saved.
    private func load() {
        // The fields on show belong to what is being dropped: let go of them
        // first, or the table reloading below commits them into the new copy.
        shownID = nil
        window?.endEditing(for: nil)
        saved = Assistants.all
        draft = saved
        typedKeys = [:]
        removedIDs = []
        reload()
    }

    /// The assistant as the window has it; for the tests too.
    func entry(_ id: String) -> Assistant? { draft.first { $0.id == id } }

    /// The one on the right; for the tests.
    var shown: Assistant? { selectedEntry }

    private func reload() {
        list = draft
        table.reloadData()
        let index = list.firstIndex { $0.id == selectedID } ?? (list.isEmpty ? nil : 0)
        if let index {
            table.selectRowIndexes([index], byExtendingSelection: false)
            selectedID = list[index].id
        } else {
            selectedID = nil
        }
        showDetail()
    }

    // MARK: - The list

    func numberOfRows(in tableView: NSTableView) -> Int { list.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = list[row]
        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: subtitle(for: entry))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let symbol = entry.kind.isCommandLine ? "terminal" : entry.isLocal ? "laptopcomputer" : "cloud"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        let usable = entry.enabled && entry.isInstalled
        image.contentTintColor = usable ? .secondaryLabelColor : .tertiaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [image, text])
        row.spacing = 8
        row.alphaValue = usable ? 1 : 0.55
        return row
    }

    private func subtitle(for entry: Assistant) -> String {
        switch entry.kind {
        case .claudeCode, .codex:
            guard entry.isInstalled, let path = entry.path else { return "Not set up" }
            return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .openAI, .anthropic:
            let host = URL(string: entry.baseURL)?.host ?? "No address"
            let key = typedKeys[entry.id] != nil ? "new key, not saved yet"
                : Keychain.hasKey(for: entry.id) ? "key in Keychain"
                : entry.isLocal ? "no key" : "needs a key"
            return "\(host) · \(key)"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        commit()
        let row = table.selectedRow
        selectedID = list.indices.contains(row) ? list[row].id : nil
        showDetail()
    }

    // MARK: - The detail

    private func showDetail() {
        // The fields let go of their assistant before they go: a field being
        // typed in ends its editing as it is taken away, and that commit wrote
        // the old text into the copy just read again — "foo", after Discard.
        shownID = nil
        window?.endEditing(for: nil)
        detail.subviews.forEach { $0.removeFromSuperview() }
        titleField = nil; headingNote = nil; nameField = nil; addressField = nil; keyField = nil
        suggestions.close()
        modelBox = nil; modelField = nil; modelNote = nil; getModelsButton = nil
        toolsNote = nil; capField = nil; contextField = nil; pathField = nil; pathNote = nil
        toolsPopup = nil; enabledBox = nil
        modelFilter = ""
        shownModels = []
        remove.isEnabled = false
        guard let id = selectedID, let entry = list.first(where: { $0.id == id }) else {
            let empty = NSTextField(labelWithString: "Add an assistant with +.")
            empty.textColor = .secondaryLabelColor
            place(NSStackView(views: [empty]))
            return
        }
        remove.isEnabled = !entry.kind.isCommandLine
        shownID = entry.id

        let title = NSTextField(labelWithString: entry.name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField = title
        let installed = entry.isInstalled
        let subtitle = NSTextField(wrappingLabelWithString: !entry.kind.isCommandLine
            ? (entry.kind == .anthropic ? "Anthropic's Messages API." : "An OpenAI-compatible API.")
            : installed ? "Signed in through \(entry.name). Imark keeps no key for it."
            : "Not set up. \(Assistants.installHint(for: entry.kind))")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = installed ? .secondaryLabelColor : .systemOrange
        subtitle.preferredMaxLayoutWidth = 420
        subtitle.isSelectable = true
        headingNote = subtitle
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        let enabled = NSButton(checkboxWithTitle: "Use for Ask", target: self, action: #selector(fieldChanged))
        enabled.state = entry.enabled ? .on : .off
        enabledBox = enabled

        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        @discardableResult
        func row(_ label: String, _ control: NSView, note: String? = nil) -> NSTextField? {
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            var cell: NSView = control
            var hintLabel: NSTextField?
            if let note {
                let hint = NSTextField(wrappingLabelWithString: note)
                hint.font = .systemFont(ofSize: 11)
                hint.textColor = .secondaryLabelColor
                hint.preferredMaxLayoutWidth = 280
                hintLabel = hint
                let stack = NSStackView(views: [control, hint])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                cell = stack
            }
            let added = grid.addRow(with: [caption, cell])
            added.rowAlignment = .firstBaseline
            return hintLabel
        }
        func field(_ value: String, placeholder: String, width: CGFloat = 260) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }

        row("", enabled)
        switch entry.kind {
        case .claudeCode, .codex:
            let path = field(entry.path ?? "", placeholder: "Path to the \(entry.kind.command ?? "") executable", width: 280)
            // The end of a path says what it is: `…/bin/codex`.
            path.lineBreakMode = .byTruncatingMiddle
            path.toolTip = entry.path
            pathField = path
            let choose = NSButton(title: "Choose…", target: self, action: #selector(choosePath))
            let line = NSStackView(views: [path, choose])
            line.spacing = 8
            pathNote = row("Executable", line, note: " ")
            let box = NSComboBox()
            box.addItems(withObjectValues: Assistants.suggestedModels(for: entry.kind))
            box.stringValue = entry.model
            box.placeholderString = "\(entry.name)'s default"
            box.delegate = self
            box.target = self
            box.action = #selector(fieldChanged)
            box.widthAnchor.constraint(equalToConstant: 200).isActive = true
            modelBox = box
            row("Model", box)
            // Only Claude Code can be told to stop at a sum.
            if entry.kind == .claudeCode {
                let cap = field(entry.spendingCap.map { String(format: "%.2f", $0) } ?? "", placeholder: "No cap", width: 80)
                cap.formatter = NumberFieldFormatter(decimals: true)
                capField = cap
                row("Spending cap", cap, note: "US dollars per question, as Claude Code counts them. On a subscription it is an estimate, not a bill.")
            }
            row("Can read", NSTextField(labelWithString: "The document it is asked about"),
                note: entry.kind == .codex
                    ? "Its shell and web search are off and its sandbox is read-only: it can see the headings, read lines and search, in that one document only. Your ~/.codex/AGENTS.md still applies."
                    : "Its own tools are off. It can see the headings, read lines and search, in that one document only.")
        case .openAI, .anthropic:
            let name = field(entry.name, placeholder: "Name")
            nameField = name
            row("Name", name)
            let address = field(entry.baseURL, placeholder: entry.kind == .anthropic ? AnthropicTransport.defaultBaseURL : "https://…/v1")
            addressField = address
            row("Address", address)
            let key = NSSecureTextField()
            key.placeholderString = typedKeys[entry.id] != nil ? "New key, kept when you save"
                : Keychain.hasKey(for: entry.id) ? "Stored in the Keychain"
                : entry.isLocal ? "Not needed on this Mac" : "Paste the key"
            key.delegate = self
            key.widthAnchor.constraint(equalToConstant: 260).isActive = true
            keyField = key
            row("API key", key, note: "Kept in the Keychain, never in the settings. Leave empty to keep the one stored.")
            let model = field(entry.model, placeholder: "Pick or type a model", width: 280)
            modelField = model
            let getModels = NSButton(title: "Get Models", target: self, action: #selector(getModels))
            getModels.toolTip = "Ask the server which models it has. Press again to bring the list up to date."
            getModelsButton = getModels
            let line = NSStackView(views: [model, getModels])
            line.spacing = 8
            modelNote = row("Model", line, note: " ")
            let tools = NSPopUpButton()
            for value in Assistant.Tools.allCases { tools.addItem(withTitle: value.label) }
            tools.selectItem(at: Assistant.Tools.allCases.firstIndex(of: entry.tools) ?? 0)
            tools.target = self
            tools.action = #selector(fieldChanged)
            toolsPopup = tools
            toolsNote = row("Tools", tools, note: toolsText(for: entry))
            let context = field(entry.contextWindow.map(String.init) ?? "", placeholder: "Unknown", width: 100)
            context.formatter = NumberFieldFormatter(decimals: false)
            contextField = context
            row("Context", context, note: "In tokens. Decides whether a model without tools can be given the whole document.")
        }
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [heading, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        place(stack)

        if entry.kind.isCommandLine {
            updatePathNote()
        } else {
            refilter()
            updateModelState()
        }
    }

    // MARK: - An agent's executable

    /// The line under the path: what the executable says it is, or why there
    /// is nothing to run.
    private func updatePathNote() {
        guard let note = pathNote, let field = pathField, let entry = selectedEntry else { return }
        let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        field.toolTip = path.isEmpty ? nil : path
        let runnable = !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
        headingNote?.stringValue = runnable
            ? "Signed in through \(entry.name). Imark keeps no key for it."
            : "Not set up. \(Assistants.installHint(for: entry.kind))"
        headingNote?.textColor = runnable ? .secondaryLabelColor : .systemOrange
        var colour = NSColor.secondaryLabelColor
        if path.isEmpty {
            note.stringValue = "Not set: choose the executable."
            colour = .systemOrange
        } else if !FileManager.default.isExecutableFile(atPath: path) {
            note.stringValue = "Nothing can be run at this path."
            colour = .systemRed
        } else {
            switch versions[path] {
            case .none:
                note.stringValue = "Checking…"
                probe(path)
            case .some(.some(let version)) where version.isEmpty:
                note.stringValue = "Checking…"
            case .some(.some(let version)):
                note.stringValue = version
            case .some(.none):
                note.stringValue = "It did not say what it is to `--version`. Check that this is \(entry.name)."
                colour = .systemOrange
            }
        }
        note.textColor = colour
    }

    /// Runs `--version` once per path, off the main thread.
    private func probe(_ path: String) {
        versions[path] = .some("")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let version = Assistants.version(of: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                self?.versions[path] = .some(version)
                self?.updatePathNote()
            }
        }
    }

    /// Choose…: the executable itself, or an app with it inside.
    @objc private func choosePath() {
        guard let window, let entry = selectedEntry, let command = entry.kind.command else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the \(command) executable, or an app that has it inside."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.usePath(url, for: entry)
        }
    }

    /// Takes a chosen file, or the agent's command inside a chosen app; for
    /// the tests too.
    func usePath(_ url: URL, for entry: Assistant) {
        guard let command = entry.kind.command, let field = pathField, shownID == entry.id else { return }
        var chosen = url
        if url.pathExtension == "app" {
            guard let inside = Assistants.bundledExecutable(in: url, named: command) else {
                pathNote?.stringValue = "There is no `\(command)` inside \(url.lastPathComponent). Choose the executable itself."
                pathNote?.textColor = .systemRed
                return
            }
            chosen = inside
        }
        field.stringValue = chosen.path
        commit()
    }

    private func toolsText(for entry: Assistant) -> String {
        entry.tools == .auto && entry.refusesTools
            ? "This model takes no tools, so it is given the document itself instead."
            : "Lets the model search and read the document. A model that cannot is given the document itself."
    }

    private func place(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor, constant: -24),
            view.topAnchor.constraint(equalTo: detail.topAnchor, constant: 20),
            // Clear of Cancel and Save.
            view.bottomAnchor.constraint(lessThanOrEqualTo: detail.bottomAnchor, constant: -64),
        ])
    }

    // MARK: - Saving

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === modelField {
            suggestions.close()
            modelFilter = ""
            refilter()
        }
        commit()
    }

    @objc private func fieldChanged() { commit() }

    /// Writes what the fields say into the window's copy of the assistant on
    /// the right. A key is only taken when something was typed: the field
    /// starts empty on purpose.
    private func commit() {
        guard let id = shownID, var entry = entry(id) else { return }
        let before = entry
        if let enabledBox { entry.enabled = enabledBox.state == .on }
        if let modelBox { entry.model = modelBox.stringValue.trimmingCharacters(in: .whitespaces) }
        if let modelField { entry.model = modelField.stringValue.trimmingCharacters(in: .whitespaces) }
        if let capField {
            let value = Double(capField.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            entry.spendingCap = value.flatMap { $0 > 0 ? $0 : nil }
        }
        if let nameField, !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        }
        if let addressField {
            let address = Assistants.normalizedAddress(addressField.stringValue, kind: entry.kind)
            if address != addressField.stringValue { addressField.stringValue = address }
            entry.baseURL = address
        }
        // Added as "Other", it is named after its address until it is named.
        if entry.name == "API", entry.baseURL != before.baseURL, let host = URL(string: entry.baseURL)?.host {
            entry.name = ["api.", "www."].reduce(host) { $0.hasPrefix($1) ? String($0.dropFirst($1.count)) : $0 }
            nameField?.stringValue = entry.name
            titleField?.stringValue = entry.name
        }
        if let toolsPopup, Assistant.Tools.allCases.indices.contains(toolsPopup.indexOfSelectedItem) {
            let tools = Assistant.Tools.allCases[toolsPopup.indexOfSelectedItem]
            // Asked for again by hand: forget what was found out.
            if tools != entry.tools { entry.refusesTools = false }
            entry.tools = tools
        }
        if let contextField { entry.contextWindow = Int(contextField.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
        if let pathField {
            let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
            entry.path = path.isEmpty ? nil : (path as NSString).expandingTildeInPath
        }
        if !entry.kind.isCommandLine, entry.model != before.model {
            // What the list says about the new model replaces what was set for
            // the old one, and a refusal of tools was the old model's.
            let known = listed(entry.model, for: entry)
            if let window = known?.contextWindow {
                entry.contextWindow = window
            } else if let old = listed(before.model, for: before)?.contextWindow, entry.contextWindow == old {
                entry.contextWindow = nil
            }
            contextField?.stringValue = entry.contextWindow.map(String.init) ?? ""
            entry.refusesTools = known?.takesTools == false
        }
        if let keyField, !keyField.stringValue.isEmpty {
            typedKeys[id] = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            keyField.stringValue = ""
            keyField.placeholderString = "New key, kept when you save"
            // What went wrong with the old key, or the old address, is past.
            failures[id] = nil
        }
        if entry.baseURL != before.baseURL { failures[id] = nil }
        if entry != before, let index = draft.firstIndex(where: { $0.id == id }) { draft[index] = entry }
        list = draft
        let row = table.selectedRow
        if list.indices.contains(row) { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
        guard !entry.kind.isCommandLine else { return updatePathNote() }
        refilter()
        updateModelState()
    }

    // MARK: - The models an API lists

    private var selectedEntry: Assistant? { shownID.flatMap(entry) }

    /// The assistant on the right with the address its field says now, typed
    /// out or not: the model field and Get Models follow it as it is typed.
    private var liveEntry: Assistant? {
        guard var entry = selectedEntry else { return nil }
        if let addressField { entry.baseURL = Assistants.normalizedAddress(addressField.stringValue, kind: entry.kind) }
        return entry
    }

    /// The list fetched for this assistant, when it came from the address it
    /// has: another server's models are no use here.
    private func models(for entry: Assistant) -> [ModelInfo]? {
        if looked.insert(entry.id).inserted, lists[entry.id] == nil { lists[entry.id] = ModelCatalog.saved(for: entry.id) }
        guard let saved = lists[entry.id], saved.address == entry.baseURL else { return nil }
        return saved.models
    }

    private func listed(_ model: String, for entry: Assistant) -> ModelInfo? {
        models(for: entry)?.first { $0.id == model }
    }

    /// Get Models: asks the server for its models, with the address and key
    /// the fields hold, and keeps the list for the field to complete from.
    /// Nothing is asked of a server unless this is pressed.
    @objc private func getModels() {
        // What was typed into the address or the key counts, finished or not.
        window?.makeFirstResponder(nil)
        commit()
        guard let entry = selectedEntry, !entry.kind.isCommandLine, !loading.contains(entry.id) else { return }
        // A key typed and not saved yet is the one to try.
        let secret = typedKeys[entry.id] ?? Keychain.key(for: entry.id)
        guard let request = ModelCatalog.request(for: entry, key: secret) else { return updateModelState() }
        let sentKey = !(secret ?? "").isEmpty
        loading.insert(entry.id)
        failures[entry.id] = nil
        updateModelState()
        Task { @MainActor [weak self] in
            let result: Result<[ModelInfo], Error>
            do {
                result = .success(try await ModelCatalog.fetch(request))
            } catch {
                result = .failure(error)
            }
            self?.modelsArrived(result, for: entry, sentKey: sentKey)
        }
    }

    private func modelsArrived(_ result: Result<[ModelInfo], Error>, for entry: Assistant, sentKey: Bool) {
        loading.remove(entry.id)
        switch result {
        case .success(let models):
            let saved = ModelCatalog.Saved(address: entry.baseURL, fetched: Date(), models: models)
            lists[entry.id] = saved
            ModelCatalog.save(saved, for: entry.id)
        case .failure(let error):
            // The list from before stays; the note says what went wrong.
            failures[entry.id] = ModelCatalog.message(for: error, assistant: entry, sentKey: sentKey)
        }
        guard shownID == entry.id, let field = modelField else { return }
        // A server with one model, as LM Studio or Ollama often is: that is the one.
        if case .success(let models) = result, models.count == 1,
           field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, field.currentEditor() == nil {
            field.stringValue = models[0].id
            commit()
        }
        refilter()
        updateModelState()
    }

    private func refilter() {
        let all = liveEntry.flatMap(models(for:)) ?? []
        shownModels = ModelCatalog.matching(modelFilter, in: all)
        suggestions.summary = modelFilter.isEmpty
            ? "\(count(all.count)) on the server"
            : "\(shownModels.count) of \(count(all.count)) match"
        suggestions.items = shownModels.map { model in
            // Sorted by the name after the last slash, so that is what reads
            // first; where it comes from and how much it holds, after.
            let name = Assistants.shortModel(model.id)
            let provider = String(model.id.dropLast(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let detail = [provider.isEmpty ? nil : provider, model.contextWindow.map(ModelCatalog.tokens)].compactMap { $0 }
            return SuggestionList.Item(value: model.id, title: name, detail: detail.joined(separator: " · "))
        }
    }

    /// A click in the model field opens its list, all of it, with the model it
    /// holds marked; a click anywhere else in the window closes it. After the
    /// click is done with, when the field is the first responder.
    private func clicked(_ event: NSEvent) {
        guard event.window === window else { return }
        guard let field = modelField, field.isEnabled,
              field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return suggestions.close() }
        guard !suggestions.isOpen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.modelField === field else { return }
            self.modelFilter = ""
            self.refilter()
            self.suggestions.open(under: field, marking: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A model taken from the list, with Return or a click.
    private func pickModel(_ id: String) {
        guard let field = modelField else { return }
        if let editor = field.currentEditor() {
            editor.string = id
            editor.selectedRange = NSRange(location: (id as NSString).length, length: 0)
        } else {
            field.stringValue = id
        }
        modelFilter = ""
        refilter()
        commit()
    }

    private func count(_ models: Int) -> String { models == 1 ? "1 model" : "\(models) models" }

    /// The model field, Get Models and the line under them, from the address
    /// as it is typed and what the last list said.
    private func updateModelState(typing: Bool = false) {
        guard let entry = liveEntry, !entry.kind.isCommandLine, let field = modelField, let note = modelNote else { return }
        let hasAddress = ModelCatalog.request(for: entry, key: nil) != nil
        let isLoading = loading.contains(entry.id)
        field.isEnabled = hasAddress
        getModelsButton?.isEnabled = hasAddress && !isLoading
        let models = self.models(for: entry)
        let model = field.stringValue.trimmingCharacters(in: .whitespaces)
        var colour = NSColor.secondaryLabelColor
        let text: String
        if !hasAddress {
            text = "Enter the server's address first."
        } else if isLoading {
            text = "Getting the models…"
        } else if let models, typing {
            text = shownModels.isEmpty ? "None of the \(count(models.count)) match." : "\(shownModels.count) of \(count(models.count)) match."
        } else if let failure = failures[entry.id] {
            text = failure
            colour = .systemRed
        } else if let models {
            if models.isEmpty {
                text = "The server lists no models. Type the model's name."
            } else if model.isEmpty {
                text = "\(count(models.count)) on the server. Click the field to pick one, or type to narrow the list."
            } else if let info = models.first(where: { $0.id == model }) {
                text = ModelCatalog.summary(of: info) ?? "One of the \(count(models.count)) on the server."
            } else {
                text = "Not among the \(count(models.count)) on the server. Check the name."
                colour = .systemOrange
            }
        } else if lists[entry.id] != nil {
            text = "The list is from another address. Get the models again."
        } else {
            text = "Get the models from the server, or type the name."
        }
        note.stringValue = text
        note.textColor = colour
        toolsNote?.stringValue = toolsText(for: entry)
    }

    // MARK: - Typing a model

    /// Typing narrows the list and opens it, so the models to pick from are
    /// under the field while the name is typed.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === pathField { return updatePathNote() }
        if field === addressField {
            refilter()
            return updateModelState()
        }
        guard field === modelField else { return }
        modelFilter = field.stringValue
        refilter()
        suggestions.open(under: field)
        updateModelState(typing: true)
    }

    /// The arrows, Return and Escape go to the list while it is open; ↓ opens
    /// it. Otherwise Return in any field is Save, and Escape goes on up to the
    /// window, which takes it as Cancel.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let field = modelField, control === field, suggestions.handle(selector, in: field) { return true }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        save()
        return true
    }

    // MARK: - Save and Cancel

    /// Whether anything in the window differs from what is saved, the field
    /// being typed in included.
    var hasChanges: Bool {
        commit()
        return draft != saved || !typedKeys.isEmpty
    }

    /// Save: the window's copy becomes the settings, typed keys go into the
    /// Keychain, and removed assistants take their keys and lists with them.
    /// An assistant left alone here keeps whatever was written to it
    /// meanwhile — a model picked under a question, a refusal of tools found
    /// out — rather than the copy taken when the window opened.
    @objc func save() {
        window?.makeFirstResponder(nil)
        commit()
        let now = Assistants.all
        var result = draft.map { entry -> Assistant in
            guard let before = saved.first(where: { $0.id == entry.id }), before == entry,
                  let current = now.first(where: { $0.id == entry.id }) else { return entry }
            return current
        }
        result += now.filter { current in
            !saved.contains { $0.id == current.id } && !draft.contains { $0.id == current.id }
        }
        for id in removedIDs {
            Keychain.removeKey(for: id)
            ModelCatalog.forget(id)
        }
        for (id, key) in typedKeys where result.contains(where: { $0.id == id }) {
            Keychain.setKey(key, for: id)
        }
        Assistants.all = result
        load()
        window?.close()
    }

    /// Cancel, Escape and the close button: straight out when nothing
    /// changed, otherwise asked first.
    @objc func cancel() {
        window?.performClose(nil)
    }

    private func confirmDiscard() {
        guard let window, window.attachedSheet == nil else { return }
        suggestions.close()
        let sheet = DiscardSheet { [weak self] discard in
            self?.discardSheet = nil
            if discard { self?.discard() }
        }
        discardSheet = sheet
        window.beginSheet(sheet.window)
    }

    /// Discard Changes: back to what is saved, and the window goes.
    private func discard() {
        // Lists fetched for assistants that were never saved go with them.
        for entry in draft where !saved.contains(where: { $0.id == entry.id }) { ModelCatalog.forget(entry.id) }
        load()
        window?.close()
    }

    // MARK: - Adding and removing

    @objc private func addPressed(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, preset) in presets.enumerated() {
            if preset.kind == .anthropic || preset.address.isEmpty, index > 0 { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: preset.name, action: #selector(addPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addPreset(_ sender: NSMenuItem) {
        commit()
        let preset = presets[sender.tag]
        let name = preset.address.isEmpty ? "API" : preset.name
        let entry = Assistant(
            id: "api-\(UUID().uuidString.prefix(8).lowercased())",
            kind: preset.kind, name: name, model: preset.model, baseURL: preset.address
        )
        draft.append(entry)
        selectedID = entry.id
        reload()
        // Where the next thing to fill in is.
        window?.makeFirstResponder(preset.address.isEmpty ? addressField : entry.isLocal ? modelField : keyField)
    }

    @objc private func removePressed() {
        guard let id = shownID, let entry = entry(id), !entry.kind.isCommandLine else { return NSSound.beep() }
        commit()
        draft.removeAll { $0.id == id }
        typedKeys[id] = nil
        if saved.contains(where: { $0.id == id }) { removedIDs.insert(id) } else { ModelCatalog.forget(id) }
        selectedID = nil
        reload()
    }
}

/// Escape is Cancel and Return is Save, as in any dialog — except that while
/// the list of models is open, both are the list's: Return takes the model and
/// Escape closes the list. Return is taken here rather than left to Save's key
/// equivalent, which AppKit blanks while the window is not key, and which
/// would take Return before the field being typed in heard it.
private final class AssistantsWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var listIsOpen: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, attachedSheet == nil, isPlain(event) else { return super.performKeyEquivalent(with: event) }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if listIsOpen?() == true, isReturn || event.keyCode == 53 { return false }
        if isReturn {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// No modifier held, the keypad's own flag aside.
private func isPlain(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty
}

/// Asks whether to lose what was changed in the window, with its two answers
/// at the bottom right the way a Mac dialog has them. Not NSAlert: since Big
/// Sur it stacks a short alert's buttons in its middle.
final class DiscardSheet: NSObject {
    static let title = "Discard unsaved changes?"
    static let text = "The changes you made to the assistants have not been saved, and will be lost."
        + "\n\nDiscard Changes closes the window and keeps every assistant as it was when last saved. "
        + "Keep Editing takes you back to the window with your changes, so you can save them."

    let window: NSWindow
    let discardButton = NSButton(title: "Discard Changes", target: nil, action: nil)
    let keepButton = NSButton(title: "Keep Editing", target: nil, action: nil)
    private let done: (Bool) -> Void

    init(done: @escaping (Bool) -> Void) {
        self.done = done
        let sheet = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
        window = sheet
        super.init()
        sheet.onCancel = { [weak self] in self?.finish(false) }
        sheet.onReturn = { [weak self] in self?.finish(false) }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(wrappingLabelWithString: Self.title)
        title.font = .boldSystemFont(ofSize: 13)
        let text = NSTextField(wrappingLabelWithString: Self.text)
        text.font = .systemFont(ofSize: 11)
        for label in [title, text] { label.preferredMaxLayoutWidth = 348 }
        let words = NSStackView(views: [title, text])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 8
        let top = NSStackView(views: [icon, words])
        top.alignment = .top
        top.spacing = 16

        // Keep Editing is the default, so Return loses nothing; Discard
        // Changes has ⌘D, as Don't Save has in a document's sheet.
        discardButton.target = self
        discardButton.action = #selector(discardPressed)
        discardButton.keyEquivalent = "d"
        discardButton.keyEquivalentModifierMask = .command
        discardButton.hasDestructiveAction = true
        keepButton.target = self
        keepButton.action = #selector(keepPressed)
        keepButton.keyEquivalent = "\r"
        for button in [discardButton, keepButton] {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        }
        let buttons = NSStackView(views: [discardButton, keepButton])
        buttons.spacing = 12

        let content = NSView()
        for view in [top, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            buttons.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
    }

    @objc private func discardPressed() { finish(true) }
    @objc private func keepPressed() { finish(false) }

    private func finish(_ discard: Bool) {
        window.sheetParent?.endSheet(window)
        done(discard)
    }
}

/// Escape and Return are both Keep Editing: nothing is lost by a key.
private final class SheetWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, isPlain(event), event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps a field to a number as it is typed or pasted: digits, and one decimal
/// separator when it takes decimals. The rest is dropped rather than refused,
/// so "128,000" pasted into Context comes out as 128000.
final class NumberFieldFormatter: Formatter {
    let decimals: Bool

    init(decimals: Bool) {
        self.decimals = decimals
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func string(for obj: Any?) -> String? { obj.map { "\($0)" } }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let kept = Self.kept(partialString, decimals: decimals)
        guard kept != partialString else { return true }
        newString?.pointee = kept as NSString
        return false
    }

    static func kept(_ text: String, decimals: Bool) -> String {
        var result = ""
        var separator = false
        for character in text {
            if character.isASCII, character.isNumber {
                result.append(character)
            } else if decimals, !separator, character == "." || character == "," {
                result.append(character)
                separator = true
            }
        }
        // More than a billion tokens, or dollars, is a slip of the finger.
        return String(result.prefix(9))
    }
}
