// Ask: asking an assistant about a passage, from the tools it reads the
// document with to the card the answer lands in.
//
//   (cd renderer && node build.mjs)
//   TEST_BIN="$(swift build --show-bin-path)"
//   mkdir -p "$OUT/ask" && swiftc -parse-as-library \
//     -I "$TEST_BIN" -I "$TEST_BIN/Modules" -F "$TEST_BIN" \
//     -Xlinker -rpath -Xlinker "$TEST_BIN" \
//     $(find Sources/Imark -name '*.swift' ! -name main.swift) \
//     $(find Sources/ImarkRender -name '*.swift') \
//     Support/test-ask.swift -o "$OUT/ask/run" && "$OUT/ask/run"
//
// A folder of its own, because the renderer is put beside the executable to be
// served from there. Nothing here reaches a real assistant: Claude Code is a
// shell script that prints what the real one printed, and the APIs are a
// stand-in URL protocol. Chats go to a folder of the test's own.

import AppKit
import WebKit

@main
enum AskTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("OK   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)  \(detail())")
        }
    }

    static let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("imark-ask-\(UUID().uuidString)")

    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func waitFor(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { spin(0.02) }
    }

    static func stageRenderer() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let built = repo.appendingPathComponent("Resources")
        guard let beside = Bundle.main.resourceURL else { return }
        for name in ["index.html", "bundle.js", "bundle.css"] {
            let target = beside.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: built.appendingPathComponent(name), to: target)
        }
    }

    static let document = """
    # Event ingestion service

    ## 4.2 Delivery guarantees

    Clients retry a failed request with exponential backoff and full jitter, capped at 30 seconds.

    After five failures the event goes to the dead-letter queue.

    ```sh
    # retry forever
    ```

    ## 4.3 Retention

    Raw events stay in hot storage for 30 days.
    """

    static func main() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stageRenderer()
        ChatStore.folder = folder.appendingPathComponent("chats")
        ClaudeCodeTransport.workingFolder = folder.appendingPathComponent("work")
        // Keys stay in memory: the suite never reads or writes the keychain,
        // which would ask whoever runs it for their password.
        Keychain.inMemory = [:]
        UserDefaults.standard.setVolatileDomain(
            ["askEnabled": true, "askKeepChats": "untilDeleted", "askShowsUsage": true],
            forName: UserDefaults.argumentDomain
        )
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        tools()
        mcpServer()
        prompts()
        claudeStream()
        try claudeProcess()
        try codexProcess()
        openAI()
        openAIWithoutTools()
        anthropic()
        models()
        modelsWindow()
        draftsWindow()
        store()
        try glyph()
        try page()

        // What the transports and the page remembered in this executable's own
        // defaults, which every compiled suite shares.
        for key in ["assistants", "askAssistant"] { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "\nall good" : "\n\(failures) failing")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - The document's tools

    static func tools() {
        let tools = DocumentTools(text: document)
        let outline = tools.outline()
        check("outline lists the headings with their lines",
              outline.contains("L1 # Event ingestion service") && outline.contains("L3 ## 4.2 Delivery guarantees")
                && outline.contains("L13 ## 4.3 Retention"), outline)
        check("a comment in a code block is not a heading", !outline.contains("retry forever"), outline)

        let read = tools.read(from: 5, to: 5)
        check("read numbers the lines from one", read.hasPrefix("L5: Clients retry"), read)
        let clamped = tools.read(from: -3, to: 2)
        check("read keeps to the document", clamped.hasPrefix("L1:") && clamped.contains("L2:") && !clamped.contains("L3:"), clamped)
        let long = DocumentTools(text: (1...500).map { "line \($0)" }.joined(separator: "\n")).read(from: 1, to: 500)
        check("read stops at its limit and says where to go on",
              long.contains("L200: line 200") && !long.contains("L201:") && long.contains("Read again from L201"), String(long.suffix(80)))

        let search = tools.search("BACKOFF")
        check("search ignores case and counts", search.hasPrefix("1 match for") && search.contains("L5:"), search)
        let words = tools.search("retry capped")
        check("search falls back to every word on the line", words.hasPrefix("1 match") && words.contains("L5:"), words)
        check("search says when nothing is found", tools.search("kafka").hasPrefix("0 matches"))

        let call = tools.call("search", ["query": "event"])
        check("a tool call says what it did", call.activity?.text == "Searched for “event” — 3 places", call.activity?.text ?? "nil")
        check("an unknown tool is an error", tools.call("shell", [:]).isError)
        check("read takes numbers as strings", tools.call("read", ["from": "7", "to": 7.0]).text.hasPrefix("L7:"))

        let section = tools.section(around: 4)
        check("the section around a line runs to the next heading of its level",
              section.title == "4.2 Delivery guarantees" && section.range == 2..<12, "\(section)")
    }

    static func mcpServer() {
        let doc = { Optional(document) }
        let hello = AskMCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                              "params": ["protocolVersion": "2025-06-18"]], document: doc)
        let info = (hello?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        check("the server introduces itself", info?["name"] as? String == "imark", "\(hello ?? [:])")
        check("a notification gets no reply",
              AskMCPServer.respond(to: ["jsonrpc": "2.0", "method": "notifications/initialized"], document: doc) == nil)

        let listed = AskMCPServer.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], document: doc)
        let annotated = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }
        check("every tool says it only reads, which Codex asks of a tool it may call unasked", annotated)
        let names = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check("the server offers the three tools and nothing else", names == ["outline", "read", "search"], "\(names)")
        check("the agent pre-approves them by their prefixed names",
              AskMCPServer.qualifiedToolNames == ["mcp__imark__outline", "mcp__imark__read", "mcp__imark__search"])

        let called = AskMCPServer.respond(to: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                               "params": ["name": "read", "arguments": ["from": 13, "to": 13]]], document: doc)
        let text = (((called?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        check("a tool call answers from the document", text == "L13: ## 4.3 Retention", text)

        let unknown = AskMCPServer.respond(to: ["jsonrpc": "2.0", "id": 4, "method": "resources/list"], document: doc)
        check("an unknown method is an error", (unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let unreadable = AskMCPServer.respond(to: ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                                   "params": ["name": "outline"]], document: { nil })
        check("a document that cannot be read is an error, not a crash",
              (unreadable?["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    static func sampleChat(turns: [AskTurn] = [], session: String? = nil) -> AskChat {
        AskChat(
            id: "c-test", document: "/tmp/doc.md", quote: "full jitter", line: 4, end: 5, blockEnd: 5,
            occurrence: 1, section: "4.2 Delivery guarantees", created: Date(), updated: Date(),
            assistant: "claude-code", model: "", session: session, turns: turns
        )
    }

    static func prompts() {
        let tools = DocumentTools(text: document)
        let opening = AskPrompt.opening(for: sampleChat(), question: "Що це?", name: "doc.md", tools: tools, document: .none)
        check("the first message names the passage, its block and the question",
              opening.contains("Selected passage: «full jitter»") && opening.contains("L5: Clients retry")
                && opening.contains("Section: 4.2 Delivery guarantees") && opening.hasSuffix("Question: Що це?"), opening)
        let whole = AskPrompt.opening(for: sampleChat(), question: "Q", name: "doc.md", tools: tools, document: .whole)
        check("a model without tools can be given all of it", whole.contains("L15: Raw events"), whole)
        check("the system prompt is English and asks for the reader's language",
              AskPrompt.system(tools: true).contains("Answer in the language of the user's question"))
        check("the system prompt forbids tool calls written out as text",
              AskPrompt.system(tools: true).contains("Never write a tool call"))
        check("a line written a dozen times over is a loop",
              AskController.isRepeating("Intro\n" + String(repeating: "</table>\n", count: 12))
                && !AskController.isRepeating("Intro\n" + String(repeating: "</table>\n", count: 11))
                && !AskController.isRepeating((1...20).map { "- item \($0)" }.joined(separator: "\n") + "\n"))
        check("a small document fits, a huge one does not",
              AskPrompt.fits(tools, window: 8_000) && !AskPrompt.fits(DocumentTools(text: String(repeating: "word ", count: 200_000)), window: 32_000))
        check("a list of lines in one citation goes too",
              AskController.noteText("Mentioned elsewhere [L393, L516, L729].") == "Mentioned elsewhere.",
              AskController.noteText("Mentioned elsewhere [L393, L516, L729]."))
        check("an answer kept as a note loses its line citations",
              AskController.noteText("Spread out [L5], capped [L40-44] and [L3 – L4].") == "Spread out, capped and.",
              AskController.noteText("Spread out [L5], capped [L40-44] and [L3 – L4]."))
    }

    // MARK: - Claude Code

    /// Recorded from Claude Code's stream-json with the document's tools: one
    /// search, a sentence said on the way to it, then the answer.
    static let claudeLines = [
        #"{"type":"system","subtype":"init","session_id":"sess-1","tools":["mcp__imark__outline","mcp__imark__read","mcp__imark__search"],"model":"claude-sonnet-5"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":1200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look."}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"tu1","name":"mcp__imark__search","input":{"query":"backoff"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"2 matches for “backoff”.\nL5: Clients retry"}]}]}}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":500,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"**Full jitter** spreads retries "}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"out [L5]."}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":4200,"num_turns":2,"result":"**Full jitter** spreads retries out [L5].","session_id":"sess-1","total_cost_usd":0.012,"usage":{"input_tokens":1700,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":120},"modelUsage":{"claude-sonnet-5":{"inputTokens":1700,"outputTokens":120,"contextWindow":200000,"costUSD":0.012}}}"#,
    ]

    static func claudeStream() {
        var parser = ClaudeStreamParser()
        var events: [AskEvent] = []
        for line in claudeLines { events += parser.feed(line, since: Date()) }
        check("the session is picked up", events.first == .session("sess-1"), "\(events.first.map { "\($0)" } ?? "none")")
        check("what was said on the way to a tool is thrown away", events.contains(.restart))
        check("the tool call becomes a line in the chat",
              events.contains(.activity(AskActivity(kind: .search, text: "Searched for “backoff” — 2 places"))))
        let text = events.reduce(into: "") { text, event in
            if case .delta(let piece) = event { text += piece }
            if case .restart = event { text = "" }
        }
        check("the answer arrives in pieces", text == "**Full jitter** spreads retries out [L5].", text)
        guard case .usage(let usage)? = events.dropLast().last else { return check("the result carries the usage", false, "\(events)") }
        check("the usage counts the cache as input and keeps the price", usage.input == 2_700 && usage.cachedInput == 1_000
            && usage.output == 120 && usage.cost == 0.012 && usage.rounds == 2 && usage.costSource == "Claude Code", "\(usage)")
        check("the context is the last request's, of the model's window", usage.context == 1_500 && usage.window == 200_000, "\(usage)")
        check("the answer finishes", events.last == .finished)

        var toolless = ClaudeStreamParser()
        let bare = toolless.feed(#"{"type":"system","subtype":"init","session_id":"s","tools":[],"mcp_servers":[{"name":"imark","status":"pending"}]}"#, since: Date())
        check("without the document's tools the question never reaches the model",
              { if case .failed(let f)? = bare.last { return f.message.contains("did not reach Claude Code") }; return false }() && toolless.done,
              "\(bare)")

        var failing = ClaudeStreamParser()
        let auth = failing.feed(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}"#, since: Date())
            + failing.feed(#"{"type":"result","subtype":"success","is_error":true,"result":"","num_turns":1,"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#, since: Date())
        guard case .failed(let failure)? = auth.last else { return check("a signed-out agent fails", false, "\(auth)") }
        check("a signed-out agent says how to sign in", failure.remedy == .signIn && failure.message.contains("claude"), failure.message)
    }

    static func fakeClaude(_ lines: [String]) throws -> URL { try fakeAgent("claude", lines) }

    /// A stand-in for an agent's command: it keeps what it was given and
    /// prints what the real one printed.
    static func fakeAgent(_ name: String, _ lines: [String], stderr: String = "", status: Int = 0) throws -> URL {
        let dir = folder.appendingPathComponent("fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("out.jsonl"), atomically: true, encoding: .utf8)
        try stderr.write(to: dir.appendingPathComponent("err.txt"), atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent(name)
        try """
        #!/bin/sh
        cat > "\(dir.path)/stdin.txt"
        for a in "$@"; do printf '%s\\n' "$a"; done > "\(dir.path)/args.txt"
        pwd > "\(dir.path)/pwd.txt"
        env > "\(dir.path)/env.txt"
        cat "\(dir.path)/out.jsonl"
        cat "\(dir.path)/err.txt" >&2
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func run(_ transport: AskTransport, _ request: AskRequest) -> [AskEvent] {
        var events: [AskEvent] = []
        transport.start(request) { events.append($0) }
        waitFor(10) {
            events.contains { if case .finished = $0 { return true }; if case .failed = $0 { return true }; return false }
        }
        return events
    }

    static func claudeProcess() throws {
        let script = try fakeClaude(claudeLines)
        Assistants.locations["claude"] = script
        ClaudeCodeTransport.mcpExecutable = "/Applications/Imark.app/Contents/MacOS/Imark"
        let doc = folder.appendingPathComponent("doc.md")
        try document.write(to: doc, atomically: true, encoding: .utf8)
        let assistant = Assistant(id: "claude-code", kind: .claudeCode, name: "Claude Code", model: "haiku", spendingCap: 0.5)

        let events = run(ClaudeCodeTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "-What is it?", document: doc, text: document))
        check("Claude Code answers through the process", events.last == .finished, "\(events.suffix(2))")
        let dir = script.deletingLastPathComponent()
        let args = (try? String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args.indices.contains($0 + 1) ? args[$0 + 1] : "" } }
        check("its own tools are off", value(after: "--tools") == "", "\(args)")
        check("the reader's settings and hooks are not loaded", value(after: "--setting-sources") == "")
        check("the document's server is the only one", args.contains("--strict-mcp-config")
            && (value(after: "--mcp-config") ?? "").contains("--ask-mcp") && (value(after: "--mcp-config") ?? "").contains(doc.path))
        check("only the document's tools are pre-approved",
              value(after: "--allowedTools") == "mcp__imark__outline,mcp__imark__read,mcp__imark__search")
        check("its system prompt is Ask's", (value(after: "--system-prompt") ?? "").contains("Markdown reader"))
        check("the model and the cap go along", value(after: "--model") == "haiku" && value(after: "--max-budget-usd") == "0.5")
        check("a first question starts a new session", value(after: "--resume") == nil)
        let stdin = (try? String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        check("the question goes in on standard input, dash and all",
              stdin.contains("Selected passage: «full jitter»") && stdin.hasSuffix("Question: -What is it?") && !args.contains("-What is it?"), stdin)
        let pwd = (try? String(contentsOf: dir.appendingPathComponent("pwd.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        check("it runs in a folder of its own", pwd.hasSuffix("/work"), pwd)
        let env = (try? String(contentsOf: dir.appendingPathComponent("env.txt"), encoding: .utf8)) ?? ""
        check("it waits for the document's tools before it asks the model",
              env.components(separatedBy: "\n").contains("MCP_CONNECTION_NONBLOCKING=0"))

        let earlier = [AskTurn(question: "First?", answer: "First answer.")]
        let followUp = run(ClaudeCodeTransport(), AskRequest(assistant: assistant, chat: sampleChat(turns: earlier, session: "sess-1"),
                                                              question: "And then?", document: doc, text: document))
        let again = (try? String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        let resumed = again.firstIndex(of: "--resume").map { again[$0 + 1] }
        let followStdin = (try? String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        check("a follow-up continues the session with only the question",
              followUp.last == .finished && resumed == "sess-1" && followStdin == "And then?", "\(resumed ?? "nil") \(followStdin)")

        // A session Claude Code has cleared away: asked again with the chat
        // written out.
        let gone = try fakeClaude([
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: sess-old"],"num_turns":0,"usage":{}}"#,
        ])
        Assistants.locations["claude"] = gone
        var events2: [AskEvent] = []
        let transport = ClaudeCodeTransport()
        transport.start(AskRequest(assistant: assistant, chat: sampleChat(turns: earlier, session: "sess-old"),
                                   question: "And then?", document: doc, text: document)) { events2.append($0) }
        waitFor(10) { events2.contains { if case .failed = $0 { return true }; return false } }
        let retryStdin = (try? String(contentsOf: gone.deletingLastPathComponent().appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        let retryArgs = (try? String(contentsOf: gone.deletingLastPathComponent().appendingPathComponent("args.txt"), encoding: .utf8)) ?? ""
        check("a lost session is asked again with the chat written out",
              retryStdin.contains("Your answer: First answer.") && retryStdin.hasSuffix("Question: And then?") && !retryArgs.contains("--resume"),
              retryStdin)

        Assistants.locations["claude"] = folder.appendingPathComponent("nowhere/claude")
        let missing = run(ClaudeCodeTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        if case .failed(let failure)? = missing.last {
            check("a missing executable says so", failure.message.contains("could not be started") || failure.remedy == .install, failure.message)
        } else {
            check("a missing executable says so", false, "\(missing)")
        }
        Assistants.locations["claude"] = script
    }

    // MARK: - Codex

    static let codexLines = [
        #"{"type":"thread.started","thread_id":"th-1"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Looking**"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Let me search."}}"#,
        #"{"type":"item.started","item":{"id":"item_2","type":"mcp_tool_call","server":"imark","tool":"search","arguments":{"query":"backoff"},"result":null,"error":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"mcp_tool_call","server":"imark","tool":"search","arguments":{"query":"backoff"},"result":{"content":[{"type":"text","text":"2 matches for “backoff”.\nL5: Clients retry"}],"structured_content":null},"error":null,"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"**Full jitter** spreads retries out [L5]."}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"cache_write_input_tokens":0,"output_tokens":122,"reasoning_output_tokens":64}}"#,
    ]

    /// The answer as the page would build it from the events.
    static func answer(of events: [AskEvent]) -> String {
        events.reduce("") { text, event in
            switch event {
            case .delta(let part): return text + part
            case .restart: return ""
            default: return text
            }
        }
    }

    static func codexProcess() throws {
        var parser = CodexStreamParser()
        var events: [AskEvent] = []
        for line in codexLines { events += parser.feed(line, since: Date()) }
        check("Codex's thread becomes the chat's session", events.first == .session("th-1"), "\(events.first.map { "\($0)" } ?? "nil")")
        check("what it said on the way to a tool is not the answer",
              answer(of: events) == "**Full jitter** spreads retries out [L5]." && events.contains(.restart), answer(of: events))
        check("the search it made is told",
              events.contains { if case .activity(let a) = $0 { return a.text == "Searched for “backoff” — 2 places" }; return false })
        let usage = events.compactMap { if case .usage(let u) = $0 { return u }; return nil }.first
        check("its figures are taken as they come for a new session, with no cost made up",
              usage?.input == 24_763 && usage?.cachedInput == 24_448 && usage?.output == 122 && usage?.reasoning == 64
                && usage?.rounds == 2 && usage?.cost == nil && usage?.firstToken == nil && usage?.sessionTotal?.input == 24_763,
              "\(usage.map { "\($0)" } ?? "nil")")
        check("and it ends", events.last == .finished && parser.done)

        var next = CodexStreamParser(resuming: true, before: AskUsage.SessionTotal(input: 24_763, cachedInput: 24_448, output: 122, reasoning: 64))
        let more = next.feed(#"{"type":"turn.completed","usage":{"input_tokens":50000,"cached_input_tokens":49000,"output_tokens":300,"reasoning_output_tokens":100}}"#, since: Date())
        let added = more.compactMap { if case .usage(let u) = $0 { return u }; return nil }.first
        check("a follow-up's figures are what it added to the session's sum",
              added?.input == 25_237 && added?.cachedInput == 24_552 && added?.output == 178 && added?.reasoning == 36 && added?.sessionTotal?.input == 50_000,
              "\(added.map { "\($0)" } ?? "nil")")

        check("a value for -c is a TOML string", CodexTransport.toml("a \"b\" \\ c\nd") == #""a \"b\" \\ c\nd""#, CodexTransport.toml("a \"b\" \\ c\nd"))

        let script = try fakeAgent("codex", codexLines)
        Assistants.locations["codex"] = script
        CodexTransport.mcpExecutable = "/Applications/Imark.app/Contents/MacOS/Imark"
        let doc = folder.appendingPathComponent("doc.md")
        try document.write(to: doc, atomically: true, encoding: .utf8)
        let assistant = Assistant(id: "codex", kind: .codex, name: "Codex", model: "gpt-6-sol")
        let ran = run(CodexTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "-What is it?", document: doc, text: document))
        check("Codex answers through the process", ran.last == .finished && answer(of: ran).hasPrefix("**Full jitter**"), "\(ran.suffix(2))")
        let dir = script.deletingLastPathComponent()
        let args = (try? String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let settings = args.indices.filter { args[$0] == "-c" && args.indices.contains($0 + 1) }.map { args[$0 + 1] }
        check("it runs exec with JSON out, without the reader's config, read-only",
              args.first == "exec" && args.contains("--json") && args.contains("--ignore-user-config") && args.contains("--skip-git-repo-check")
                && args.firstIndex(of: "--sandbox").map { args[$0 + 1] } == "read-only", "\(args)")
        let server = settings.first { $0.hasPrefix("mcp_servers.imark=") } ?? ""
        check("the document's server is required and its tools need no approval",
              server.contains(#"command="/Applications/Imark.app/Contents/MacOS/Imark""#) && server.contains(#"args=["--ask-mcp", "\#(doc.path)"]"#)
                && server.contains("required=true") && server.contains(#"default_tools_approval_mode="approve""#), server)
        check("its shell and the rest of its own tools are off",
              ["features.shell_tool=false", "features.view_image=false", "features.apps=false", "features.plugins=false", #"web_search="disabled""#, "agents.enabled=false"]
                .allSatisfy(settings.contains), "\(settings)")
        check("Ask's rules go in as its developer instructions",
              settings.contains { $0.hasPrefix("developer_instructions=") && $0.contains("Markdown reader") })
        check("the model goes along, and the question comes on standard input",
              args.firstIndex(of: "--model").map { args[$0 + 1] } == "gpt-6-sol" && args.last == "-" && !args.contains("resume"))
        let stdin = (try? String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        check("the first question carries the passage", stdin.contains("Selected passage: «full jitter»") && stdin.hasSuffix("Question: -What is it?"), stdin)
        let pwd = (try? String(contentsOf: dir.appendingPathComponent("pwd.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        check("in the same folder of its own", pwd.hasSuffix("/work"), pwd)

        var earlier = [AskTurn(question: "First?", answer: "First answer.")]
        earlier[0].usage = AskUsage(input: 10, rounds: 1, sessionTotal: AskUsage.SessionTotal(input: 24_000, cachedInput: 0, output: 100, reasoning: 0))
        let followUp = run(CodexTransport(), AskRequest(assistant: assistant, chat: sampleChat(turns: earlier, session: "th-1"),
                                                        question: "And then?", document: doc, text: document))
        let again = (try? String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let followStdin = (try? String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        let followUsage = followUp.compactMap { if case .usage(let u) = $0 { return u }; return nil }.first
        check("a follow-up resumes the thread with only the question, its settings given again",
              again.suffix(3) == ["resume", "th-1", "-"] && followStdin == "And then?" && again.contains { $0.hasPrefix("mcp_servers.imark=") },
              "\(again.suffix(3)) \(followStdin)")
        check("and counts only what it added", followUsage?.input == 763 && followUsage?.output == 22, "\(followUsage.map { "\($0)" } ?? "nil")")

        let gone = try fakeAgent("codex", [#"{"type":"turn.failed","error":{"message":"thread th-old not found"}}"#], status: 1)
        Assistants.locations["codex"] = gone
        var lost: [AskEvent] = []
        let transport = CodexTransport()
        transport.start(AskRequest(assistant: assistant, chat: sampleChat(turns: earlier, session: "th-old"),
                                   question: "And then?", document: doc, text: document)) { lost.append($0) }
        waitFor(10) { lost.contains { if case .failed = $0 { return true }; return false } }
        let retryStdin = (try? String(contentsOf: gone.deletingLastPathComponent().appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? ""
        let retryArgs = (try? String(contentsOf: gone.deletingLastPathComponent().appendingPathComponent("args.txt"), encoding: .utf8)) ?? ""
        check("a thread Codex no longer has is asked again with the chat written out",
              retryStdin.contains("Your answer: First answer.") && retryStdin.hasSuffix("Question: And then?") && !retryArgs.contains("resume"), retryStdin)

        Assistants.locations["codex"] = try fakeAgent("codex", [
            #"{"type":"thread.started","thread_id":"th-2"}"#,
            #"{"type":"error","message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"}"#,
            #"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"}}"#,
        ], status: 1)
        let unsigned = run(CodexTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        if case .failed(let failure)? = unsigned.last {
            check("signed out, it says how to sign in", failure.remedy == .signIn && failure.message.contains("codex login"), failure.message)
        } else {
            check("signed out, it says how to sign in", false, "\(unsigned)")
        }
        Assistants.locations["codex"] = try fakeAgent("codex", [], stderr: "Error: required MCP servers failed to initialize: imark: handshake failed\n", status: 1)
        let toolless = run(CodexTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        if case .failed(let failure)? = toolless.last {
            check("without the document's tools it is not asked at all", failure.message.contains("document tools could not start"), failure.message)
        } else {
            check("without the document's tools it is not asked at all", false, "\(toolless)")
        }

        let saved = Settings.assistantsData
        // As a bug of the window's once left it: Claude Code with an API's
        // name and address, and Codex never listed.
        Assistants.all = [
            Assistant(id: "claude-code", kind: .claudeCode, name: "OpenAI", model: "opus", baseURL: "https://api.openai.com/v1"),
            Assistant(id: "api-x", kind: .openAI, name: "X", baseURL: "https://x.example/v1"),
        ]
        check("an agent is always called by its own name, with no address",
              Assistants.assistant("claude-code").map { $0.name == "Claude Code" && $0.baseURL.isEmpty && $0.model == "opus" } == true,
              "\(Assistants.assistant("claude-code").map { "\($0.name) \($0.baseURL)" } ?? "nil")")
        Assistants.locations["codex"] = .some(nil)
        check("Codex is listed even before it is installed, after Claude Code",
              Assistants.all.map(\.id) == ["claude-code", "codex", "api-x"] && Assistants.assistant("codex")?.isInstalled == false,
              "\(Assistants.all.map(\.id))")
        check("but no question goes to it until it is", !Assistants.enabled.contains { $0.id == "codex" })
        check("and the window says how to get it", Assistants.installHint(for: .codex).contains("brew install --cask codex")
              && Assistants.installHint(for: .codex).contains("codex login"))
        Assistants.locations["codex"] = script
        check("found where such tools are installed, its path is filled in to keep or change",
              Assistants.assistant("codex")?.path == script.path && Assistants.enabled.contains { $0.id == "codex" })

        // A path set by hand is what runs, wherever the command would be found.
        let app = try fakeApp()
        let inside = Assistants.bundledExecutable(in: app, named: "codex")
        check("an app chosen for Codex gives the codex inside it, the nearest one",
              inside?.resolvingSymlinksInPath().path == app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").resolvingSymlinksInPath().path,
              inside?.path ?? "nil")
        check("and nothing when it has none", Assistants.bundledExecutable(in: app, named: "claude") == nil)
        check("what it is, it says itself", inside.flatMap(Assistants.version(of:)) == "codex-cli 9.9.9")
        Assistants.locations["codex"] = .some(nil)
        var chosen = assistant
        chosen.path = script.path
        check("a path set for it is what runs", run(CodexTransport(), AskRequest(assistant: chosen, chat: sampleChat(), question: "Q", document: doc, text: document)).last == .finished)
        let unset = run(CodexTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        if case .failed(let failure)? = unset.last {
            check("with no path it says where to set one", failure.remedy == .settings && failure.message.contains("choose its executable"), failure.message)
        } else {
            check("with no path it says where to set one", false, "\(unset)")
        }
        Settings.assistantsData = saved
        Assistants.locations.removeValue(forKey: "codex")
    }

    /// An app with Codex inside, laid out as ChatGPT.app has it.
    static func fakeApp() throws -> URL {
        let app = folder.appendingPathComponent("fake-\(UUID().uuidString)/ChatGPT.app")
        for place in ["Contents/Resources/codex-cli/bin", "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"] {
            let dir = app.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("codex")
            try "#!/bin/sh\necho 'codex-cli 9.9.9'\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return app
    }

    // MARK: - APIs

    final class Stub: URLProtocol {
        static var replies: [(status: Int, body: String)] = []
        static var requests: [(url: URL, headers: [String: String], body: [String: Any])] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
            }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            Stub.requests.append((request.url!, request.allHTTPHeaderFields ?? [:], body))
            let reply = Stub.replies.isEmpty ? (status: 500, body: "no reply left") : Stub.replies.removeFirst()
            // Status 0 is a server that is not there.
            if reply.status == 0 {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static func useStub(_ replies: [(Int, String)]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        AskTransports.session = URLSession(configuration: configuration)
        Stub.replies = replies.map { (status: $0.0, body: $0.1) }
        Stub.requests = []
    }

    static func sse(_ chunks: [String]) -> String {
        chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }

    static func openAI() {
        useStub([
            (200, sse([
                #"{"choices":[{"delta":{"role":"assistant","content":"Looking."}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":""}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"backoff\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                #"{"choices":[],"usage":{"prompt_tokens":900,"completion_tokens":20,"cost":0.001}}"#,
            ])),
            (200, sse([
                #"{"choices":[{"delta":{"content":"It spreads retries "}}]}"#,
                #"{"choices":[{"delta":{"content":"out [L5]."},"finish_reason":"stop"}]}"#,
                #"{"choices":[],"usage":{"prompt_tokens":1100,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":800},"cost":0.002}}"#,
            ])),
        ])
        let assistant = Assistant(id: "api-test", kind: .openAI, name: "OpenRouter", model: "some/model", baseURL: "https://openrouter.ai/api/v1")
        let doc = folder.appendingPathComponent("doc.md")
        let events = run(OpenAITransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "What?", document: doc, text: document))

        check("an API answer finishes", events.last == .finished, "\(events.suffix(3))")
        check("it goes to chat/completions", Stub.requests.first?.url.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        let first = Stub.requests.first?.body ?? [:]
        check("the tools go with the first request, and usage is asked for",
              (first["tools"] as? [[String: Any]])?.count == 3 && (first["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        let second = Stub.requests.dropFirst().first?.body["messages"] as? [[String: Any]] ?? []
        let toolReply = second.last { $0["role"] as? String == "tool" }
        check("the tool runs here and its result goes back",
              toolReply?["tool_call_id"] as? String == "call_1" && (toolReply?["content"] as? String ?? "").hasPrefix("1 match for “backoff”"),
              "\(toolReply ?? [:])")
        check("the call is in the history the way the API wants it",
              ((second.first { $0["tool_calls"] != nil }?["tool_calls"]) as? [[String: Any]])?.first?["id"] as? String == "call_1")
        check("the search shows in the chat", events.contains(.activity(AskActivity(kind: .search, text: "Searched for “backoff” — 1 place"))))
        check("what came before the tool is dropped", events.contains(.restart))
        guard let usage = events.compactMap({ if case .usage(let u) = $0 { return u }; return nil }).last else {
            return check("usage is reported", false)
        }
        check("usage adds up both requests", usage.input == 2_000 && usage.output == 50 && usage.cachedInput == 800 && usage.rounds == 2, "\(usage)")
        check("OpenRouter's cost is summed and credited", abs((usage.cost ?? 0) - 0.003) < 1e-9 && usage.costSource == "openrouter.ai", "\(usage)")
        check("the context is the last request's", usage.context == 1_130, "\(usage)")
    }

    static func openAIWithoutTools() {
        Assistants.all = [Assistant(id: "api-local", kind: .openAI, name: "LM Studio", model: "qwen", baseURL: "http://localhost:1234/v1")]
        useStub([
            (400, #"{"error":{"message":"This model does not support tools"}}"#),
            (200, sse([
                #"{"choices":[{"delta":{"content":"Random waits."},"finish_reason":"stop"}]}"#,
                #"{"choices":[],"usage":{"prompt_tokens":300,"completion_tokens":5}}"#,
            ])),
        ])
        let assistant = Assistants.assistant("api-local")!
        let doc = folder.appendingPathComponent("doc.md")
        let events = run(OpenAITransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "What?", document: doc, text: document))
        spin(0.2)
        check("a model that refuses tools is asked again without", events.last == .finished && Stub.requests.count == 2, "\(events)")
        let retried = Stub.requests.last?.body ?? [:]
        let opening = ((retried["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "user" }?["content"] as? String) ?? ""
        check("and is given the document instead", retried["tools"] == nil && opening.contains("L15: Raw events"), opening)
        check("the refusal is remembered", Assistants.assistant("api-local")?.refusesTools == true)
        let usage = events.compactMap { if case .usage(let u) = $0 { return u }; return nil }.last
        check("a model on this Mac costs nothing", usage?.local == true && usage?.cost == nil, "\(usage.map { "\($0)" } ?? "nil")")

        useStub([(401, #"{"error":{"message":"Invalid API key"}}"#)])
        let refused = run(OpenAITransport(), AskRequest(assistant: Assistant(id: "api-x", kind: .openAI, name: "OpenAI", model: "m", baseURL: "https://api.openai.com/v1"),
                                                         chat: sampleChat(), question: "Q", document: doc, text: document))
        if case .failed(let failure)? = refused.last {
            check("a refused key points at Settings", failure.remedy == .settings && failure.message.contains("refused the key"), failure.message)
        } else {
            check("a refused key points at Settings", false, "\(refused)")
        }
        let noModel = run(OpenAITransport(), AskRequest(assistant: Assistant(id: "api-y", kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1"),
                                                         chat: sampleChat(), question: "Q", document: doc, text: document))
        check("no model is asked for before anything is sent", { if case .failed(let f)? = noModel.last { return f.remedy == .settings }; return false }())
    }

    static func anthropic() {
        Keychain.removeKey(for: "api-anthropic-test")
        let doc = folder.appendingPathComponent("doc.md")
        let assistant = Assistant(id: "api-anthropic-test", kind: .anthropic, name: "Anthropic API", model: "claude-sonnet-5")
        useStub([])
        let keyless = run(AnthropicTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        check("Anthropic's API asks for a key first", { if case .failed(let f)? = keyless.last { return f.remedy == .settings }; return false }() && Stub.requests.isEmpty)

        Keychain.setKey("sk-test", for: assistant.id)
        defer { Keychain.removeKey(for: assistant.id) }
        let events: [String] = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":700,"cache_read_input_tokens":300}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"read","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"from\":5,"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"to\":5}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}"#,
        ]
        let answer: [String] = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":900}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Random waits [L5]."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
        ]
        useStub([(200, events.map { "event: x\ndata: \($0)\n\n" }.joined()), (200, answer.map { "data: \($0)\n\n" }.joined())])
        let got = run(AnthropicTransport(), AskRequest(assistant: assistant, chat: sampleChat(), question: "Q", document: doc, text: document))
        check("Anthropic's API answers after a tool", got.last == .finished && got.contains(.activity(AskActivity(kind: .read, text: "Read line 5"))), "\(got)")
        check("the keychain was never asked", Keychain.inMemory?["api-anthropic-test"] == "sk-test")
        check("the key and the version go in its headers",
              Stub.requests.first?.headers["x-api-key"] == "sk-test" && Stub.requests.first?.headers["anthropic-version"] == "2023-06-01")
        let second = Stub.requests.last?.body["messages"] as? [[String: Any]] ?? []
        let results = second.last?["content"] as? [[String: Any]]
        check("the tool result goes back as a tool_result block",
              results?.first?["tool_use_id"] as? String == "tu_1" && (results?.first?["content"] as? String) == "L5: Clients retry a failed request with exponential backoff and full jitter, capped at 30 seconds.",
              "\(results ?? [])")
        let usage = got.compactMap { if case .usage(let u) = $0 { return u }; return nil }.last
        check("its usage is split across start and end, and added up", usage?.input == 1_900 && usage?.output == 24 && usage?.cachedInput == 300, "\(usage.map { "\($0)" } ?? "nil")")
    }

    // MARK: - The models an API lists

    static let openRouterModels = """
    {"data":[
     {"id":"openai/gpt-5-mini","context_length":400000,"architecture":{"output_modalities":["text"]},
      "pricing":{"prompt":"0.00000025","completion":"0.000002"},"supported_parameters":["tools","max_tokens"]},
     {"id":"google/gemini-2.5-flash-image","context_length":32768,"architecture":{"output_modalities":["image","text"]},
      "pricing":{"prompt":"0.0000003","completion":"0.0000025"},"supported_parameters":["max_tokens"]},
     {"id":"black-forest-labs/flux","architecture":{"output_modalities":["image"]}},
     {"id":"openrouter/auto","context_length":2000000,"pricing":{"prompt":"-1","completion":"-1"}},
     {"id":"meta-llama/llama-3.3-8b-instruct:free","context_length":131072,
      "pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]}
    ]}
    """

    static func models() {
        let openAIList = #"{"object":"list","data":[{"id":"gpt-5-mini","object":"model"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},"#
            + #"{"id":"gpt-4o-mini-tts"},{"id":"dall-e-3"},{"id":"gpt-5"},{"id":"omni-moderation-latest"},{"id":"gpt-5"}]}"#
        check("OpenAI's list keeps the chat models, once each, in order",
              ModelCatalog.parse(Data(openAIList.utf8))?.map(\.id) == ["gpt-5", "gpt-5-mini"],
              "\(ModelCatalog.parse(Data(openAIList.utf8))?.map(\.id) ?? [])")

        let routed = ModelCatalog.parse(Data(openRouterModels.utf8)) ?? []
        check("OpenRouter's list leaves out what only draws, and is in order of the name after the last slash",
              routed.map(\.id) == ["openrouter/auto", "google/gemini-2.5-flash-image", "openai/gpt-5-mini", "meta-llama/llama-3.3-8b-instruct:free"],
              "\(routed.map(\.id))")
        let named = #"{"data":[{"id":"z-ai/glm-5"},{"id":"~deepseek/deepseek-v4-flash-latest"},{"id":"openai/gpt-10"},"#
            + #"{"id":"openai/gpt-5"},{"id":"anthropic/claude-sonnet-5"},{"id":"azure/gpt-5"}]}"#
        check("names are compared as people read them: case aside, numbers in order, the provider last",
              ModelCatalog.parse(Data(named.utf8))?.map(\.id)
                == ["anthropic/claude-sonnet-5", "~deepseek/deepseek-v4-flash-latest", "z-ai/glm-5", "azure/gpt-5", "openai/gpt-5", "openai/gpt-10"],
              "\(ModelCatalog.parse(Data(named.utf8))?.map(\.id) ?? [])")
        let mini = routed.first { $0.id == "openai/gpt-5-mini" }
        check("and says what it knows about a model",
              mini?.contextWindow == 400_000 && mini?.takesTools == true && mini?.inputPrice == 0.25 && mini?.outputPrice == 2,
              "\(mini.map { "\($0)" } ?? "nil")")
        check("in a line under the field",
              mini.flatMap(ModelCatalog.summary(of:)) == "400K tokens of context · takes tools · $0.25 in, $2 out per million tokens",
              mini.flatMap(ModelCatalog.summary(of:)) ?? "nil")
        let free = routed.first { $0.id.hasSuffix(":free") }
        check("a free model says so, and 131072 tokens read as 128K",
              free.flatMap(ModelCatalog.summary(of:)) == "128K tokens of context · takes tools · free", free.flatMap(ModelCatalog.summary(of:)) ?? "nil")
        check("a model without tools is known by it", routed.first { $0.id.contains("gemini") }?.takesTools == false)
        check("the router's price of -1 is no price", routed.first { $0.id == "openrouter/auto" }?.inputPrice == nil)
        let together = #"[{"id":"meta-llama/Llama-3-70b","type":"chat","context_length":8192},{"id":"BAAI/bge-large","type":"embedding"}]"#
        check("Together's bare list is read too, without its embeddings",
              ModelCatalog.parse(Data(together.utf8))?.map(\.id) == ["meta-llama/Llama-3-70b"])
        check("something else is no list", ModelCatalog.parse(Data("<html>".utf8)) == nil && ModelCatalog.parse(Data(#"{"error":"x"}"#.utf8)) == nil)
        check("token counts read the way windows are named",
              [131_072, 200_000, 1_048_576, 1_000_000, 32_768, 1_500].map(ModelCatalog.tokens) == ["128K", "200K", "1M", "1M", "32K", "1.5K"],
              "\([131_072, 200_000, 1_048_576, 1_000_000, 32_768, 1_500].map(ModelCatalog.tokens))")

        let names = ["anthropic/claude-haiku-4.5", "anthropic/claude-sonnet-5", "openai/gpt-5", "x/claude"].map { ModelInfo(id: $0) }
        check("typing finds a model by any part of its name, the closest first",
              ModelCatalog.matching("claude", in: names).map(\.id) == ["x/claude", "anthropic/claude-haiku-4.5", "anthropic/claude-sonnet-5"],
              "\(ModelCatalog.matching("claude", in: names).map(\.id))")
        check("every word typed has to be in it, in any case",
              ModelCatalog.matching("SON 5", in: names).map(\.id) == ["anthropic/claude-sonnet-5"] && ModelCatalog.matching("", in: names).count == 4)

        check("an address without a scheme gets https, and a pasted endpoint goes",
              Assistants.normalizedAddress(" api.groq.com/openai/v1/chat/completions/ ", kind: .openAI) == "https://api.groq.com/openai/v1",
              Assistants.normalizedAddress(" api.groq.com/openai/v1/chat/completions/ ", kind: .openAI))
        check("one on this Mac gets http",
              Assistants.normalizedAddress("localhost:1234/v1/models", kind: .openAI) == "http://localhost:1234/v1",
              Assistants.normalizedAddress("localhost:1234/v1/models", kind: .openAI))
        check("Anthropic's address loses the /v1 Imark adds",
              Assistants.normalizedAddress("https://api.anthropic.com/v1/messages", kind: .anthropic) == "https://api.anthropic.com"
                && Assistants.normalizedAddress("https://api.anthropic.com/v1", kind: .anthropic) == "https://api.anthropic.com")

        check("a whole number field keeps the digits of whatever is pasted",
              NumberFieldFormatter.kept("128,000 tokens", decimals: false) == "128000" && NumberFieldFormatter.kept("abc", decimals: false).isEmpty)
        check("a decimal one keeps one separator", NumberFieldFormatter.kept("$1,5.2x", decimals: true) == "1,52")

        let router = Assistant(id: "api-or", kind: .openAI, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1")
        let keyless = ModelCatalog.request(for: router, key: nil)
        check("the list is asked for at /models, without a key when there is none",
              keyless?.url?.absoluteString == "https://openrouter.ai/api/v1/models" && keyless?.value(forHTTPHeaderField: "Authorization") == nil)
        check("and with it when there is", ModelCatalog.request(for: router, key: "sk-or")?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or")
        let claude = ModelCatalog.request(for: Assistant(id: "a", kind: .anthropic, name: "Anthropic API"), key: "sk-ant")
        check("Anthropic's list is asked for its way",
              claude?.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000"
                && claude?.value(forHTTPHeaderField: "x-api-key") == "sk-ant" && claude?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01",
              claude?.url?.absoluteString ?? "nil")
        check("no address, nothing to ask", ModelCatalog.request(for: Assistant(id: "b", kind: .openAI, name: "API"), key: nil) == nil)

        func fetched(_ reply: (Int, String), _ assistant: Assistant = router, key: String? = nil) -> Result<[ModelInfo], Error> {
            useStub([reply])
            var result: Result<[ModelInfo], Error>?
            Task {
                do { result = .success(try await ModelCatalog.fetch(ModelCatalog.request(for: assistant, key: key)!)) } catch { result = .failure(error) }
            }
            waitFor(5) { result != nil }
            return result ?? .failure(ModelCatalog.Failure(message: "no answer"))
        }
        func said(_ result: Result<[ModelInfo], Error>, _ assistant: Assistant = router, sentKey: Bool = false) -> String {
            if case .failure(let error) = result { return ModelCatalog.message(for: error, assistant: assistant, sentKey: sentKey) }
            return "no failure"
        }
        check("a list comes back through the session", (try? fetched((200, openRouterModels)).get())?.count == 4)
        check("a list that needs a key says so", said(fetched((401, "{}"))) == "The server wants the API key first.")
        check("a refused key says so", said(fetched((401, "{}"), key: "sk"), sentKey: true) == "The server refused the key.")
        let local = Assistant(id: "c", kind: .openAI, name: "LM Studio", baseURL: "http://localhost:1234/v1")
        check("a server on this Mac that is not running is asked about",
              said(fetched((0, ""), local), local) == "Nothing answers at localhost:1234. Is the server running?", said(fetched((0, ""), local), local))
        check("a web page where the API should be points at the address",
              said(fetched((200, "<html>OpenRouter</html>"))) == "The answer was not a list of models. Check that it is the API's address, which usually ends in /v1.",
              said(fetched((200, "<html>OpenRouter</html>"))))

        ModelCatalog.folder = folder.appendingPathComponent("models")
        let list = ModelCatalog.Saved(address: router.baseURL, fetched: Date(timeIntervalSince1970: 1_000), models: routed)
        ModelCatalog.save(list, for: "api-or")
        check("a fetched list is kept until the next", ModelCatalog.saved(for: "api-or") == list)
        ModelCatalog.forget("api-or")
        check("and goes with its assistant", ModelCatalog.saved(for: "api-or") == nil)
        ModelCatalog.save(list, for: "../escape")
        check("an id that is not a name writes nothing", !FileManager.default.fileExists(atPath: folder.appendingPathComponent("escape.json").path))
    }

    static func modelsWindow() {
        let saved = Settings.assistantsData
        Keychain.inMemory = [:]
        Assistants.all = [
            Assistant(id: "api-or", kind: .openAI, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", tools: .auto, refusesTools: true, contextWindow: 9_000),
            Assistant(id: "api-lm", kind: .openAI, name: "LM Studio", baseURL: "http://localhost:1234/v1"),
            Assistant(id: "api-ol", kind: .openAI, name: "Ollama", baseURL: "http://localhost:11434/v1"),
        ]
        let controller = AssistantsWindowController.shared
        controller.showWindow(nil)
        guard let window = controller.window else { return check("the Assistants window opens", false) }
        func note() -> String { controller.modelNote?.stringValue ?? "nil" }
        func type(_ text: String, into field: NSControl, replacing: Bool = true, end: Bool = true) {
            window.makeFirstResponder(field)
            let editor = window.fieldEditor(false, for: field) as? NSTextView
            if replacing { editor?.selectAll(nil) }
            editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
            if end { window.makeFirstResponder(nil) }
        }
        func press(_ button: NSButton?) {
            button?.performClick(nil)
            waitFor(3) { controller.getModelsButton?.isEnabled == true }
        }

        useStub([(200, openRouterModels)])
        controller.select("api-or")
        spin(0.2)
        check("nothing is asked of a server until Get Models is pressed",
              Stub.requests.isEmpty && controller.shownModels.isEmpty && note() == "Get the models from the server, or type the name.", note())
        press(controller.getModelsButton)
        check("Get Models fills the list from the server",
              controller.shownModels.count == 4 && controller.suggestions.items.count == 4
                && Stub.requests.first?.url.absoluteString == "https://openrouter.ai/api/v1/models",
              "\(controller.shownModels.count) \(Stub.requests.map(\.url))")
        check("the note says how many and what to do",
              note() == "4 models on the server. Click the field to pick one, or type to narrow the list.", note())
        check("and the list is kept for the next launch", ModelCatalog.saved(for: "api-or")?.models.count == 4)

        guard let box = controller.modelField else { return check("the model field is there", false) }
        let list = controller.suggestions
        // A click in the field, the mouse-up queued first or the field waits for a real one.
        let inside = box.convert(NSPoint(x: 30, y: box.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            let event = NSEvent.mouseEvent(with: type, location: inside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) } else { NSApp.sendEvent(event) }
        }
        spin(0.3)
        check("a click in the field opens the whole list under it", list.isOpen && list.items.count == 4 && window.firstResponder is NSText,
              "\(list.isOpen) \(list.items.count)")
        check("its foot counts the models while none is marked", list.footText == "4 models on the server", list.footText)
        let fieldRect = window.convertToScreen(box.convert(box.bounds, to: nil))
        check("wider than the field, just below it", list.frame.width > fieldRect.width && abs(list.frame.maxY - fieldRect.minY) < 6,
              "\(list.frame) \(fieldRect)")
        check("each row leads with the name and says where it is from",
              list.items.first == SuggestionList.Item(value: "openrouter/auto", title: "auto", detail: "openrouter · 2M")
                && list.items.last?.detail == "meta-llama · 128K", "\(list.items)")
        let away = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: window.frame.width - 10, y: 10), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: away.locationInWindow, modifierFlags: [], timestamp: away.timestamp,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
        NSApp.sendEvent(away)
        spin(0.1)
        check("a click elsewhere in the window closes it", !list.isOpen)

        type("llama", into: box, end: false)
        check("typing narrows the list and keeps it open under the field",
              list.items.map(\.value) == ["meta-llama/llama-3.3-8b-instruct:free"] && list.isOpen, "\(list.items.map(\.value)) \(list.isOpen)")
        check("and the note counts what matches", note() == "1 of 4 models match.", note())
        let editor = window.fieldEditor(false, for: box) as? NSTextView
        editor?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check("Escape closes the list and leaves the window", !list.isOpen && window.isVisible)
        editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        check("↓ opens it again on the first row", list.isOpen && list.highlighted == 0)
        check("and the foot of the list tells about the row", list.footText == "128K tokens of context · takes tools · free", list.footText)
        editor?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("Return takes the row", !list.isOpen && controller.entry("api-or")?.model == "meta-llama/llama-3.3-8b-instruct:free",
              controller.entry("api-or")?.model ?? "nil")
        window.makeFirstResponder(nil)
        window.makeFirstResponder(box)
        (window.fieldEditor(false, for: box) as? NSTextView)?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        check("↓ in a field that holds a model opens the whole list at it",
              list.isOpen && list.items.count == 4 && list.highlighted.map { list.items[$0].value } == "meta-llama/llama-3.3-8b-instruct:free",
              "\(list.items.count) \(list.highlighted ?? -1)")
        window.makeFirstResponder(nil)

        type("openai/gpt-5-mini", into: box)
        var entry = controller.entry("api-or")
        check("a model picked from the list brings its context window",
              entry?.model == "openai/gpt-5-mini" && entry?.contextWindow == 400_000 && controller.contextField?.stringValue == "400000",
              "\(entry.map { "\($0.model) \($0.contextWindow ?? -1)" } ?? "nil") \(controller.contextField?.stringValue ?? "")")
        check("and forgets that the old model took no tools", entry?.refusesTools == false)
        check("the note says what the list knows about it",
              note() == "400K tokens of context · takes tools · $0.25 in, $2 out per million tokens", note())
        check("the whole list is back once the field is left", controller.shownModels.count == 4)

        type("google/gemini-2.5-flash-image", into: box)
        entry = controller.entry("api-or")
        check("a model the list says takes no tools is given the document from the first question",
              entry?.refusesTools == true && entry?.contextWindow == 32_768, "\(entry.map { "\($0)" } ?? "nil")")
        type("gemini-typo", into: box)
        entry = controller.entry("api-or")
        check("a name the list does not have is questioned, and loses the old model's window",
              note() == "Not among the 4 models on the server. Check the name." && controller.modelNote?.textColor == .systemOrange
                && entry?.contextWindow == nil && entry?.refusesTools == false,
              "\(note()) \(entry?.contextWindow ?? -1)")

        useStub([(500, "")])
        press(controller.getModelsButton)
        check("a failed Get Models says so in red and keeps the list it had",
              note() == "The server answered with an error (500)." && controller.modelNote?.textColor == .systemRed && controller.shownModels.count == 4, note())

        if let context = controller.contextField {
            type("12k8", into: context, end: false)
            let typed = context.stringValue
            type("128,000", into: context)
            check("Context takes digits only, typed or pasted",
                  typed == "128" && context.stringValue == "128000" && controller.entry("api-or")?.contextWindow == 128_000,
                  "\(typed) \(context.stringValue)")
        }

        useStub([(200, #"{"data":[{"id":"qwen2.5-7b-instruct"},{"id":"text-embedding-nomic-embed-text-v1.5"}]}"#)])
        controller.select("api-lm")
        press(controller.getModelsButton)
        check("a server with one model has it picked", controller.entry("api-lm")?.model == "qwen2.5-7b-instruct",
              controller.entry("api-lm")?.model ?? "nil")

        let many = (1...25).map { #"{"id":"lab/model-\#($0)"}"# }.joined(separator: ",")
        useStub([(200, #"{"data":["# + many + "]}")])
        press(controller.getModelsButton)
        if let field = controller.modelField {
            window.makeFirstResponder(field)
            (window.fieldEditor(false, for: field) as? NSTextView)?.doCommand(by: #selector(NSResponder.moveDown(_:)))
            check("a long list shows ten rows and scrolls",
                  list.isOpen && list.items.count == 25 && abs(list.frame.height - SuggestionList.height(rows: 10)) < 1 && list.scrolls,
                  "\(list.items.count) \(list.frame.height) \(list.scrolls)")
            check("in the order of the numbers", list.items.prefix(3).map(\.title) == ["model-1", "model-2", "model-3"], "\(list.items.prefix(3).map(\.title))")
            window.makeFirstResponder(nil)
        }

        useStub([(0, "")])
        controller.select("api-ol")
        press(controller.getModelsButton)
        check("a server that is not running is named",
              note() == "Nothing answers at localhost:11434. Is the server running?" && controller.modelNote?.textColor == .systemRed, note())

        // Other OpenAI-compatible API: the address comes first.
        useStub([(401, "{}"), (200, #"{"data":[{"id":"llama-3.3-70b-versatile","context_window":131072}]}"#)])
        let item = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        item.tag = 4
        controller.perform(NSSelectorFromString("addPreset:"), with: item)
        guard let address = controller.addressField else { return check("a new API has an address field", false) }
        check("a new API of no known kind starts at its address", (window.firstResponder as? NSText)?.delegate === address,
              "\(String(describing: window.firstResponder))")
        check("its model field and Get Models wait for the address",
              controller.modelField?.isEnabled == false && controller.getModelsButton?.isEnabled == false && note() == "Enter the server's address first.", note())
        type("api.groq.com/openai/v1/chat/completions", into: address, end: false)
        check("and come alive as it is typed", controller.modelField?.isEnabled == true && controller.getModelsButton?.isEnabled == true)
        press(controller.getModelsButton)
        let added = controller.shown
        check("its address is tidied and it is named after it",
              added?.baseURL == "https://api.groq.com/openai/v1" && added?.name == "groq.com" && address.stringValue == "https://api.groq.com/openai/v1",
              "\(added.map { "\($0.baseURL) \($0.name)" } ?? "nil")")
        check("without a key the server's refusal is explained", note() == "The server wants the API key first.", note())
        if let key = controller.keyField { type("gsk-test", into: key, end: false) }
        press(controller.getModelsButton)
        check("the key typed is used by the next Get Models",
              controller.shownModels.first?.id == "llama-3.3-70b-versatile" && Stub.requests.last?.headers["Authorization"] == "Bearer gsk-test",
              "\(controller.shownModels.map(\.id)) \(Stub.requests.last?.headers ?? [:])")
        type("https://api.groq.com/v2", into: address)
        check("a list from another address is not offered",
              controller.shownModels.isEmpty && note() == "The list is from another address. Get the models again.", note())

        window.close()
        if let added { Keychain.removeKey(for: added.id) }
        Settings.assistantsData = saved
    }

    static func draftsWindow() {
        let before = Settings.assistantsData
        Keychain.inMemory = [:]
        Assistants.all = [
            Assistant(id: "api-a", kind: .openAI, name: "Alpha", model: "m-1", baseURL: "https://a.example/v1"),
            Assistant(id: "api-b", kind: .openAI, name: "Beta", model: "b-1", baseURL: "https://b.example/v1"),
            Assistant(id: "api-c", kind: .openAI, name: "Gamma", model: "c-1", baseURL: "https://c.example/v1"),
        ]
        Keychain.setKey("sk-beta", for: "api-b")
        let controller = AssistantsWindowController.shared
        AssistantsWindowController.show()
        guard let window = controller.window else { return check("the Assistants window opens", false) }
        func type(_ text: String, into field: NSControl?, end: Bool = true) {
            guard let field else { return }
            window.makeFirstResponder(field)
            let editor = window.fieldEditor(false, for: field) as? NSTextView
            editor?.selectAll(nil)
            editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
            if end { window.makeFirstResponder(nil) }
        }
        func key(_ code: UInt16, _ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
            spin(0.2)
        }

        controller.select("api-a")
        type("foo", into: controller.modelField, end: false)
        key(53, "\u{1b}")
        check("Escape after typing asks before anything is lost, and nothing is saved yet",
              window.attachedSheet != nil && Assistants.assistant("api-a")?.model == "m-1",
              "\(window.attachedSheet != nil) \(Assistants.assistant("api-a")?.model ?? "nil")")
        if let sheet = controller.discardSheet, let content = sheet.window.contentView {
            let keep = sheet.keepButton.convert(sheet.keepButton.bounds, to: nil)
            let discard = sheet.discardButton.convert(sheet.discardButton.bounds, to: nil)
            check("the sheet says what each button does",
                  DiscardSheet.text.contains("Discard Changes closes the window") && DiscardSheet.text.contains("Keep Editing takes you back"))
            check("its buttons sit at the bottom right, Discard Changes then Keep Editing",
                  discard.maxX < keep.minX && content.bounds.width - keep.maxX <= 24 && keep.minY <= 24 && abs(discard.minY - keep.minY) < 1,
                  "\(discard) \(keep) in \(content.bounds)")
            check("Keep Editing is the default button", sheet.window.defaultButtonCell === sheet.keepButton.cell)
            sheet.window.performKeyEquivalent(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!)
            spin(0.3)
        }
        check("Return is Keep Editing: back with the change still there",
              window.attachedSheet == nil && window.isVisible && controller.modelField?.stringValue == "foo")
        window.performClose(nil)
        spin(0.3)
        check("the close button asks too", window.attachedSheet != nil)
        controller.discardSheet?.discardButton.performClick(nil)
        spin(0.3)
        check("Discard Changes closes the window and saves nothing",
              !window.isVisible && Assistants.assistant("api-a")?.model == "m-1")
        AssistantsWindowController.show()
        controller.select("api-a")
        check("opened again, it shows what is saved", controller.modelField?.stringValue == "m-1" && controller.entry("api-a")?.model == "m-1",
              controller.modelField?.stringValue ?? "nil")

        type("sk-alpha", into: controller.keyField)
        type("m-2", into: controller.modelField)
        controller.select("api-b")
        controller.perform(NSSelectorFromString("removePressed"))
        // Meanwhile, elsewhere: a model picked under a question.
        var gamma = Assistants.assistant("api-c")!
        gamma.model = "c-2"
        Assistants.update(gamma)
        check("until Save nothing reaches the settings or the Keychain",
              Assistants.assistant("api-a")?.model == "m-1" && Keychain.key(for: "api-a") == nil
                && Assistants.assistant("api-b") != nil && Keychain.key(for: "api-b") == "sk-beta")
        check("the list says a typed key is not saved yet", controller.entry("api-b") == nil)
        controller.save()
        spin(0.3)
        check("Save writes the model and the key, and closes the window",
              !window.isVisible && Assistants.assistant("api-a")?.model == "m-2" && Keychain.key(for: "api-a") == "sk-alpha",
              "\(window.isVisible) \(Assistants.assistant("api-a")?.model ?? "nil")")
        check("an assistant removed goes, with its key", Assistants.assistant("api-b") == nil && Keychain.key(for: "api-b") == nil)
        check("one left alone keeps what was written to it meanwhile", Assistants.assistant("api-c")?.model == "c-2")

        AssistantsWindowController.show()
        spin(0.2)
        controller.cancel()
        spin(0.3)
        check("Cancel with nothing changed just closes", !window.isVisible && window.attachedSheet == nil)

        // Return is Save, except while the list of models is open.
        useStub([(200, #"{"data":[{"id":"m-2"},{"id":"m-3"}]}"#)])
        AssistantsWindowController.show()
        controller.select("api-a")
        controller.getModelsButton?.performClick(nil)
        waitFor(3) { controller.shownModels.count == 2 }
        if let field = controller.modelField {
            window.makeFirstResponder(field)
            let editor = window.fieldEditor(false, for: field) as? NSTextView
            editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
            editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        }
        key(53, "\u{1b}")
        check("Escape with the list open closes the list, not the window",
              !controller.suggestions.isOpen && window.isVisible && window.attachedSheet == nil)
        if let field = controller.modelField {
            let editor = window.fieldEditor(false, for: field) as? NSTextView
            editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
            editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        }
        key(36, "\r")
        check("Return with the list open takes the model and saves nothing",
              !controller.suggestions.isOpen && window.isVisible && controller.modelField?.stringValue == "m-3" && Assistants.assistant("api-a")?.model == "m-2",
              "\(controller.suggestions.isOpen) \(window.isVisible) \(controller.modelField?.stringValue ?? "nil")")
        key(36, "\r")
        check("Return with it shut is Save", !window.isVisible && Assistants.assistant("api-a")?.model == "m-3",
              "\(window.isVisible) \(Assistants.assistant("api-a")?.model ?? "nil")")

        // An agent's executable, chosen by hand. Saved above, Codex kept the
        // path it was found at; here it has none.
        Assistants.locations["codex"] = .some(nil)
        Assistants.all = Assistants.all.filter { $0.kind != .codex }
        AssistantsWindowController.show()
        controller.select("codex")
        spin(0.2)
        check("an agent with no path says so",
              controller.pathField?.stringValue == "" && controller.pathNote?.stringValue == "Not set: choose the executable.",
              controller.pathNote?.stringValue ?? "nil")
        if let app = try? fakeApp(), let codex = controller.entry("codex") {
            controller.usePath(app, for: codex)
            waitFor(5) { controller.pathNote?.stringValue == "codex-cli 9.9.9" }
            check("choosing an app takes the codex inside it, and shows what it says it is",
                  URL(fileURLWithPath: controller.pathField?.stringValue ?? "").resolvingSymlinksInPath().path
                    == app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").resolvingSymlinksInPath().path
                    && controller.pathNote?.stringValue == "codex-cli 9.9.9" && controller.entry("codex")?.isInstalled == true,
                  "\(controller.pathField?.stringValue ?? "nil") \(controller.pathNote?.stringValue ?? "nil")")
            check("and like everything else it waits for Save", Assistants.assistant("codex")?.isInstalled == false)
            type("/nowhere/codex", into: controller.pathField)
            check("a path with nothing to run is said to be one", controller.pathNote?.stringValue == "Nothing can be run at this path.")
        }
        Assistants.locations.removeValue(forKey: "codex")

        if window.isVisible { window.close() }
        Settings.assistantsData = before
    }

    // MARK: - Keeping chats

    static func store() {
        let store = ChatStore.shared
        store.reset()
        var chat = sampleChat(turns: [AskTurn(question: "Q", answer: "A")])
        chat.id = "c-kept"
        chat.document = ChatStore.key(for: folder.appendingPathComponent("doc.md"))
        store.save(chat)
        let file = ChatStore.folder.appendingPathComponent("c-kept.json")
        check("a chat kept until deleted is written down", FileManager.default.fileExists(atPath: file.path))
        store.reset()
        check("and read back after a restart", store.chat("c-kept")?.turns.first?.answer == "A")
        check("it is filed under its document", store.chats(for: folder.appendingPathComponent("doc.md")).map(\.id) == ["c-kept"])

        UserDefaults.standard.setVolatileDomain(["askEnabled": true, "askKeepChats": "untilQuit"], forName: UserDefaults.argumentDomain)
        var passing = chat
        passing.id = "c-passing"
        store.save(passing)
        check("a chat kept until quit is never written",
              !FileManager.default.fileExists(atPath: ChatStore.folder.appendingPathComponent("c-passing.json").path) && store.chat("c-passing") != nil)
        UserDefaults.standard.setVolatileDomain(["askEnabled": true, "askKeepChats": "untilDeleted", "askShowsUsage": true], forName: UserDefaults.argumentDomain)

        var hostile = chat
        hostile.id = "../escape"
        store.save(hostile)
        check("an id that is not a plain name goes nowhere on disk",
              !FileManager.default.fileExists(atPath: ChatStore.folder.deletingLastPathComponent().appendingPathComponent("escape.json").path))

        store.delete("c-kept")
        check("a deleted chat is gone from disk", !FileManager.default.fileExists(atPath: file.path) && store.chat("c-kept") == nil)
        store.deleteAll()
        check("delete all leaves nothing", store.count == 0)
    }

    // MARK: - The page

    struct Opened {
        let controller: DocumentWindowController
        let page: WKWebView
        let url: URL
    }

    @discardableResult
    static func js(_ page: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var done = false
        page.evaluateJavaScript(script) { value, error in
            result = error == nil ? value : "error: \(error!)"
            done = true
        }
        waitFor(5) { done }
        return result
    }

    static func glyph() throws {
        // The bubble is text.bubble's own, as the toolbar draws it beside.
        let bubble = NSImage(systemSymbolName: "ellipsis.bubble", accessibilityDescription: nil)!.withSymbolConfiguration(AskGlyph.toolbar)!
        let comment = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)!.withSymbolConfiguration(AskGlyph.toolbar)!
        let glyph = AskGlyph.image()
        check("Ask's bubble is the comment button's size, with room above and below for its sparkle",
              bubble.size == comment.size && glyph.size.width == bubble.size.width && glyph.size.height > bubble.size.height
                && glyph.size.height < bubble.size.height + 8, "\(glyph.size) over \(bubble.size)")
        check("a glyph for the toolbar takes the toolbar's colour", glyph.isTemplate && !AskGlyph.image(color: .red).isTemplate)
        check("the page gets it as an image to mask with", AskGlyph.maskDataURL.hasPrefix("data:image/png;base64,") && AskGlyph.maskDataURL.count > 200)
    }

    static func page() throws {
        ChatStore.shared.reset()
        let script = try fakeClaude(claudeLines)
        Assistants.locations["claude"] = script
        Assistants.all = [Assistant(id: "claude-code", kind: .claudeCode, name: "Claude Code")]
        UserDefaults.standard.set("claude-code", forKey: "askAssistant")

        let url = folder.appendingPathComponent("page.md")
        try document.write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController(url: url)
        controller.window?.setFrameOrigin(NSPoint(x: -6_000, y: 0))
        controller.showWindow(nil)
        spin(1.5)
        guard let page = controller.content.renderer.subviews.compactMap({ $0 as? WKWebView }).first else {
            return check("the window has a web view", false)
        }
        waitFor(5) { (js(page, "document.querySelectorAll('#content p').length") as? Int ?? 0) > 0 }

        check("the toolbar has Ask while it is on",
              controller.window?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "ask" } == true)

        // A selection, made in the page the way a hand makes one.
        js(page, """
        (() => {
          const p = [...document.querySelectorAll('#content p')].find((el) => el.textContent.includes('full jitter'))
          const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT)
          const node = walker.nextNode()
          const at = node.data.indexOf('full jitter')
          const range = document.createRange()
          range.setStart(node, at)
          range.setEnd(node, at + 'full jitter'.length)
          const selection = window.getSelection()
          selection.removeAllRanges()
          selection.addRange(range)
        })()
        """)
        controller.askAboutSelection(nil)
        waitFor(3) { js(page, "!!document.querySelector('.ask-card textarea')") as? Bool == true }
        check("⌘J opens a card on the selection", js(page, "!!document.querySelector('.ask-card textarea')") as? Bool == true)
        check("the passage is marked while the card is open",
              js(page, "document.querySelector('.ask-anchor')?.textContent") as? String == "full jitter")
        check("the first question offers presets for a word",
              (js(page, "[...document.querySelectorAll('.ask-chip')].map((c) => c.textContent).join('|')") as? String ?? "").hasPrefix("Define|"))
        check("the card says who will answer",
              (js(page, "document.querySelector('.ask-model')?.textContent") as? String ?? "").contains("Claude Code"))
        check("the card is outside the document, so it is never document text",
              js(page, "document.getElementById('content').contains(document.querySelector('.ask-card'))") as? Bool == false)
        check("the card's quote leads nowhere: the passage is right above it",
              js(page, "document.querySelector('.ask-card .ask-quote')?.hasAttribute('data-action')") as? Bool == false)

        js(page, """
        (() => {
          const field = document.querySelector('.ask-card textarea')
          field.value = 'Що означає «full jitter»?'
          field.dispatchEvent(new Event('input', { bubbles: true }))
          document.querySelector('.ask-card [data-action=send]').click()
        })()
        """)
        check("the question leaves the field once it is sent",
              js(page, "document.querySelector('.ask-card textarea')?.value") as? String == "")
        waitFor(10) { js(page, "!!document.querySelector('.ask-card .ask-answer') && !document.querySelector('.ask-card .is-stop')") as? Bool == true }
        let answer = js(page, "document.querySelector('.ask-card .ask-answer')?.textContent") as? String ?? ""
        check("the answer lands in the card, without what came before the tool",
              answer.contains("Full jitter spreads retries out") && !answer.contains("Let me look"), answer)
        check("a line citation becomes a chip that says which line",
              (js(page, "document.querySelector('.ask-cite')?.title") as? String ?? "").hasPrefix("Line 5: Clients retry"))
        check("the search is summed up above the answer",
              (js(page, "document.querySelector('.ask-card .ask-fold')?.textContent") as? String ?? "").contains("Searched for “backoff” — 2 places"))
        check("the answer says what it cost",
              (js(page, "document.querySelector('.ask-card .ask-actions .ask-meta')?.textContent") as? String ?? "") == "2.7k in · 120 out · 4.2 s · $0.012",
              js(page, "document.querySelector('.ask-card .ask-actions .ask-meta')?.textContent") as? String ?? "nil")
        let stored = ChatStore.shared.chats(for: url).first
        check("the chat is kept with its session and usage",
              stored?.session == "sess-1" && stored?.turns.first?.usage?.cost == 0.012 && stored?.quote == "full jitter"
                && stored?.line == 4 && stored?.blockEnd == 5, "\(stored.map { "\($0)" } ?? "nil")")

        js(page, "document.querySelector('.ask-card .ask-actions .ask-meta').click()")
        check("the usage opens into the details",
              (js(page, "document.querySelector('.ask-tip')?.textContent") as? String ?? "").contains("1,000 from cache"))
        js(page, "document.querySelector('.ask-cite').click()")
        spin(0.2)
        check("a citation takes the page to its line and lights it",
              js(page, "!!document.querySelector('[data-line^=\"4,\"].ask-flash')") as? Bool == true)

        check("the line under the question says what the assistant may do, not what it did",
              js(page, "document.querySelector('.ask-card .ask-sees-text')?.textContent") as? String == "Can search the document")
        check("an empty field has nothing to send",
              js(page, "document.querySelector('.ask-card .ask-send').disabled") as? Bool == true)
        check("the thread keeps its scrolling to itself",
              js(page, "getComputedStyle(document.querySelector('.ask-card .ask-thread')).overscrollBehaviorY") as? String == "contain")
        check("a long assistant name gives way instead of running into the next words",
              js(page, "getComputedStyle(document.querySelector('.ask-model-name')).textOverflow") as? String == "ellipsis")

        // What is read follows the reader's text size; the chrome does not.
        js(page, "document.documentElement.style.setProperty('--size-body', '20px')")
        check("the answer follows the text size",
              js(page, "getComputedStyle(document.querySelector('.ask-card .ask-answer')).fontSize") as? String == "18.75px")
        check("so does the card's width", js(page, "document.querySelector('.ask-card').offsetWidth") as? Int == 560)
        check("the labels do not", js(page, "getComputedStyle(document.querySelector('.ask-card .ask-label')).fontSize") as? String == "11px")
        js(page, "document.documentElement.style.setProperty('--size-body', '16px')")

        // Every palette's own surface: the card is part of the page in each.
        js(page, "document.documentElement.dataset.theme = 'warm-dark'")
        let surface = js(page, "getComputedStyle(document.querySelector('.ask-card')).backgroundColor") as? String
        check("the card takes the palette's surface", surface == "rgb(34, 27, 20)", surface ?? "nil")
        js(page, "document.documentElement.dataset.theme = 'classic-light'")

        // A follow-up continues the session, and answers with a table.
        let tabled = try fakeClaude([
            #"{"type":"system","subtype":"init","session_id":"sess-1","tools":["mcp__imark__outline","mcp__imark__read","mcp__imark__search"]}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":900}}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"| Скорочення | Розшифровка |\n|---|---|\n"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"| **MFA** | Multi-Factor Authentication — багатофакторна автентифікація |\n| **IdP** | Identity Provider — постачальник ідентичності |\n"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\nAlso in [L5, L7-8]."}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"num_turns":1,"total_cost_usd":0.000254783,"usage":{"input_tokens":900,"output_tokens":40}}"#,
        ])
        Assistants.locations["claude"] = tabled
        js(page, """
        window.__changes = 0
        new MutationObserver((records) => { window.__changes += records.length })
          .observe(document.getElementById('content'), { subtree: true, childList: true, attributes: true, characterData: true })
        """)
        js(page, """
        (() => {
          const field = document.querySelector('.ask-card textarea')
          field.value = 'розшифруй всі абревіатури'
          field.dispatchEvent(new Event('input', { bubbles: true }))
          document.querySelector('.ask-card [data-action=send]').click()
        })()
        """)
        waitFor(10) { ChatStore.shared.chats(for: url).first?.turns.count == 2 && ChatStore.shared.chats(for: url).first?.turns.last?.usage != nil }
        spin(0.5)
        let args = (try? String(contentsOf: tabled.deletingLastPathComponent().appendingPathComponent("args.txt"), encoding: .utf8)) ?? ""
        check("a follow-up from the card resumes the agent's session", args.contains("--resume\nsess-1"))
        check("an answer arriving changes nothing in the document",
              js(page, "window.__changes") as? Int == 0, "\(js(page, "window.__changes") ?? "nil") changes")
        check("a table in an answer keeps its words whole",
              (js(page, "document.querySelector('.ask-card .ask-answer td')?.offsetWidth") as? Int ?? 0) > 40,
              "\(js(page, "document.querySelector('.ask-card .ask-answer td')?.offsetWidth") ?? "nil")")
        check("a list of lines in one citation becomes a chip for each",
              js(page, "[...document.querySelectorAll('.ask-card .ask-turn')].pop().querySelectorAll('.ask-cite').length") as? Int == 2)
        check("and its header is not the document's shouting capitals",
              js(page, "getComputedStyle(document.querySelector('.ask-card .ask-answer th')).textTransform") as? String == "none")
        check("a fraction of a cent is not rounded to nothing",
              (js(page, "[...document.querySelectorAll('.ask-card .ask-actions .ask-meta')].pop()?.textContent") as? String ?? "").hasSuffix("$0.00025"),
              js(page, "[...document.querySelectorAll('.ask-card .ask-actions .ask-meta')].pop()?.textContent") as? String ?? "nil")
        Assistants.locations["claude"] = script

        // Another assistant picked: the chat goes on with it, as the chip says.
        useStub([(200, sse([#"{"choices":[{"delta":{"content":"From the API."}}]}"#, #"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":4}}"#]))])
        Assistants.all = [
            Assistant(id: "claude-code", kind: .claudeCode, name: "Claude Code"),
            Assistant(id: "api-chip", kind: .openAI, name: "Chip API", model: "m-1", baseURL: "https://api.example.com/v1", tools: .off),
        ]
        Settings.askAssistant = "api-chip"
        spin(0.3)
        check("the chip shows the assistant picked in Settings",
              (js(page, "document.querySelector('.ask-card .ask-model')?.textContent") as? String ?? "").contains("Chip API"))
        js(page, """
        (() => {
          const field = document.querySelector('.ask-card textarea')
          field.value = 'і ще?'
          field.dispatchEvent(new Event('input', { bubbles: true }))
          document.querySelector('.ask-card [data-action=send]').click()
        })()
        """)
        waitFor(10) { ChatStore.shared.chats(for: url).first?.turns.count == 3 && ChatStore.shared.chats(for: url).first?.turns.last?.usage != nil }
        let switched = ChatStore.shared.chats(for: url).first
        check("and a chat begun with Claude Code is answered by it",
              Stub.requests.first?.url.absoluteString == "https://api.example.com/v1/chat/completions"
                && switched?.turns.last?.answer == "From the API." && switched?.assistant == "api-chip" && switched?.session == nil,
              "\(Stub.requests.map(\.url)) \(switched?.assistant ?? "nil")")
        check("given the chat so far",
              (Stub.requests.first?.body["messages"] as? [[String: Any]])?.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String ?? "").contains("spreads retries out [L5]") } == true,
              "\((Stub.requests.first?.body["messages"] as? [[String: Any]])?.map { "\($0["role"] ?? ""): \(String(describing: $0["content"] ?? "").prefix(60))" } ?? [])")
        check("each answer remembers who gave it",
              switched?.turns.map { $0.answeredBy ?? "?" } == ["Claude Code", "Claude Code", "Chip API · m-1"], "\(switched?.turns.map { $0.answeredBy ?? "?" } ?? [])")
        js(page, "[...document.querySelectorAll('.ask-card .ask-actions .ask-meta')].pop()?.click()")
        check("and its usage says so",
              (js(page, "document.querySelector('.ask-tip')?.textContent") as? String ?? "").contains("Answered byChip API · m-1"),
              js(page, "document.querySelector('.ask-tip')?.textContent") as? String ?? "nil")
        js(page, "document.querySelector('.ask-tip') && document.querySelector('.ask-card .ask-actions .ask-meta').click()")
        Assistants.all = [Assistant(id: "claude-code", kind: .claudeCode, name: "Claude Code")]
        Settings.askAssistant = "claude-code"
        spin(0.3)

        js(page, "document.querySelector('.ask-card [data-action=close]').click()")
        spin(0.3)
        check("closing the card leaves a mark in the margin",
              js(page, "!document.querySelector('.ask-card') && document.querySelectorAll('.ask-mark').length === 1") as? Bool == true)
        check("and the mark wears the toolbar's glyph",
              (js(page, "getComputedStyle(document.querySelector('.ask-mark .ask-glyph')).webkitMaskImage") as? String ?? "").contains("data:image/png"),
              js(page, "document.querySelector('.ask-mark')?.innerHTML") as? String ?? "nil")

        // At full width the margin is 48 points and macOS lays its scroller over
        // the last 15: a mark out there was clicked into the scroller.
        js(page, "window.imark.setWidth('full')")
        spin(0.4)
        let right = js(page, "(() => { const b = document.querySelector('.ask-mark').getBoundingClientRect(); return innerWidth - b.right })()") as? Double ?? -1
        check("at full width the mark stays clear of the scroller", right >= 15, "\(right) points from the edge")
        js(page, "window.imark.setWidth('normal')")
        spin(0.3)
        js(page, "document.querySelector('.ask-mark').click()")
        check("the mark opens the chat again",
              js(page, "document.querySelectorAll('.ask-card .ask-turn').length") as? Int == 3)

        controller.toggleAskPanel(nil)
        spin(0.3)
        check("⇧⌘J opens the panel with the chat in it",
              js(page, "document.documentElement.dataset.askPanel === 'open' && document.querySelectorAll('.ask-panel .ask-turn').length === 3 && !document.querySelector('.ask-card')") as? Bool == true)
        check("the toolbar button is lit while the panel is open", controller.ask.panelOpen)
        check("the panel's header counts the document's chats",
              js(page, "document.querySelector('.ask-panel .ask-count')?.textContent") as? String == "1")
        check("a two-column table too narrow for the panel becomes pairs",
              js(page, "document.querySelector('.ask-panel .ask-answer table')?.classList.contains('is-pairs')") as? Bool == true)
        check("answered questions carry no notice of a missing answer",
              js(page, "document.querySelectorAll('.ask-panel .ask-error').length") as? Int == 0)
        check("a wheel over the panel's head never scrolls the document",
              js(page, "(() => { const e = new WheelEvent('wheel', { bubbles: true, cancelable: true, deltaY: 40 }); document.querySelector('.ask-panel-head').dispatchEvent(e); return e.defaultPrevented })()") as? Bool == true)
        check("the panel keeps its scrolling to itself",
              js(page, "getComputedStyle(document.querySelector('.ask-panel')).overscrollBehaviorY") as? String == "contain")

        // By the time an answer is read the reader is often far from the
        // passage: the quote in the panel takes the page back there, and Back
        // returns to where they were. The page is made long enough to leave.
        let scrollY = { js(page, "window.scrollY") as? Double ?? -1 }
        let passageShows = {
            js(page, "(() => { const b = document.querySelector('.ask-anchor').getBoundingClientRect(); return b.top >= 0 && b.bottom <= innerHeight })()") as? Bool == true
        }
        let back = NSMenuItem(title: "Back", action: #selector(DocumentWindowController.goBackInHistory(_:)), keyEquivalent: "")
        js(page, "document.getElementById('content').style.paddingBottom = '4000px'; window.scrollTo(0, 2000)")
        spin(0.3)
        check("the panel's quote is a link to the passage",
              js(page, "document.querySelector('.ask-panel .ask-quote')?.getAttribute('role')") as? String == "button")
        // Focused first, as the pointer pressed on it focuses it.
        js(page, """
        (() => {
          const quote = document.querySelector('.ask-panel .ask-quote')
          quote.focus()
          quote.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1 }))
        })()
        """)
        spin(0.8)
        check("clicking it takes the page to the passage", passageShows(), "at \(scrollY())")
        check("and leaves the keys to the page, where Space pages on",
              js(page, "!document.activeElement.closest('.ask-panel')") as? Bool == true,
              js(page, "document.activeElement.className") as? String ?? "nil")
        check("and lights the block it is in",
              js(page, "!!document.querySelector('.ask-anchor').closest('[data-line].ask-flash')") as? Bool == true)
        check("a step Back can undo", controller.validateMenuItem(back))
        controller.goBackInHistory(nil)
        spin(0.8)
        check("Back returns to where the reader was", abs(scrollY() - 2000) < 2, "at \(scrollY())")
        js(page, "window.scrollTo(0, 0)")
        spin(0.3)
        js(page, "document.querySelectorAll('.ask-flash').forEach((el) => el.classList.remove('ask-flash'))")
        js(page, "document.querySelector('.ask-panel .ask-quote').click()")
        spin(0.8)
        check("a passage already on screen only lights up",
              scrollY() == 0 && !controller.validateMenuItem(back)
                && js(page, "!!document.querySelector('.ask-anchor').closest('.ask-flash')") as? Bool == true,
              "at \(scrollY())")
        js(page, "window.scrollTo(0, 2000)")
        spin(0.3)
        js(page, """
        (() => {
          const quote = document.querySelector('.ask-panel .ask-quote')
          quote.focus()
          quote.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
        })()
        """)
        spin(0.8)
        check("Return on the quote does what a click does", passageShows(), "at \(scrollY())")
        // A passage on a line wider than its box, as in a code block: the box
        // scrolls sideways to it too.
        js(page, """
        (() => {
          const p = document.querySelector('.ask-anchor').closest('p')
          p.style.cssText = 'white-space: nowrap; overflow-x: auto; width: 120px'
          p.scrollLeft = 0
        })()
        """)
        js(page, "document.querySelector('.ask-panel .ask-quote').click()")
        spin(0.3)
        check("a passage past the edge of a box that scrolls sideways is brought in",
              js(page, """
              (() => {
                const p = document.querySelector('.ask-anchor').closest('p')
                const box = p.getBoundingClientRect()
                const words = document.querySelector('.ask-anchor').getBoundingClientRect()
                return p.scrollLeft > 0 && words.left >= box.left && words.left < box.right
              })()
              """) as? Bool == true)
        // Put back, and waited for: a hidden window hands out scroll events
        // late, and one arriving after the next check's pointer move put away
        // the `+` it looks for.
        js(page, """
        window.__scrolled = false
        addEventListener('scroll', () => { window.__scrolled = true }, { once: true, capture: true })
        document.querySelector('.ask-anchor').closest('p').style.cssText = ''
        document.getElementById('content').style.paddingBottom = ''
        window.scrollTo(0, 0)
        """)
        waitFor(3) { js(page, "window.__scrolled") as? Bool == true }
        spin(0.1)

        // The margin's `+` answers the pointer by its height, and over the panel
        // it lit the document's blocks behind it as the pointer moved.
        js(page, """
        (() => {
          const p = [...document.querySelectorAll('#content p')].find((el) => el.textContent.includes('Raw events'))
          const box = p.getBoundingClientRect()
          p.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.left + 10, clientY: box.top + 5 }))
        })()
        """)
        check("over the text the margin offers a note, as before",
              js(page, "document.querySelector('.block-plus').style.display !== 'none'") as? Bool == true)
        js(page, """
        (() => {
          const line = document.querySelector('.ask-panel .ask-fold, .ask-panel .ask-about')
          const box = line.getBoundingClientRect()
          for (let dx = 0; dx < 60; dx += 6) {
            line.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.left + dx, clientY: box.top + 4 }))
          }
        })()
        """)
        spin(0.4)
        check("over the panel the document behind it lights nothing",
              js(page, "document.querySelector('.block-plus').style.display === 'none' && !document.querySelector('.block-target, .block-armed')") as? Bool == true)

        // The chat's usage, opened from the panel, goes when anything scrolls or
        // the panel shows another chat.
        js(page, "document.querySelector('.ask-panel-head .ask-meta')?.click()")
        check("the chat's usage opens from the panel", js(page, "!!document.querySelector('.ask-tip')") as? Bool == true)
        check("and is pinned to the window like the panel",
              js(page, "document.querySelector('.ask-tip')?.style.position") as? String == "fixed")
        js(page, "document.dispatchEvent(new Event('scroll'))")
        check("scrolling puts it away", js(page, "!document.querySelector('.ask-tip')") as? Bool == true)
        js(page, "document.querySelector('.ask-panel-head .ask-meta')?.click()")
        js(page, "document.querySelector('.ask-panel [data-action=new]').click()")
        check("a new chat puts it away", js(page, "!document.querySelector('.ask-tip')") as? Bool == true)
        js(page, "document.querySelector('.ask-panel [data-action=list]').click()")
        js(page, "document.querySelector('.ask-panel [data-action=open]').click()")
        spin(0.2)

        // Its edge can be dragged, and the document follows on release. The page
        // remembers the width, runs of this suite included: start from none.
        js(page, "localStorage.removeItem('imark.askPanelWidth'); document.documentElement.style.removeProperty('--ask-panel-width')")
        spin(0.2)
        let before = js(page, "document.querySelector('.ask-panel').offsetWidth") as? Int ?? 0
        js(page, """
        (() => {
          const handle = document.querySelector('.ask-resize')
          const box = handle.getBoundingClientRect()
          const at = (x) => ({ bubbles: true, clientX: x, clientY: box.top + 100 })
          handle.dispatchEvent(new MouseEvent('mousedown', at(box.left + 3)))
          document.dispatchEvent(new MouseEvent('mousemove', at(box.left - 37)))
          document.dispatchEvent(new MouseEvent('mouseup', at(box.left - 37)))
        })()
        """)
        let after = js(page, "document.querySelector('.ask-panel').offsetWidth") as? Int ?? 0
        check("dragging the panel's edge widens it", abs(after - before - 40) <= 2, "\(before) → \(after)")

        // Kept as a note: written into the file after the passage's block,
        // signed by the assistant, without the citations.
        js(page, "document.querySelector('.ask-panel .ask-turn [data-action=keep]').click()")
        waitFor(3) { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("<!-- imark") }
        let written = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("an answer kept as a note is written into the document",
              written.contains("<!-- imark") && written.contains("by=\"Claude Code\"") && written.contains("**Full jitter** spreads retries out.")
                && !written.contains("[L5]"), written)
        spin(1)
        check("the passage keeps its chat after the document is written",
              js(page, "document.querySelectorAll('.ask-mark').length") as? Int == 1)

        js(page, "document.querySelector('.ask-panel [data-action=list]').click()")
        js(page, "document.querySelector('.ask-panel [data-action=delete]').click()")
        spin(0.3)
        check("deleting a chat from the list removes it and its mark",
              ChatStore.shared.chats(for: url).isEmpty && js(page, "document.querySelectorAll('.ask-mark').length") as? Int == 0)

        controller.toggleAskPanel(nil)
        spin(0.2)
        js(page, "localStorage.removeItem('imark.askPanelWidth')")
        check("⇧⌘J closes the panel again", js(page, "document.documentElement.dataset.askPanel") is NSNull || js(page, "document.documentElement.dataset.askPanel === undefined") as? Bool == true)

        UserDefaults.standard.setVolatileDomain(["askEnabled": false], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: Settings.changed, object: nil)
        spin(0.3)
        check("turned off, the toolbar has no Ask",
              controller.window?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "ask" } == false)
        controller.window?.close()
    }
}
