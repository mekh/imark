import Foundation

/// A model an API lists, with whatever the list says about it.
struct ModelInfo: Codable, Equatable {
    var id: String
    /// Tokens. OpenRouter, Groq, Mistral and Together say; OpenAI does not.
    var contextWindow: Int?
    /// Whether it takes tools, when the list says (OpenRouter, Mistral).
    var takesTools: Bool?
    /// US dollars per million tokens, when the list says (OpenRouter).
    var inputPrice: Double?
    var outputPrice: Double?
}

/// The models behind an address, for the model field in Settings ▸ Assistants.
///
/// Typed by hand, a model's name — a provider prefix, a date, a `:free` — is
/// where a typo slips in, and it only shows at the first question, as "no model
/// called …". Every OpenAI-compatible server lists its models at `/models`, and
/// Anthropic's API at `/v1/models`.
///
/// Asked only when the reader presses Get Models, never behind their back, and
/// kept until the next press: a list of a few hundred models is the same list
/// tomorrow, and the field completes from it without asking again.
enum ModelCatalog {
    struct Failure: Error {
        let message: String
    }

    /// A list as it was fetched, and from where: a list from another address
    /// is not this server's.
    struct Saved: Codable, Equatable {
        var address: String
        var fetched: Date
        var models: [ModelInfo]
    }

    /// Caches, not Application Support: it can always be fetched again.
    /// Replaced by the tests.
    static var folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Imark/Models", isDirectory: true)

    private static func file(for id: String) -> URL? {
        AskChat.isValidID(id) ? folder.appendingPathComponent("\(id).json") : nil
    }

