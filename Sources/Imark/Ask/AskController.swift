import AppKit
import ImarkRender

/// Ask for one document window: between the page, which draws the chats and
/// takes the questions, the transports, which take them to an assistant, and
/// the store, which keeps them.
///
/// The page owns everything the reader sees and this owns everything that
/// leaves the Mac. The page never learns a key or an address; this never
/// decides what a chat looks like.
final class AskController {
    private let renderer: RendererView
    private(set) var url: URL?
    private var running: [String: AskTransport] = [:]
    private(set) var panelOpen = false

    /// Keeps an answer as a note on its passage. The window controller does the
    /// writing, which is where the file's stamp and the undo stack live.
    /// The chat, the note's text, and who signs it.
    var onKeep: ((AskChat, String, String) -> Void)?
    /// The panel opened or closed, for the toolbar button's state.
    var onPanel: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(renderer: RendererView) {
        self.renderer = renderer
        NotificationCenter.default.addObserver(
            self, selector: #selector(chatsChanged(_:)), name: ChatStore.changed, object: nil
        )
    }

    /// A window closing mid-answer: the answer is not coming, and the chat says
    /// so rather than waiting for it forever.
    deinit {
        for (id, transport) in running {
            transport.cancel()
            guard var chat = ChatStore.shared.chat(id), let last = chat.turns.indices.last else { continue }
            if chat.turns[last].answer.isEmpty { chat.turns[last].error = "The window closed before the answer arrived." }
            ChatStore.shared.save(chat)
        }
    }

    // MARK: - Driving the page

    /// A document went up in the window. Chats for the one put down stay where
    /// they are, and an answer still arriving for one of them is kept.
    func show(_ url: URL) {
        self.url = url
        configure()
        sendChats()
    }

    func configure() {
        let assistant = Assistants.current
        let access = sees(for: assistant)
        renderer.ask("configure", [
            "enabled": Settings.askEnabled,
            "assistant": assistant?.label ?? "",
            "available": assistant != nil,
            "sees": access.short,
            "seesDetail": access.detail,
            "showUsage": Settings.askShowsUsage,
            "glyph": AskGlyph.maskDataURL,
        ])
    }

    /// Opens a chat about the selection, or the panel when nothing is selected.
    func askAboutSelection() {
        guard Settings.askEnabled else { return NSSound.beep() }
        renderer.ask("open", ["selection": true])
    }

    func togglePanel() {
        guard Settings.askEnabled else { return NSSound.beep() }
        renderer.ask("togglePanel", [String: Any]())
    }

    private func sendChats() {
        guard let url else { return }
        renderer.ask("setChats", ["chats": ChatStore.shared.chats(for: url).map { chat -> [String: Any] in
            var page = chat.page
            page["running"] = running[chat.id] != nil
            return page
        }])
    }

    @objc private func chatsChanged(_ notification: Notification) {
        guard let url, notification.object as? String == ChatStore.key(for: url) else { return }
        sendChats()
    }

    private func event(_ chat: String, _ kind: String, _ extra: [String: Any] = [:]) {
        var payload = extra
        payload["chat"] = chat
        payload["kind"] = kind
        renderer.ask("event", payload)
    }

