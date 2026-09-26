import Foundation

/// Asks anything that speaks OpenAI's chat completions: OpenAI, OpenRouter,
/// LM Studio, Ollama and the rest.
///
/// An API runs the model and nothing else, so the loop around it is Imark's:
/// the model asks for a tool, the tool runs here against the document, the
/// result goes back, until the model answers. A model that does not take tools
/// is given the document itself instead — all of it when it fits, or the
/// section and the headings when it does not.
final class OpenAITransport: AskTransport {
    private var task: Task<Void, Never>?
    private var cancelled = false

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
        guard let endpoint = URL(string: assistant.baseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("chat/completions") else {
            return emit(.failed(AskFailure(message: "The address of \(assistant.name) is not a URL.", remedy: .settings)))
        }

        var tools = assistant.usesTools
        var messages = Self.messages(for: request, tools: tools)
        var usage = AskUsage(rounds: 0, local: assistant.isLocal)
        let started = Date()
        var firstToken: Double?

        var round = 0
        while round < AskTransports.maxRounds {
            round += 1
            var body: [String: Any] = [
                "model": assistant.model,
                "messages": messages,
                "stream": true,
                "stream_options": ["include_usage": true],
            ]
            if tools {
                body["tools"] = Self.toolDefinitions
                // The last round has to answer with what it found.
                if round == AskTransports.maxRounds { body["tool_choice"] = "none" }
            }

            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if let key, !key.isEmpty {
                urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            // OpenRouter lists requests under these; everyone else ignores them.
            urlRequest.setValue("https://github.com/mekh/imark", forHTTPHeaderField: "HTTP-Referer")
            urlRequest.setValue("Imark", forHTTPHeaderField: "X-Title")
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let reply: Reply
            do {
                reply = try await Self.stream(urlRequest) { text in
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    emit(.delta(text))
                }
            } catch let failure as HTTPFailure {
                // A model that does not take tools says so with a 400 and the word
                // in the message. Asked again without, and remembered, so the
                // next question does not pay for finding out.
                if tools, assistant.tools == .auto, failure.status == 400 || failure.status == 422 || failure.status == 404,
                   failure.body.localizedCaseInsensitiveContains("tool") {
                    tools = false
                    var remembered = assistant
                    remembered.refusesTools = true
                    DispatchQueue.main.async { Assistants.update(remembered) }
                    messages = Self.messages(for: request, tools: false)
                    round -= 1
                    continue
                }
                return emit(.failed(Self.failure(failure, assistant: assistant)))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                return emit(.failed(AskFailure(
                    message: "\(assistant.name) could not be reached: \(error.localizedDescription)",
                    remedy: assistant.isLocal ? .none : .settings
                )))
            }

            usage.rounds += 1
            if let part = reply.usage { usage.add(part) }

            guard !reply.calls.isEmpty else { break }
            if !reply.text.isEmpty { emit(.restart) }

            messages.append([
                "role": "assistant",
                "content": reply.text.isEmpty ? NSNull() : reply.text,
                "tool_calls": reply.calls.map { call in
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                },
            ])
            let document = request.tools
            for call in reply.calls {
                let arguments = (call.arguments.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let result = document.call(call.name, arguments)
                if let activity = result.activity { emit(.activity(activity)) }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result.text])
            }
        }

        usage.seconds = Date().timeIntervalSince(started)
        usage.firstToken = firstToken
        usage.window = assistant.contextWindow
        if usage.cost != nil { usage.costSource = URL(string: assistant.baseURL)?.host ?? assistant.name }
        emit(.usage(usage))
        emit(.finished)
    }

    static var toolDefinitions: [[String: Any]] {
        DocumentTools.definitions.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
        }
    }

    /// The whole chat, every time: an API keeps nothing between requests.
    static func messages(for request: AskRequest, tools: Bool) -> [[String: Any]] {
        let document = request.tools
        let mode: AskPrompt.Document = tools
            ? .none
            : (AskPrompt.fits(document, window: request.assistant.contextWindow) ? .whole : .section)
        let earlier = AskTransports.history(request.chat.turns)
        var messages: [[String: Any]] = [["role": "system", "content": AskPrompt.system(tools: tools)]]
        let questions = earlier.map(\.question) + [request.question]
        for (index, question) in questions.enumerated() {
            let text = index == 0
                ? AskPrompt.opening(for: request.chat, question: question, name: request.document.lastPathComponent, tools: document, document: mode)
                : question
            messages.append(["role": "user", "content": text])
            if index < earlier.count { messages.append(["role": "assistant", "content": earlier[index].answer]) }
        }
        return messages
    }

    // MARK: - The stream

    struct Call {
        var id: String
        var name: String
        var arguments: String
    }

    struct Reply {
        var text = ""
        var calls: [Call] = []
        var usage: AskUsage?
    }

    struct HTTPFailure: Error {
        let status: Int
        let body: String
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
            throw HTTPFailure(status: status, body: body)
        }

        var reply = Reply()
        var calls: [Int: Call] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let field = EventStreamLine(line), field.field == "data" else { continue }
            if field.value == "[DONE]" { break }
            guard let data = field.value.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = chunk.dict("error") {
                throw HTTPFailure(status: 500, body: error["message"] as? String ?? "The stream reported an error.")
            }
            if let usage = chunk.dict("usage") { reply.usage = Self.usage(from: usage) }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first, let delta = choice.dict("delta") else { continue }
            if let text = delta["content"] as? String, !text.isEmpty {
                reply.text += text
                onText(text)
            }
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = part.int("index") ?? calls.count
                var call = calls[index] ?? Call(id: "", name: "", arguments: "")
                if let id = part["id"] as? String, !id.isEmpty { call.id = id }
                if let function = part.dict("function") {
                    if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                    call.arguments += function["arguments"] as? String ?? ""
                }
                calls[index] = call
            }
        }
        reply.calls = calls.keys.sorted().compactMap { index in
            var call = calls[index]!
            guard !call.name.isEmpty else { return nil }
            if call.id.isEmpty { call.id = "call_\(index)" }
            return call
        }
        return reply
    }

    static func usage(from raw: [String: Any]) -> AskUsage {
        let input = raw.int("prompt_tokens")
        let output = raw.int("completion_tokens")
        return AskUsage(
            input: input,
            cachedInput: raw.dict("prompt_tokens_details")?.int("cached_tokens"),
            output: output,
            reasoning: raw.dict("completion_tokens_details")?.int("reasoning_tokens"),
            rounds: 0,
            cost: raw["cost"] as? Double,
            context: input.map { $0 + (output ?? 0) }
        )
    }

    static func failure(_ failure: HTTPFailure, assistant: Assistant) -> AskFailure {
        let detail = (failure.body.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["message"] as? String }
            ?? failure.body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch failure.status {
        case 401, 403:
            return AskFailure(message: "\(assistant.name) refused the key. Check it in Settings ▸ Assistants.", remedy: .settings)
        case 404:
            return AskFailure(message: "\(assistant.name) has no model called “\(assistant.model)”. \(detail)", remedy: .settings)
        case 429:
            return AskFailure(message: "\(assistant.name) is limiting requests right now. \(detail)")
        default:
            return AskFailure(message: "\(assistant.name) answered with an error (\(failure.status)). \(detail)")
        }
    }
}
