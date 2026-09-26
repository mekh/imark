import Foundation

/// Asks Anthropic's Messages API directly, with a key. The same loop as
/// `OpenAITransport` — tools run here, results go back — in the shape this API
/// has: content blocks, `tool_use` and `tool_result`, and usage split across
/// the start and the end of each message.
final class AnthropicTransport: AskTransport {
    private var task: Task<Void, Never>?
    private var cancelled = false

    static let defaultBaseURL = "https://api.anthropic.com"

    func start(_ request: AskRequest, emit: @escaping (AskEvent) -> Void) {
        // Read here, on the main thread, once for the whole answer: every round
        // of tools is a request, and the keychain is not asked for each.
        let key = Keychain.key(for: request.assistant.id)
        task = Task { [weak self] in
            await self?.run(request, key: key) { event in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cancelled else { return }
                    emit(event)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
    }

    private func run(_ request: AskRequest, key: String?, emit: @escaping (AskEvent) -> Void) async {
        let assistant = request.assistant
        guard !assistant.model.isEmpty else {
            return emit(.failed(AskFailure(message: "Pick a model for \(assistant.name) in Settings ▸ Assistants.", remedy: .settings)))
        }
        guard let key, !key.isEmpty else {
            return emit(.failed(AskFailure(message: "\(assistant.name) needs an API key. Add it in Settings ▸ Assistants.", remedy: .settings)))
        }
        let base = assistant.baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultBaseURL : assistant.baseURL
        guard let endpoint = URL(string: base)?.appendingPathComponent("v1/messages") else {
            return emit(.failed(AskFailure(message: "The address of \(assistant.name) is not a URL.", remedy: .settings)))
        }

        let tools = assistant.usesTools
        var messages = Self.messages(for: request, tools: tools)
        var usage = AskUsage(rounds: 0)
        let started = Date()
        var firstToken: Double?

        for round in 1...AskTransports.maxRounds {
            var body: [String: Any] = [
                "model": assistant.model,
                "max_tokens": 4_096,
                "system": AskPrompt.system(tools: tools),
                "messages": messages,
                "stream": true,
            ]
            if tools {
                body["tools"] = DocumentTools.definitions.map {
                    ["name": $0.name, "description": $0.description, "input_schema": $0.schema]
                }
                if round == AskTransports.maxRounds { body["tool_choice"] = ["type": "none"] }
            }

            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let reply: Reply
            do {
                reply = try await Self.stream(urlRequest) { text in
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    emit(.delta(text))
                }
            } catch let failure as OpenAITransport.HTTPFailure {
                return emit(.failed(OpenAITransport.failure(failure, assistant: assistant)))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                return emit(.failed(AskFailure(message: "\(assistant.name) could not be reached: \(error.localizedDescription)")))
            }

            usage.rounds += 1
            usage.add(reply.usage)

            let calls = reply.blocks.filter { $0["type"] as? String == "tool_use" }
            guard !calls.isEmpty else { break }
            if reply.blocks.contains(where: { $0["type"] as? String == "text" }) { emit(.restart) }

            messages.append(["role": "assistant", "content": reply.blocks])
            let document = request.tools
            let results = calls.map { call -> [String: Any] in
                let result = document.call(call["name"] as? String ?? "", call["input"] as? [String: Any] ?? [:])
                if let activity = result.activity { emit(.activity(activity)) }
                return ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "", "content": result.text, "is_error": result.isError]
            }
            messages.append(["role": "user", "content": results])
        }

        usage.seconds = Date().timeIntervalSince(started)
        usage.firstToken = firstToken
        usage.window = assistant.contextWindow
        emit(.usage(usage))
        emit(.finished)
    }

    static func messages(for request: AskRequest, tools: Bool) -> [[String: Any]] {
        OpenAITransport.messages(for: request, tools: tools).filter { $0["role"] as? String != "system" }
    }

    struct Reply {
        var blocks: [[String: Any]] = []
        var usage = AskUsage(rounds: 0)
    }

    static func stream(_ request: URLRequest, onText: (String) -> Void) async throws -> Reply {
        let (bytes, response) = try await AskTransports.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4_000 { break }
            }
            throw OpenAITransport.HTTPFailure(status: status, body: body)
        }

        var reply = Reply()
        var json: [Int: String] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let field = EventStreamLine(line), field.field == "data",
                  let data = field.value.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "message_start":
                let raw = event.dict("message")?.dict("usage") ?? [:]
                let cached = raw.int("cache_read_input_tokens")
                let input = (raw.int("input_tokens") ?? 0) + (cached ?? 0) + (raw.int("cache_creation_input_tokens") ?? 0)
                reply.usage.input = input
                reply.usage.cachedInput = cached
                reply.usage.context = input
            case "content_block_start":
                var block = event.dict("content_block") ?? [:]
                if block["type"] as? String == "tool_use" { block["input"] = [String: Any]() }
                reply.blocks.append(block)
            case "content_block_delta":
                guard let delta = event.dict("delta"), !reply.blocks.isEmpty else { continue }
                let index = reply.blocks.count - 1
                if let text = delta["text"] as? String {
                    reply.blocks[index]["text"] = (reply.blocks[index]["text"] as? String ?? "") + text
                    onText(text)
                } else if let part = delta["partial_json"] as? String {
                    json[index, default: ""] += part
                }
            case "content_block_stop":
                let index = reply.blocks.count - 1
                if let raw = json[index], let data = raw.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    reply.blocks[index]["input"] = input
                }
            case "message_delta":
                if let output = event.dict("usage")?.int("output_tokens") {
                    reply.usage.output = output
                    reply.usage.context = (reply.usage.context ?? 0) + output
                }
            case "error":
                throw OpenAITransport.HTTPFailure(status: 500, body: event.dict("error")?["message"] as? String ?? "The stream reported an error.")
            default:
                break
            }
        }
        return reply
    }
}
