import Foundation

/// Asks Claude Code, through its own `claude` command.
///
/// Run as little of Claude Code as answering needs. Its own tools are off and
/// the document's three come from `AskMCPServer`; its system prompt, written for
/// working in a code base, is replaced by Ask's; the reader's settings are not
/// loaded, so their hooks — a sound when a session stops, a script when one
/// starts — do not fire for every question; and it runs in a folder of its
/// own, so no project's CLAUDE.md comes along and its sessions stay out of the
/// reader's projects.
final class ClaudeCodeTransport: AgentTransport {
    override class var agentName: String { "Claude Code" }
    override func makeParser(for request: AskRequest, resume: Bool) -> any AgentStreamParser { ClaudeStreamParser() }

    override func arguments(for request: AskRequest, resume: Bool) -> [String] {
        Self.arguments(for: request, resume: resume)
    }

    override func prompt(for request: AskRequest, resume: Bool) -> String {
        resume ? request.question : Self.prompt(for: request)
    }

    override func prepare(_ environment: inout [String: String]) {
        // In print mode Claude Code sends the question while its MCP servers
        // are still starting, and the model got no tools at all: told it could
        // search the document, it wrote a Read call out as text, made up what
        // it returned and ran on into a page of `</table>`. With this it waits
        // for the document's server first.
        environment["MCP_CONNECTION_NONBLOCKING"] = "0"
    }

    override func failure(said: String) -> AskFailure {
        said.isEmpty ? super.failure(said: said) : ClaudeStreamParser.failure(said, subtype: nil)
    }

    static func arguments(for request: AskRequest, resume: Bool) -> [String] {
        let server: [String: Any] = [
            "command": mcpExecutable ?? "",
            "args": [AskMCPServer.flag, request.document.path],
        ]
        let config = ["mcpServers": [AskMCPServer.name: server]]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "",
            "--mcp-config", json, "--strict-mcp-config",
            "--allowedTools", AskMCPServer.qualifiedToolNames.joined(separator: ","),
            "--system-prompt", AskPrompt.system(tools: true),
            "--setting-sources", "",
            "--disable-slash-commands",
        ]
        if !request.assistant.model.isEmpty { arguments += ["--model", request.assistant.model] }
        if resume, let session = request.chat.session { arguments += ["--resume", session] }
        if let cap = request.assistant.spendingCap, cap > 0 { arguments += ["--max-budget-usd", String(cap)] }
        return arguments
    }

    static func prompt(for request: AskRequest) -> String { conversation(for: request) }
}

/// Turns Claude Code's `stream-json` output into Ask's events, a line at a time.
struct ClaudeStreamParser: AgentStreamParser {
    private(set) var done = false
    /// The last result said the session to resume does not exist.
    private(set) var sessionMissing = false
    private var toolCalls: [String: (name: String, input: [String: Any])] = [:]
    private var answered = false
    private var firstToken: Double?
    /// What the latest request to the model took in: how full the context is.
    private var context: Int?
    private var lastText = ""

    mutating func feed(_ line: String, since start: Date) -> [AskEvent] {
        guard !done, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { break }
            var events: [AskEvent] = []
            if let session = object["session_id"] as? String { events.append(.session(session)) }
            // Without the document's tools the model has nothing to read with
            // but the prompt says it does. Better no answer than a made-up one.
            let tools = object["tools"] as? [String] ?? []
            if !AskMCPServer.qualifiedToolNames.allSatisfy(tools.contains) {
                done = true
                events.append(.failed(AskFailure(
                    message: "Imark's document tools did not reach Claude Code, so it was stopped before it could answer without them. Try again; if it keeps happening, the Claude Code version may not support them.",
                    remedy: .none
                )))
            }
            return events
        case "stream_event":
            return streamEvent(object.dict("event") ?? [:], since: start)
        case "assistant":
            let content = object.dict("message")?["content"] as? [[String: Any]] ?? []
            for item in content {
                if item["type"] as? String == "tool_use", let id = item["id"] as? String {
                    let name = (item["name"] as? String ?? "").components(separatedBy: "__").last ?? ""
                    toolCalls[id] = (name, item["input"] as? [String: Any] ?? [:])
                }
                if item["type"] as? String == "text", let text = item["text"] as? String { lastText = text }
            }
        case "user":
            let content = object.dict("message")?["content"] as? [[String: Any]] ?? []
            return content.compactMap { item -> AskEvent? in
                guard item["type"] as? String == "tool_result",
                      let id = item["tool_use_id"] as? String, let call = toolCalls[id] else { return nil }
                let text = Self.text(of: item["content"])
                return DocumentTools.describe(call.name, call.input, result: text).map(AskEvent.activity)
            }
        case "result":
            done = true
            var events: [AskEvent] = [.usage(usage(from: object))]
            if object["is_error"] as? Bool == true {
                let said = (object["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (object["errors"] as? [String])?.joined(separator: " ")
                    ?? lastText
                sessionMissing = said.localizedCaseInsensitiveContains("no conversation found")
                events.append(.failed(Self.failure(said, subtype: object["subtype"] as? String)))
            } else {
                events.append(.finished)
            }
            return events
        default:
            break
        }
        return []
    }

    private mutating func streamEvent(_ event: [String: Any], since start: Date) -> [AskEvent] {
        switch event["type"] as? String {
        case "message_start":
            if let usage = event.dict("message")?.dict("usage") {
                context = (usage.int("input_tokens") ?? 0) + (usage.int("cache_read_input_tokens") ?? 0)
                    + (usage.int("cache_creation_input_tokens") ?? 0)
            }
            // A new message after a tool: whatever the last one said on the way
            // to the tool is not the answer.
            if answered {
                answered = false
                return [.restart]
            }
        case "content_block_delta":
            guard let delta = event.dict("delta"), delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
            answered = true
            return [.delta(text)]
        default:
            break
        }
        return []
    }

    private func usage(from result: [String: Any]) -> AskUsage {
        let usage = result.dict("usage") ?? [:]
        let cached = usage.int("cache_read_input_tokens")
        let input = (usage.int("input_tokens") ?? 0) + (cached ?? 0) + (usage.int("cache_creation_input_tokens") ?? 0)
        let window = (result.dict("modelUsage")?.values.compactMap { ($0 as? [String: Any])?.int("contextWindow") })?.max()
        return AskUsage(
            input: input, cachedInput: cached, output: usage.int("output_tokens"),
            rounds: max(1, result.int("num_turns") ?? 1),
            seconds: result.int("duration_ms").map { Double($0) / 1000 },
            firstToken: firstToken,
            cost: result["total_cost_usd"] as? Double,
            costSource: "Claude Code",
            context: context, window: window
        )
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        let items = content as? [[String: Any]] ?? []
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func failure(_ said: String, subtype: String?) -> AskFailure {
        let lower = said.lowercased()
        if lower.contains("authenticate") || lower.contains("/login") || lower.contains("log in") || lower.contains("oauth") {
            return AskFailure(
                message: "Claude Code is not signed in. Run `claude` in Terminal once and sign in there.",
                remedy: .signIn
            )
        }
        if subtype == "error_max_budget_usd" {
            return AskFailure(message: "Stopped at the spending cap set for Claude Code.", remedy: .settings)
        }
        return AskFailure(message: said.isEmpty ? "Claude Code did not answer." : said)
    }
}
