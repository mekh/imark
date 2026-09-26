import AppKit

/// The Ask group in Settings. Its controls and their actions live here rather
/// than in PreferencesWindowController, which only lays out the rows: Ask is
/// this fork's, and the shared file stays a couple of lines away from
/// upstream's.
final class AskSettingsRows: NSObject {
    private let asking = NSButton(checkboxWithTitle: "Show Ask in the selection row and toolbar", target: nil, action: nil)
    private let assistant = NSPopUpButton()
    private let keep = NSPopUpButton()
    private let usage = NSButton(checkboxWithTitle: "Show tokens and cost under answers", target: nil, action: nil)
    private let manage = NSButton(title: "Assistants…", target: nil, action: nil)
    private let deleteAll = NSButton(title: "Delete All Chats…", target: nil, action: nil)

    override init() {
        super.init()
        asking.target = self
        asking.action = #selector(askingChanged)
        asking.toolTip = "The assistant reads the document it is asked about and sends it to whoever runs the model."
        assistant.target = self
        assistant.action = #selector(assistantChanged)
        keep.removeAllItems()
        for value in Settings.KeepChats.allCases { keep.addItem(withTitle: value.label) }
        keep.target = self
        keep.action = #selector(keepChanged)
        usage.target = self
        usage.action = #selector(usageChanged)
        for button in [manage, deleteAll] {
            button.bezelStyle = .rounded
            button.target = self
        }
        manage.action = #selector(managePressed)
        deleteAll.action = #selector(deleteAllPressed)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Settings.changed, object: nil)
    }

    func rows() -> [(String, NSView)] {
        let buttons = NSStackView(views: [manage, deleteAll])
        buttons.spacing = 8
        return [
            ("Asking", asking),
            ("Ask with", assistant),
            ("Keep chats", keep),
            ("Usage", usage),
            ("", buttons),
        ]
    }

    @objc func refresh() {
        asking.state = Settings.askEnabled ? .on : .off
        assistant.removeAllItems()
        let list = Assistants.enabled
        if list.isEmpty {
            assistant.addItem(withTitle: "None set up")
            assistant.isEnabled = false
        } else {
            assistant.isEnabled = true
            for entry in list {
                assistant.addItem(withTitle: entry.label)
                assistant.lastItem?.representedObject = entry.id
            }
            if let current = Assistants.current,
               let index = assistant.itemArray.firstIndex(where: { $0.representedObject as? String == current.id }) {
                assistant.selectItem(at: index)
            }
        }
        keep.selectItem(at: Settings.KeepChats.allCases.firstIndex(of: Settings.askKeepChats) ?? 0)
        usage.state = Settings.askShowsUsage ? .on : .off
    }

    @objc private func askingChanged() { Settings.askEnabled = asking.state == .on }

    @objc private func assistantChanged() {
        guard let id = assistant.selectedItem?.representedObject as? String else { return }
        Settings.askAssistant = id
    }

    @objc private func keepChanged() {
        let all = Settings.KeepChats.allCases
        guard all.indices.contains(keep.indexOfSelectedItem) else { return }
        Settings.askKeepChats = all[keep.indexOfSelectedItem]
    }

    @objc private func usageChanged() { Settings.askShowsUsage = usage.state == .on }

    @objc private func managePressed() { AssistantsWindowController.show() }

    @objc private func deleteAllPressed() {
        let alert = NSAlert()
        let count = ChatStore.shared.count
        alert.messageText = count == 1 ? "Delete the one chat there is?" : "Delete all \(count) chats?"
        alert.informativeText = "Chats about every document go. Notes kept from them stay in the documents."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard count > 0 else { return NSSound.beep() }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { ChatStore.shared.deleteAll() }
        }
        if let window = deleteAll.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
