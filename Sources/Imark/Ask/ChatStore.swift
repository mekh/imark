import Foundation

/// Every chat, in memory, and on disk when Settings says to keep them until
/// they are deleted.
///
/// One JSON file per chat in Application Support, never anything in the
/// document: a chat is the reader's own, often long, and a document that
/// carried it would hand it to whoever the file is sent to next. The notes an
/// answer turns into are the part that belongs in the file, and only on
/// purpose.
final class ChatStore {
    static let shared = ChatStore()

    /// Posted with the document's path as the object, so every window showing
    /// that document redraws its chats — two tabs on one file are one list.
    static let changed = Notification.Name("ImarkChatsChanged")

    /// Replaced by the tests, which must not read or write the real chats.
    static var folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Imark/Chats", isDirectory: true)
    }()

    private var chats: [String: AskChat] = [:]
    private var loaded = false

    /// The key a document is filed under: the file itself, however it was
    /// reached.
    static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func chats(for url: URL) -> [AskChat] {
        load()
        let key = Self.key(for: url)
        return chats.values.filter { $0.document == key }.sorted { $0.created < $1.created }
    }

    func chat(_ id: String) -> AskChat? {
        load()
        return chats[id]
    }

    /// `writing` false keeps the change in memory only, for an answer still
    /// arriving: it is written once it is done.
    func save(_ chat: AskChat, writing: Bool = true) {
        load()
        chats[chat.id] = chat
        if writing, Settings.askKeepChats == .untilDeleted { write(chat) }
    }

    func delete(_ id: String) {
        load()
        guard let chat = chats.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: file(for: id))
        announce(chat.document)
    }

    /// Every chat about one document, or every chat there is.
    func deleteAll(for url: URL? = nil) {
        load()
        let key = url.map(Self.key(for:))
        let doomed = chats.values.filter { key == nil || $0.document == key }
        for chat in doomed {
            chats.removeValue(forKey: chat.id)
            try? FileManager.default.removeItem(at: file(for: chat.id))
        }
        for document in Set(doomed.map(\.document)) { announce(document) }
    }

    var count: Int {
        load()
        return chats.count
    }

    func announce(_ document: String) {
        NotificationCenter.default.post(name: Self.changed, object: document)
    }

    /// Forgets what was read, for the tests that swap the folder underneath.
    func reset() {
        chats = [:]
        loaded = false
    }

    // MARK: - Disk

    private func file(for id: String) -> URL {
        Self.folder.appendingPathComponent("\(id).json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let chat = try? decoder.decode(AskChat.self, from: data) else { continue }
            chats[chat.id] = chat
        }
    }

    private func write(_ chat: AskChat) {
        // An id is made by the page, and goes into a file name.
        guard AskChat.isValidID(chat.id) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(chat) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: chat.id), options: .atomic)
    }
}

extension AskChat {
    /// Letters, digits and dashes, and not too long: the page makes the id, and
    /// it ends up in a file name.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
