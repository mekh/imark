import Foundation

/// What Ask remembers between launches. An extension of its own rather than a
/// block in Settings.swift: Ask exists only in this fork, and keeping it out of
/// the shared file keeps every merge from upstream about upstream's changes.
extension Settings {
    private static var askStore: UserDefaults { .standard }

    private static func askAnnounce() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Off until it is turned on. An assistant reads the document it is asked
    /// about and sends it to whoever runs the model, and that is a thing to
    /// decide once, on purpose, rather than find switched on.
    static var askEnabled: Bool {
        get { askStore.bool(forKey: "askEnabled") }
        set { askStore.set(newValue, forKey: "askEnabled"); askAnnounce() }
    }

    /// The assistant a new chat goes to, by its id in `assistants`.
    static var askAssistant: String {
        get { askStore.string(forKey: "askAssistant") ?? "" }
        set { askStore.set(newValue, forKey: "askAssistant"); askAnnounce() }
    }

    enum KeepChats: String, CaseIterable {
        case untilDeleted, untilQuit, whileOpen

        var label: String {
            switch self {
            case .untilDeleted: return "Until I delete them"
            case .untilQuit: return "Until Imark quits"
            case .whileOpen: return "While the chat is open"
            }
        }
    }

    /// How long a chat outlives the card or panel it was written in. Kept on
    /// disk only in the first case; the other two never write it at all.
    static var askKeepChats: KeepChats {
        get { KeepChats(rawValue: askStore.string(forKey: "askKeepChats") ?? "") ?? .untilDeleted }
        set { askStore.set(newValue.rawValue, forKey: "askKeepChats"); askAnnounce() }
    }

    /// Whether every answer says what it cost: tokens in and out, time, and the
    /// price when whoever ran the model reports one.
    static var askShowsUsage: Bool {
        get { askStore.object(forKey: "askShowsUsage") as? Bool ?? true }
        set { askStore.set(newValue, forKey: "askShowsUsage"); askAnnounce() }
    }

    /// The assistants, as JSON. See `Assistants`, which merges in the command
    /// line tools it finds on the machine.
    static var assistantsData: Data? {
        get { askStore.data(forKey: "assistants") }
        set { askStore.set(newValue, forKey: "assistants"); askAnnounce() }
    }
}
