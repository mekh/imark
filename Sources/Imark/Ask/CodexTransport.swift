import Foundation

/// Asks Codex, through its own `codex exec`.
///
/// Run as little of Codex as answering needs. Its shell is off, and with it
/// every file but the document, which comes through `AskMCPServer`; web search,
/// images, apps, plugins and sub-agents are off; the reader's own
/// `config.toml` is not loaded, so their MCP servers, hooks and model choices
/// stay out; the sandbox is read-only, and Codex asks nothing of anybody in
/// exec, so a write it tried would be refused. Two things cannot be switched
/// off: its patch tool, which the sandbox refuses, and the reader's global
/// `~/.codex/AGENTS.md`, which it always reads.
///
/// The document's server is required, so Codex waits for it rather than
/// starting the first turn without it. Settings are given with `-c` on every
/// launch, a follow-up included: a resumed session takes the new process's.
final class CodexTransport: AgentTransport {
    override class var agentName: String { "Codex" }

    override func makeParser(for request: AskRequest, resume: Bool) -> any AgentStreamParser {
        CodexStreamParser(resuming: resume, before: resume ? Self.sessionTotal(in: request.chat) : nil)
    }

    override func arguments(for request: AskRequest, resume: Bool) -> [String] {
        Self.arguments(for: request, resume: resume)
    }

    override func prompt(for request: AskRequest, resume: Bool) -> String {
        resume ? request.question : Self.conversation(for: request)
    }

    override func failure(said: String) -> AskFailure {
        said.isEmpty ? super.failure(said: said) : CodexStreamParser.failure(said)
    }

    static func arguments(for request: AskRequest, resume: Bool) -> [String] {
        let server = "{command=\(toml(mcpExecutable ?? "")), args=[\(toml(AskMCPServer.flag)), \(toml(request.document.path))], "
            + "required=true, default_tools_approval_mode=\"approve\", omit_tools_from=[\"deferred\"]}"
        var arguments = [
            "exec", "--json", "--ignore-user-config", "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-c", "mcp_servers.\(AskMCPServer.name)=\(server)",
            "-c", "developer_instructions=\(toml(AskPrompt.system(tools: true)))",
            "-c", "web_search=\"disabled\"",
            "-c", "project_doc_max_bytes=0",
            "-c", "agents.enabled=false",
            "-c", "tools.experimental_request_user_input.enabled=false",
        ]
        // As settings rather than --disable: an unknown name there stops Codex
        // with an error, here it only warns, and the names change between
        // versions.
        for feature in ["shell_tool", "view_image", "sleep_tool", "apps", "plugins", "image_generation", "goals", "multi_agent"] {
            arguments += ["-c", "features.\(feature)=false"]
        }
        if !request.assistant.model.isEmpty { arguments += ["--model", request.assistant.model] }
        if resume, let session = request.chat.session { arguments += ["resume", session] }
        // The question comes on standard input.
        arguments.append("-")
        return arguments
    }

    /// A TOML basic string: what `-c` takes a value as.
    static func toml(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The session's sum as of the last answer given in it.
    static func sessionTotal(in chat: AskChat) -> AskUsage.SessionTotal? {
        chat.turns.last { $0.error == nil && !$0.answer.isEmpty }?.usage?.sessionTotal
    }
}

/// Turns `codex exec --json` into Ask's events, a line at a time.
///
/// Codex does not stream an answer: each message arrives whole when it is
/// done. A message before a tool call was said on the way to it, and the
/// answer starts again after the call.
struct CodexStreamParser: AgentStreamParser {
    private(set) var done = false
    private(set) var sessionMissing = false
    private let resuming: Bool
    private let before: AskUsage.SessionTotal?
    private var said = false
    private var toolSinceText = false
    private var toolCalls = 0
    /// The latest `error` line: Codex retries some, and says so only if it
    /// then gives up.
    private var lastError = ""

    init(resuming: Bool = false, before: AskUsage.SessionTotal? = nil) {
        self.resuming = resuming
        self.before = before
    }

    mutating func feed(_ line: String, since start: Date) -> [AskEvent] {
        guard !done, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            return (object["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.completed":
            return item(object.dict("item") ?? [:])
        case "error":
            lastError = object["message"] as? String ?? lastError
        case "turn.failed":
            done = true
            let message = object.dict("error")?["message"] as? String ?? lastError
            let lower = message.lowercased()
            sessionMissing = resuming && ["not found", "no rollout", "does not exist", "no such"].contains { lower.contains($0) }
            return [.failed(Self.failure(message))]
        case "turn.completed":
            done = true
            return [.usage(usage(from: object.dict("usage") ?? [:], since: start)), .finished]
        default:
            break
        }
        return []
    }

    private mutating func item(_ item: [String: Any]) -> [AskEvent] {
        switch item["type"] as? String {
        case "agent_message":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            defer {
                said = true
                toolSinceText = false
            }
            if said, toolSinceText { return [.restart, .delta(text)] }
            return [.delta(said ? "\n\n" + text : text)]
        case "mcp_tool_call":
            guard item["server"] as? String == AskMCPServer.name, item["status"] as? String == "completed",
                  let tool = item["tool"] as? String else { return [] }
            toolCalls += 1
            toolSinceText = true
            let result = (item.dict("result")?["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return DocumentTools.describe(tool, item["arguments"] as? [String: Any] ?? [:], result: result)
                .map { [.activity($0)] } ?? []
        default:
            return []
        }
    }

    /// Codex says the session's sum; this answer is what it added.
    private func usage(from raw: [String: Any], since start: Date) -> AskUsage {
        let total = AskUsage.SessionTotal(
            input: raw.int("input_tokens") ?? 0,
            cachedInput: raw.int("cached_input_tokens") ?? 0,
            output: raw.int("output_tokens") ?? 0,
            reasoning: raw.int("reasoning_output_tokens") ?? 0
        )
        let base = before ?? AskUsage.SessionTotal()
        func less(_ a: Int, _ b: Int) -> Int { max(0, a - b) }
        return AskUsage(
            input: less(total.input, base.input),
            cachedInput: less(total.cachedInput, base.cachedInput),
            output: less(total.output, base.output),
            reasoning: less(total.reasoning, base.reasoning),
            rounds: toolCalls + 1,
            seconds: Date().timeIntervalSince(start),
            costSource: "Codex",
            sessionTotal: total
        )
    }

    static func failure(_ said: String) -> AskFailure {
        let lower = said.lowercased()
        if ["not logged in", "log in", "login", "sign in", "401", "unauthorized", "refresh token", "access token"].contains(where: lower.contains) {
            return AskFailure(message: "Codex is not signed in. Run `codex login` in Terminal once and sign in there.", remedy: .signIn)
        }
        if lower.contains("required mcp servers failed") {
            return AskFailure(message: "Imark's document tools could not start for Codex, so it was not asked. \(said)")
        }
        return AskFailure(message: said.isEmpty ? "Codex did not answer." : said)
    }
}