    static func saved(for id: String) -> Saved? {
        guard let file = file(for: id), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ list: Saved, for id: String) {
        guard let file = file(for: id), let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func forget(_ id: String) {
        guard let file = file(for: id) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Nil when there is no address to ask yet.
    static func request(for assistant: Assistant, key: String?) -> URLRequest? {
        let address = assistant.baseURL.trimmingCharacters(in: .whitespaces)
        var request: URLRequest
        switch assistant.kind {
        case .claudeCode, .codex:
            return nil
        case .openAI:
            guard let base = URL(string: address), base.host != nil else { return nil }
            request = URLRequest(url: base.appendingPathComponent("models"))
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.setValue("https://github.com/mekh/imark", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Imark", forHTTPHeaderField: "X-Title")
        case .anthropic:
            guard let base = URL(string: address.isEmpty ? AnthropicTransport.defaultBaseURL : address), base.host != nil,
                  var components = URLComponents(url: base.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)
            else { return nil }
            // A page holds 20 by default and 1000 at most, which is all of them.
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            guard let url = components.url else { return nil }
            request = URLRequest(url: url)
            if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    static func fetch(_ request: URLRequest) async throws -> [ModelInfo] {
        let (data, response) = try await AskTransports.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OpenAITransport.HTTPFailure(status: status, body: String(decoding: data.prefix(4_000), as: UTF8.self))
        }
        guard let models = parse(data) else { throw Failure(message: "The answer was not a list of models.") }
        return models
    }

    /// `{"data": [...]}` from nearly everyone, a bare array from Together.
    /// Sorted by the model's name, the part after the last slash, so the same
    /// model from several providers sits together; numbers in order, `gpt-5`
    /// before `gpt-10`.
    static func parse(_ data: Data) -> [ModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let list = json as? [[String: Any]] {
            entries = list
        } else if let list = (json as? [String: Any])?["data"] as? [[String: Any]] {
            entries = list
        } else {
            return nil
        }
        var seen = Set<String>()
        return entries.compactMap(info(from:))
            .filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                switch Assistants.shortModel(a.id).localizedStandardCompare(Assistants.shortModel(b.id)) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.id.localizedStandardCompare(b.id) == .orderedAscending
                }
            }
    }

    private static func info(from entry: [String: Any]) -> ModelInfo? {
        guard let id = entry["id"] as? String, !id.isEmpty, answersInText(entry, id: id) else { return nil }
        var info = ModelInfo(id: id)
        info.contextWindow = entry.int("context_length") ?? entry.int("context_window")
            ?? entry.int("max_context_length") ?? entry.int("max_input_tokens")
            ?? entry.dict("top_provider")?.int("context_length")
        if let parameters = entry["supported_parameters"] as? [String] {
            info.takesTools = parameters.contains("tools")
        } else if let calling = entry.dict("capabilities")?["function_calling"] as? Bool {
            info.takesTools = calling
        }
        // Per token, as strings. A negative price is OpenRouter's router, which
        // costs whatever model it routes to.
        if let pricing = entry.dict("pricing"),
           let input = (pricing["prompt"] as? String).flatMap(Double.init),
           let output = (pricing["completion"] as? String).flatMap(Double.init),
           input >= 0, output >= 0 {
            info.inputPrice = input * 1_000_000
            info.outputPrice = output * 1_000_000
        }
        return info
    }

    /// The lists hold embedding, image, speech and moderation models too, which
    /// chat completions do not serve. Left out where the list says what a model
    /// makes, and by the usual words in the name where it does not (OpenAI, LM
    /// Studio, Ollama). Anything left out can still be typed.
    private static func answersInText(_ entry: [String: Any], id: String) -> Bool {
        if let type = (entry["type"] as? String)?.lowercased(),
           ["embedding", "embeddings", "image", "audio", "moderation", "rerank", "transcribe"].contains(type) {
            return false
        }
        if entry.dict("capabilities")?["completion_chat"] as? Bool == false { return false }
        if let outputs = entry.dict("architecture")?["output_modalities"] as? [String], !outputs.contains("text") {
            return false
        }
        let name = id.lowercased()
        return !["embed", "whisper", "tts", "dall-e", "gpt-image", "moderation", "transcribe", "realtime", "rerank", "sora"]
            .contains { name.contains($0) }
    }

    /// The models whose name holds every word typed, the closest first: the
    /// name itself, then names that start with it, then the rest in order.
    /// `claude` finds `anthropic/claude-…` as readily as `anthropic` does.
    static func matching(_ query: String, in models: [ModelInfo]) -> [ModelInfo] {
        let whole = query.trimmingCharacters(in: .whitespaces).lowercased()
        let words = whole.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return models }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func rank(_ model: ModelInfo) -> Int {
            let id = model.id.lowercased()
            let short = Assistants.shortModel(id)
            if id == whole || short == whole { return 0 }
            if id.hasPrefix(whole) || short.hasPrefix(whole) { return 1 }
            return 2
        }
        return models.enumerated()
            .filter { entry in words.allSatisfy { entry.element.id.range(of: $0, options: options) != nil } }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// One line on what the list says about a model, or nil when it says
    /// nothing: "128K tokens of context · takes tools · $0.15 in, $0.6 out per
    /// million tokens".
    static func summary(of model: ModelInfo) -> String? {
        var parts: [String] = []
        if let window = model.contextWindow { parts.append("\(tokens(window)) tokens of context") }
        if let tools = model.takesTools { parts.append(tools ? "takes tools" : "takes no tools") }
        if let input = model.inputPrice, let output = model.outputPrice {
            parts.append(input == 0 && output == 0 ? "free" : "\(dollars(input)) in, \(dollars(output)) out per million tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 131072 is "128K" and 200000 is "200K": windows come in powers of two
    /// or in round thousands.
    static func tokens(_ count: Int) -> String {
        let (unit, suffix) = count >= 1_000_000 ? (count % 1_048_576 == 0 ? 1_048_576 : 1_000_000, "M")
            : count >= 1_000 ? (count % 1_024 == 0 ? 1_024 : 1_000, "K") : (1, "")
        let value = Double(count) / Double(unit)
        return (value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)) + suffix
    }

    private static func dollars(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value < 0.1 ? 3 : 2
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(value))
    }

    /// What went wrong, for the note under the field, with what to check. The
    /// button is right there for trying again.
    static func message(for error: Error, assistant: Assistant, sentKey: Bool) -> String {
        let url = URL(string: assistant.baseURL)
        let place = url.map { [$0.host, $0.port.map(String.init)].compactMap { $0 }.joined(separator: ":") } ?? assistant.name
        // Most OpenAI-compatible addresses end in /v1, and a site's own
        // address answers with a web page or nothing at all.
        let check = assistant.kind == .openAI ? " Check that it is the API's address, which usually ends in /v1." : ""
        if let failure = error as? OpenAITransport.HTTPFailure {
            switch failure.status {
            case 401, 403: return sentKey ? "The server refused the key." : "The server wants the API key first."
            case 404: return "Nothing is listed at this address." + check + " Or type the model's name."
            case 429: return "The server is limiting requests. Try again in a moment."
            default: return "The server answered with an error (\(failure.status))."
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost:
                return assistant.isLocal ? "Nothing answers at \(place). Is the server running?" : "\(place) refused the connection."
            case .cannotFindHost, .dnsLookupFailed:
                return "There is no server called \(url?.host ?? place)."
            case .timedOut:
                return "\(place) did not answer in time."
            case .notConnectedToInternet, .networkConnectionLost:
                return "The Mac is offline."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "The secure connection to \(place) failed."
            case .appTransportSecurityRequiresSecureConnection:
                return "Only https is allowed for a server that is not on this Mac."
            default:
                return error.localizedDescription
            }
        }
        if let failure = error as? Failure { return failure.message + check }
        return error.localizedDescription
    }
}

extension Assistants {
    /// What an address was most likely meant to be: with a scheme when it has
    /// none (`http` on this Mac, `https` anywhere else), and without the
    /// endpoint a pasted example often ends in, which Imark adds itself.
    static func normalizedAddress(_ text: String, kind: Assistant.Kind) -> String {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "" }
        if !address.contains("://") {
            let host = address.lowercased()
            let local = ["localhost", "127.0.0.1", "[::1]"].contains { host == $0 || host.hasPrefix($0 + ":") || host.hasPrefix($0 + "/") }
                || host.split(separator: "/").first.map { $0.split(separator: ":").first?.hasSuffix(".local") ?? false } ?? false
            address = (local ? "http://" : "https://") + address
        }
        while address.hasSuffix("/") { address.removeLast() }
        let endings = kind == .anthropic
            ? ["/v1/messages", "/v1/models", "/v1"]
            : ["/chat/completions", "/completions", "/models"]
        if let ending = endings.first(where: { address.lowercased().hasSuffix($0) }) {
            address.removeLast(ending.count)
        }
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }
}
