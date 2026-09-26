import Foundation

/// One question on its way to an assistant.
struct AskRequest {
    var assistant: Assistant
    /// The chat as it was before this question: its earlier turns are the
    /// history, and its passage is what the first question is about.
    var chat: AskChat
    var question: String
    var document: URL
    var text: String

    var tools: DocumentTools { DocumentTools(text: text) }
}

/// Something that takes a question to an assistant and reports back as the
/// answer arrives. Events come on the main thread, and nothing comes after
/// `.finished`, `.failed`, or `cancel()`.
protocol AskTransport: AnyObject {
    func start(_ request: AskRequest, emit: @escaping (AskEvent) -> Void)
    func cancel()
}

enum AskTransports {
    static func make(for assistant: Assistant) -> AskTransport {
        switch assistant.kind {
        case .claudeCode: return ClaudeCodeTransport()
        case .codex: return CodexTransport()
        case .openAI: return OpenAITransport()
        case .anthropic: return AnthropicTransport()
        }
    }

    /// Replaced by the tests, which answer from a stand-in server.
    static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration)
    }()

    /// Rounds of tools one answer may take before it has to answer with what it
    /// has. A model that keeps searching is not converging.
    static let maxRounds = 8

    /// The earlier turns, for a transport that has to send them again: an API
    /// remembers nothing, and neither does an agent whose session is gone.
    static func history(_ turns: [AskTurn]) -> [(question: String, answer: String)] {
        turns.filter { $0.error == nil && !$0.answer.isEmpty }.map { ($0.question, $0.answer) }
    }
}

/// Reads a server-sent event stream a line at a time: `data:` lines, and for
/// Anthropic the `event:` line before each.
struct EventStreamLine {
    let field: String
    let value: String

    init?(_ line: String) {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
        field = String(line[..<colon])
        var rest = line[line.index(after: colon)...]
        if rest.first == " " { rest = rest.dropFirst() }
        value = String(rest)
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? { DocumentTools.integer(self[key]) }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}