    /// What the line under the question says the assistant has to go on. Said
    /// as what it may do, not what it did: "Reads the whole document" over an
    /// answer that took 963 tokens was a claim the figures next to it refuted.
    /// Whether it did search shows above each answer.
    private func sees(for assistant: Assistant?) -> (short: String, detail: String) {
        guard let assistant else { return ("", "") }
        if assistant.kind.isCommandLine || assistant.usesTools {
            return ("Can search the document",
                    "It is given the passage and its paragraph, and can look up the headings, search and read the rest of this document when it needs to.")
        }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8),
              AskPrompt.fits(DocumentTools(text: text), window: assistant.contextWindow) else {
            return ("Given this section",
                    "This model cannot search, and the document is too long to give it whole: it is given the section around the passage and the list of headings.")
        }
        return ("Given the whole document", "This model cannot search, so the whole document goes with every question.")
    }

    // MARK: - Messages from the page

    func handle(_ body: [String: Any]) {
        guard let op = body["op"] as? String else { return }
        switch op {
        case "send":
            guard let raw = body["chat"] as? [String: Any], let question = body["question"] as? String else { return }
            send(question, in: raw)
        case "stop":
            if let id = body["chat"] as? String { stop(id) }
        case "retry":
            if let id = body["chat"] as? String { retry(id) }
        case "keep":
            guard let id = body["chat"] as? String, let index = body["turn"] as? Int,
                  let chat = ChatStore.shared.chat(id), chat.turns.indices.contains(index) else { return NSSound.beep() }
            let turn = chat.turns[index]
            onKeep?(chat, Self.noteText(turn.answer), turn.assistant ?? Assistants.name(of: chat.assistant))
        case "copy":
            guard let text = body["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "delete":
            if let id = body["chat"] as? String { delete(id) }
        case "deleteAll":
            confirmDeleteAll()
        case "closed":
            // A chat kept only while it is open goes when it is put away — but
            // not while its answer is still coming, which would be work thrown
            // out for a click.
            guard let id = body["chat"] as? String, Settings.askKeepChats == .whileOpen, running[id] == nil else { return }
            ChatStore.shared.delete(id)
        case "pick":
            showAssistantMenu(for: body["chat"] as? String, at: body["rect"] as? [String: Any])
        case "panel":
            panelOpen = body["open"] as? Bool ?? false
            onPanel?(panelOpen)
        case "settings":
            onOpenSettings?()
        default:
            break
        }
    }

    // MARK: - Asking

    private func send(_ question: String, in raw: [String: Any]) {
        guard let url, let id = raw["id"] as? String, AskChat.isValidID(id) else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, running[id] == nil else { return }

        guard let assistant = Assistants.current else {
            return event(id, "error", [
                "message": "No assistant is set up. Turn one on in Settings ▸ Assistants.",
                "remedy": AskFailure.Remedy.settings.rawValue,
            ])
        }

        let now = Date()
        var chat = ChatStore.shared.chat(id) ?? AskChat(
            id: id,
            document: ChatStore.key(for: url),
            quote: raw["quote"] as? String ?? "",
            line: raw["line"] as? Int,
            end: raw["end"] as? Int,
            blockEnd: raw["blockEnd"] as? Int,
            occurrence: raw["occurrence"] as? Int ?? 1,
            section: raw["section"] as? String ?? "",
            created: now, updated: now,
            assistant: assistant.id, model: assistant.model,
            session: nil, turns: []
        )
        // Whoever the chip under the question shows answers: the one picked in
        // Settings or from the chip. Going by the assistant the chat began with
        // had Claude Code answer under a chip that said OpenAI. The one picked
        // is given the chat so far; a session belongs to one agent and does not
        // carry over to another.
        let chosen = assistant
        if chosen.id != chat.assistant { chat.session = nil }
        chat.assistant = chosen.id
        chat.model = chosen.model

        guard let document = try? String(contentsOf: url, encoding: .utf8) else {
            return event(id, "error", ["message": "The document cannot be read."])
        }

        let before = chat
        chat.turns.append(AskTurn(question: text, assistant: chosen.name, model: chosen.model))
        chat.updated = now
        ChatStore.shared.save(chat)
        let fresh = before.turns.isEmpty
        if fresh { ChatStore.shared.announce(chat.document) }
        event(id, "asked", ["assistant": chosen.label, "turn": chat.turns.count - 1])

        let transport = AskTransports.make(for: chosen)
        running[id] = transport
        let request = AskRequest(assistant: chosen, chat: before, question: text, document: url, text: document)
        transport.start(request) { [weak self] event in self?.receive(event, for: id) }
    }

    private func receive(_ event: AskEvent, for id: String) {
        guard running[id] != nil, var chat = ChatStore.shared.chat(id), !chat.turns.isEmpty else { return }
        let last = chat.turns.count - 1
        switch event {
        case .session(let session):
            chat.session = session
            ChatStore.shared.save(chat)
        case .activity(let activity):
            chat.turns[last].activity.append(activity)
            ChatStore.shared.save(chat)
            self.event(id, "activity", ["activity": activity.page])
        case .delta(let text):
            // Kept in memory as it grows and written once it is done: a write per
            // word would be a write every few milliseconds.
            chat.turns[last].answer += text
            ChatStore.shared.save(chat, writing: false)
            self.event(id, "delta", ["text": text])
            if text.contains("\n"), Self.isRepeating(chat.turns[last].answer) {
                // A model gone round in a loop writes the same line until it
                // runs out of tokens, and every one of them is paid for.
                running.removeValue(forKey: id)?.cancel()
                chat.turns[last].error = "The answer started repeating itself and was stopped."
                ChatStore.shared.save(chat)
                self.event(id, "error", ["message": chat.turns[last].error!, "remedy": AskFailure.Remedy.none.rawValue])
                ChatStore.shared.announce(chat.document)
            }
        case .restart:
            chat.turns[last].answer = ""
            ChatStore.shared.save(chat, writing: false)
            self.event(id, "restart")
        case .usage(let usage):
            chat.turns[last].usage = usage
            ChatStore.shared.save(chat)
            self.event(id, "usage", ["usage": usage.page])
        case .finished:
            running[id] = nil
            chat.updated = Date()
            ChatStore.shared.save(chat)
            self.event(id, "done", ["answer": chat.turns[last].answer])
            // Another window on the same document has not seen any of it.
            ChatStore.shared.announce(chat.document)
        case .failed(let failure):
            running[id] = nil
            chat.turns[last].error = failure.message
            ChatStore.shared.save(chat)
            self.event(id, "error", ["message": failure.message, "remedy": failure.remedy.rawValue])
            ChatStore.shared.announce(chat.document)
        }
    }

    private func stop(_ id: String) {
        guard let transport = running.removeValue(forKey: id) else { return }
        transport.cancel()
        guard var chat = ChatStore.shared.chat(id), !chat.turns.isEmpty else { return }
        let last = chat.turns.count - 1
        if chat.turns[last].answer.isEmpty { chat.turns[last].error = "Stopped." }
        ChatStore.shared.save(chat)
        event(id, "stopped", ["answer": chat.turns[last].answer])
    }

    /// The last question again, in place of its answer.
    private func retry(_ id: String) {
        guard running[id] == nil, var chat = ChatStore.shared.chat(id), let last = chat.turns.popLast() else { return }
        ChatStore.shared.save(chat)
        send(last.question, in: ["id": id])
    }

    private func delete(_ id: String) {
        running.removeValue(forKey: id)?.cancel()
        ChatStore.shared.delete(id)
    }

    private func confirmDeleteAll() {
        guard let url, let window = renderer.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete every chat about \(url.lastPathComponent)?"
        alert.informativeText = "The notes kept from them stay in the document."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for chat in ChatStore.shared.chats(for: url) { self.running.removeValue(forKey: chat.id)?.cancel() }
            ChatStore.shared.deleteAll(for: url)
        }
    }

    // MARK: - Choosing the assistant

    private final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
    private var menuTargets: [MenuTarget] = []

    /// The chip under the question opens this: every assistant that is on, and
    /// for the command-line agents the models they take by name. Picking one
    /// makes it the assistant for every question from then on, in this chat
    /// and the others, as the same choice in Settings does: the chip always
    /// shows who answers next.
    private func showAssistantMenu(for chatID: String?, at rect: [String: Any]?) {
        let menu = NSMenu()
        menuTargets = []
        let currentID = Assistants.current?.id

        func add(_ title: String, checked: Bool, indent: Int = 0, _ action: @escaping () -> Void) {
            let target = MenuTarget(action)
            menuTargets.append(target)
            let item = menu.addItem(withTitle: title, action: #selector(MenuTarget.run), keyEquivalent: "")
            item.target = target
            item.state = checked ? .on : .off
            item.indentationLevel = indent
        }

        for assistant in Assistants.enabled {
            let isCurrent = assistant.id == currentID
            add(assistant.name, checked: isCurrent && assistant.model.isEmpty) { [weak self] in
                self?.choose(assistant, model: nil, chat: chatID)
            }
            let models = Assistants.suggestedModels(for: assistant.kind)
                + (assistant.model.isEmpty || Assistants.suggestedModels(for: assistant.kind).contains(assistant.model) ? [] : [assistant.model])
            for model in models {
                add(model, checked: isCurrent && assistant.model == model, indent: 1) { [weak self] in
                    self?.choose(assistant, model: model, chat: chatID)
                }
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add("Assistants…", checked: false) { [weak self] in
            AssistantsWindowController.show(over: self?.renderer.window)
        }

        let point: NSPoint
        if let rect, let x = rect["x"] as? Double, let y = rect["y"] as? Double, let h = rect["height"] as? Double {
            point = NSPoint(x: x, y: renderer.bounds.height - y - h - 2)
        } else {
            point = NSPoint(x: renderer.bounds.midX, y: renderer.bounds.midY)
        }
        menu.popUp(positioning: nil, at: point, in: renderer)
    }

    private func choose(_ assistant: Assistant, model: String?, chat id: String?) {
        var picked = assistant
        if let model { picked.model = model }
        // Picking the assistant itself, with no model under it, means its own
        // default — except for an API, whose model is the one typed in Settings.
        if model == nil, assistant.kind.isCommandLine { picked.model = "" }
        Assistants.update(picked)
        Settings.askAssistant = picked.id
        if let id, var chat = ChatStore.shared.chat(id) {
            if chat.assistant != picked.id { chat.session = nil }
            chat.assistant = picked.id
            chat.model = picked.model
            ChatStore.shared.save(chat)
        }
        configure()
    }

    /// The same non-empty line, over and over, at the end of the answer: a
    /// dozen in a row is no list anybody meant to write.
    static func isRepeating(_ answer: String) -> Bool {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(12).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 12, let first = lines.first, !first.isEmpty else { return false }
        return lines.allSatisfy { $0 == first }
    }

    // MARK: - Keeping an answer

    /// An answer as a note: without the line citations, which point at lines
    /// that move as soon as the note itself is written into the file.
    static func noteText(_ answer: String) -> String {
        answer
            .replacingOccurrences(
                of: #"\s*\[L\d+(?:\s*[-–]\s*L?\d+)?(?:\s*[,;]\s*L?\d+(?:\s*[-–]\s*L?\d+)?)*\]"#,
                with: "", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
