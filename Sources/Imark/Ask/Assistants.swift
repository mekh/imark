import Foundation
import Security

/// Who Ask can send a question to.
///
/// Two families. A command-line agent (Claude Code, Codex) carries its own
/// login and its own subscription, so Imark keeps no key for it and only has to
/// find the executable. An API needs an address, a model and usually a key, which lives
/// in the Keychain, never in the settings. The OpenAI-compatible kind covers
/// OpenAI itself and everything that speaks its protocol: OpenRouter, LM Studio,
/// Ollama and most of the rest.
struct Assistant: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case claudeCode, openAI, anthropic, codex

        var isCommandLine: Bool { command != nil }

        /// A command-line agent's executable.
        var command: String? {
            switch self {
            case .claudeCode: return "claude"
            case .codex: return "codex"
            case .openAI, .anthropic: return nil
            }
        }
    }

    /// Whether an API model is handed the tools. Auto finds out: a model that
    /// refuses them is asked again without, and remembered.
    enum Tools: String, Codable, CaseIterable {
        case auto, on, off

        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .on: return "Always"
            case .off: return "Never"
            }
        }
    }

    var id: String
    var kind: Kind
    var name: String
    var enabled = true
    /// Empty means whatever the agent or the API picks by default.
    var model = ""
    var baseURL = ""
    var tools = Tools.auto
    /// Found out, not set: the model said it does not take tools.
    var refusesTools = false
    /// Tokens, when known. Decides whether a model without tools can be given
    /// the whole document.
    var contextWindow: Int?
    /// Claude Code stops an answer that would cost more than this.
    var spendingCap: Double?
    /// A command-line agent's executable, as set in Settings ▸ Assistants.
    /// Set, not guessed: Codex comes inside ChatGPT.app now, older apps were
    /// called Codex, and a search by name finds the wrong one.
    var path: String?

    var usesTools: Bool {
        switch tools {
        case .on: return true
        case .off: return false
        case .auto: return !refusesTools
        }
    }

    /// A command-line agent has something to run; an API always does.
    var isInstalled: Bool {
        guard kind.isCommandLine else { return true }
        guard let url = Assistants.executable(for: self) else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Nothing leaves the Mac, so there is nothing to pay and no cost to show.
    var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// What the chip under a question says: the assistant, and its model if one
    /// was picked.
    var label: String {
        model.isEmpty ? name : "\(name) · \(Assistants.shortModel(model))"
    }
}

enum Assistants {
    /// The command-line agents Imark can drive, in the order they are listed.
    static let agents: [(kind: Assistant.Kind, id: String, name: String)] = [
        (.claudeCode, "claude-code", "Claude Code"),
        (.codex, "codex", "Codex"),
    ]

    /// Every assistant, the command-line agents always among them, installed
    /// or not: one that is not is listed with how to install it, and is left
    /// out of `enabled` until it is.
    static var all: [Assistant] {
        get {
            // An agent is named for itself and has no address; the window has
            // no field for either. A bug of the window's once wrote an API's
            // name and address into Claude Code, which then read "OpenAI"
            // everywhere with no way to put it right.
            var list = stored.map { entry -> Assistant in
                guard let agent = agents.first(where: { $0.kind == entry.kind }) else { return entry }
                var fixed = entry
                fixed.name = agent.name
                fixed.baseURL = ""
                return fixed
            }
            for (index, agent) in agents.enumerated() where !list.contains(where: { $0.kind == agent.kind }) {
                list.insert(Assistant(id: agent.id, kind: agent.kind, name: agent.name), at: min(index, list.count))
            }
            // An agent never given a path gets the one its command has where
            // such tools are installed, shown in its field to keep or change.
            for index in list.indices where list[index].kind.isCommandLine && (list[index].path ?? "").isEmpty {
                list[index].path = list[index].kind.command.flatMap(locate)?.path
            }
            return list
        }
        set {
            Settings.assistantsData = try? JSONEncoder().encode(newValue)
        }
    }

    private static var stored: [Assistant] {
        guard let data = Settings.assistantsData,
              let list = try? JSONDecoder().decode([Assistant].self, from: data) else { return [] }
        return list
    }

    /// Those a question can go to: switched on, and there to run.
    static var enabled: [Assistant] { all.filter { $0.enabled && $0.isInstalled } }

    /// How to get an agent that is not set up, for the window.
    static func installHint(for kind: Assistant.Kind) -> String {
        switch kind {
        case .claudeCode:
            return "Choose its executable below. Not installed yet? `brew install --cask claude-code`, then run `claude` in Terminal once to sign in."
        case .codex:
            return "Choose its executable below, or ChatGPT.app, which has it inside. Not installed yet? `brew install --cask codex`, then `codex login` in Terminal."
        case .openAI, .anthropic:
            return ""
        }
    }

    static func assistant(_ id: String) -> Assistant? { all.first { $0.id == id } }

    /// The one a new chat goes to: the one picked in Settings while it is still
    /// there and on, otherwise the first that is.
    static var current: Assistant? {
        let list = enabled
        return list.first { $0.id == Settings.askAssistant } ?? list.first
    }

    static func name(of id: String) -> String { assistant(id)?.name ?? "Assistant" }

    static func update(_ assistant: Assistant) {
        var list = all
        if let index = list.firstIndex(where: { $0.id == assistant.id }) {
            list[index] = assistant
        } else {
            list.append(assistant)
        }
        all = list
    }

    static func remove(_ id: String) {
        all = all.filter { $0.id != id }
        Keychain.removeKey(for: id)
        ModelCatalog.forget(id)
    }

    /// `anthropic/claude-sonnet-5` reads as `claude-sonnet-5` on a chip that has
    /// room for a word or two.
    static func shortModel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    /// The models a command-line agent takes by alias, for the menu under a
    /// question. An API's model is the one picked in Settings ▸ Assistants.
    static func suggestedModels(for kind: Assistant.Kind) -> [String] {
        switch kind {
        case .claudeCode: return ["opus", "sonnet", "haiku"]
        // Codex's own catalogue, newest first. Its default is whatever the
        // account is given, which is what an empty field asks for.
        case .codex: return ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.5"]
        case .openAI, .anthropic: return []
        }
    }

    // MARK: - Finding the executables

    /// What a command-line agent runs: its path as set, else what its command
    /// is where such tools are installed.
    static func executable(for assistant: Assistant) -> URL? {
        if let path = assistant.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return assistant.kind.command.flatMap(locate)
    }

    /// The agent's command inside an app the reader chose — ChatGPT.app keeps
    /// Codex in `Contents/Resources/codex-cli/bin/codex`. Nearest first, and
    /// only inside that one app.
    static func bundledExecutable(in app: URL, named name: String) -> URL? {
        let fm = FileManager.default
        var level = [app.appendingPathComponent("Contents")]
        for _ in 0..<7 where !level.isEmpty {
            var next: [URL] = []
            for folder in level {
                let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
                for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true, values?.isSymbolicLink != true {
                        next.append(item)
                    } else if item.lastPathComponent == name, fm.isExecutableFile(atPath: item.path) {
                        return item
                    }
                }
            }
            level = next
        }
        return nil
    }

    /// The first line an executable prints for `--version`, to show what the
    /// path leads to. Nil when it does not answer within a few seconds.
    static func version(of executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + searchPath
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Walks `PATH` the way a login shell would, then the usual install places,
    /// only to fill in an agent's path the first time. A GUI app inherits a
    /// bare `PATH` from launchd, which is why the list is spelled out rather
    /// than trusted to the environment alone.
    static func locate(_ name: String) -> URL? {
        if let override = locations[name] { return override }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        if name == "claude" { candidates.append("\(home)/.claude/local/claude") }
        candidates += [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            // Where npm puts a global install when Node did not come from
            // Homebrew: its own prefix, Volta, Bun, or the newest nvm Node.
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? fm.contentsOfDirectory(atPath: nvm)) ?? []
        candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvm)/\($0)/bin/\(name)" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// For the tests, which run stand-ins for the agents; nil in it is an agent
    /// that is not installed.
    static var locations: [String: URL?] = [:]

    /// The `PATH` a command-line agent is started with: whatever the app got,
    /// plus the places the agents and their helpers are installed, which the
    /// app did not get.
    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (inherited + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}

/// API keys, one per assistant, in the login keychain.
///
/// Read from the keychain once per launch and kept in memory after that. Every
/// read of a keychain item's secret is a chance for macOS to ask for the login
/// password — when the item was saved by another build, or the reader clicked
/// Allow rather than Always Allow — and a key read for every request asked
/// twice for every question. Whether a key is there at all is asked without
/// reading it, which never asks for anything.
enum Keychain {
    private static let service = "Imark Ask"
    /// What has been read, or learned to be missing. `nil` inside means asked
    /// and not there.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Set by the tests, which keep their keys here and never touch the
    /// reader's keychain.
    static var inMemory: [String: String]?

    private static func cached(_ id: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    private static func remember(_ key: String?, for id: String) {
        lock.lock()
        cache[id] = .some(key)
        lock.unlock()
    }

    static func key(for id: String) -> String? {
        if let inMemory { return inMemory[id] }
        if let known = cached(id) { return known }
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let key = status == errSecSuccess ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        // A refusal at the password prompt is not remembered as "no key": the
        // next question may be allowed.
        if status == errSecSuccess || status == errSecItemNotFound { remember(key, for: id) }
        return key
    }

    /// Whether a key is stored, from its attributes alone: no secret is read,
    /// so no password is asked for. For labels and placeholders.
    static func hasKey(for id: String) -> Bool {
        if let inMemory { return inMemory[id] != nil }
        if let known = cached(id) { return known != nil }
        var query = base(id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func setKey(_ key: String, for id: String) {
        if inMemory != nil {
            inMemory?[id] = key.isEmpty ? nil : key
            return
        }
        removeKey(for: id)
        guard !key.isEmpty else { return }
        var item = base(id)
        item[kSecAttrLabel as String] = "Imark Ask: \(id)"
        item[kSecValueData as String] = Data(key.utf8)
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { remember(key, for: id) }
    }

    static func removeKey(for id: String) {
        if inMemory != nil {
            inMemory?[id] = nil
            return
        }
        SecItemDelete(base(id) as CFDictionary)
        remember(nil, for: id)
    }

    private static func base(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }
}
