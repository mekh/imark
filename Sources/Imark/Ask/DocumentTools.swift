import Foundation

/// The three things an assistant may do with the document it is asked about:
/// see its headings, read a stretch of it, and search it.
///
/// This is the whole of an assistant's reach, whichever kind it is. API models
/// call these through Imark's own loop; the command-line agents get the same
/// three through `AskMCPServer`, with their own tools switched off. A document
/// is somebody else's text, and text can be written to talk to a model: the
/// most it can talk one into here is reading more of the same document.
///
/// Lines are counted from one, as a person and a model count them. The page
/// counts from zero; `AskController` converts at the edge.
struct DocumentTools {
    let lines: [String]

    init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    /// Enough for a long section, short of a whole long document per call: a
    /// model that wants more asks again from where this stopped.
    static let readLimit = 200
    static let searchLimit = 30
    /// A line longer than this is cut in search results. A minified blob or a
    /// table row can be thousands of characters, and the match is in there.
    static let lineLimit = 300

    struct Definition {
        let name: String
        let description: String
        let schema: [String: Any]
    }

    static let definitions: [Definition] = [
        Definition(
            name: "outline",
            description: "List the headings of the document with their line numbers.",
            schema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ),
        Definition(
            name: "read",
            description: "Read lines of the document, numbered. Returns at most \(readLimit) lines per call.",
            schema: [
                "type": "object",
                "properties": [
                    "from": ["type": "integer", "description": "First line to read, counting from 1."],
                    "to": ["type": "integer", "description": "Last line to read, inclusive."],
                ],
                "required": ["from", "to"],
                "additionalProperties": false,
            ]
        ),
        Definition(
            name: "search",
            description: "Find the lines of the document that contain the given text, ignoring case. "
                + "Returns each matching line with its number.",
            schema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The text to look for."],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ]
        ),
    ]

    struct Result {
        let text: String
        let activity: AskActivity?
        let isError: Bool
    }

    func call(_ name: String, _ arguments: [String: Any]) -> Result {
        switch name {
        case "outline":
            let text = outline()
            return Result(text: text, activity: Self.describe(name, arguments, result: text), isError: false)
        case "read":
            guard let from = Self.integer(arguments["from"]), let to = Self.integer(arguments["to"]) else {
                return Result(text: "read needs `from` and `to` line numbers.", activity: nil, isError: true)
            }
            let text = read(from: from, to: to)
            return Result(text: text, activity: Self.describe(name, arguments, result: text), isError: false)
        case "search":
            guard let query = arguments["query"] as? String,
                  !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Result(text: "search needs a `query`.", activity: nil, isError: true)
            }
            let text = search(query)
            return Result(text: text, activity: Self.describe(name, arguments, result: text), isError: false)
        default:
            return Result(text: "There is no tool called \(name).", activity: nil, isError: true)
        }
    }

    func outline() -> String {
        let found = headingLines().map { "L\($0.index + 1) \(String(repeating: "#", count: $0.level)) \($0.title)" }
        return found.isEmpty
            ? "The document has no headings. It has \(lines.count) lines."
            : "The document has \(lines.count) lines.\n" + found.joined(separator: "\n")
    }

    func read(from: Int, to: Int) -> String {
        guard !lines.isEmpty else { return "The document is empty." }
        let first = min(max(from, 1), lines.count)
        let last = min(max(to, first), lines.count, first + Self.readLimit - 1)
        var text = (first...last).map { "L\($0): \(lines[$0 - 1])" }.joined(separator: "\n")
        if last < min(max(to, first), lines.count) {
            text += "\n(Stopped at L\(last). Read again from L\(last + 1) for more.)"
        }
        return text
    }

    /// The query as written first; if nothing has it, lines that have every one
    /// of its words, because a model searching for "retry limit" means a line
    /// about retries and limits more often than those two words side by side.
    func search(_ query: String) -> String {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var hits = matches { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if hits.isEmpty {
            let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > 1 {
                hits = matches { line in
                    words.allSatisfy { line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                }
            }
        }
        guard !hits.isEmpty else { return "0 matches for “\(needle)”." }
        let shown = hits.prefix(Self.searchLimit).map { index -> String in
            let line = lines[index]
            let cut = line.count > Self.lineLimit ? String(line.prefix(Self.lineLimit)) + "…" : line
            return "L\(index + 1): \(cut)"
        }
        var text = "\(hits.count) \(hits.count == 1 ? "match" : "matches") for “\(needle)”.\n" + shown.joined(separator: "\n")
        if hits.count > Self.searchLimit {
            text += "\n(Showing the first \(Self.searchLimit). Search for something narrower to see the rest.)"
        }
        return text
    }

    private func matches(_ test: (String) -> Bool) -> [Int] {
        lines.indices.filter { test(lines[$0]) }
    }

    /// The line the chat shows for a tool call, from what was asked and what came
    /// back. Shared with the command-line agents, whose tool calls arrive as
    /// events in their output rather than through `call`.
    static func describe(_ name: String, _ arguments: [String: Any], result: String?) -> AskActivity? {
        switch name {
        case "outline":
            return AskActivity(kind: .outline, text: "Looked at the headings")
        case "read":
            guard let from = integer(arguments["from"]), let to = integer(arguments["to"]) else { return nil }
            return AskActivity(kind: .read, text: from == to ? "Read line \(from)" : "Read lines \(from)–\(to)")
        case "search":
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var text = "Searched for “\(query)”"
            if let result, let count = Int(result.prefix { $0.isNumber }) {
                text += count == 0 ? " — nothing found" : " — \(count) \(count == 1 ? "place" : "places")"
            }
            return AskActivity(kind: .search, text: text)
        default:
            return nil
        }
    }

    /// Models send numbers as numbers, as strings, and now and then as 12.0.
    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Double: return Int(n)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    // MARK: - For prompts

    /// Lines with their numbers, the way `read` returns them, for a prompt that
    /// hands the model part of the document up front.
    func numbered(_ range: Range<Int>) -> String {
        let clamped = range.clamped(to: 0..<lines.count)
        return clamped.map { "L\($0 + 1): \(lines[$0])" }.joined(separator: "\n")
    }

    /// The section a line sits in: from the heading above it to the next heading
    /// of the same level or higher. Zero-based, end exclusive.
    func section(around line: Int) -> (title: String, range: Range<Int>) {
        let headings = headingLines()
        let above = headings.last { $0.index <= line }
        let start = above?.index ?? 0
        let level = above?.level ?? 0
        let next = headings.first { $0.index > start && (level == 0 || $0.level <= level) }
        return (above?.title ?? "", start..<(next?.index ?? lines.count))
    }

    /// ATX headings outside fenced code: a `# comment` in a shell block is not a
    /// heading, and an outline that says it is sends the model to the wrong place.
    private func headingLines() -> [(index: Int, level: Int, title: String)] {
        var found: [(Int, Int, String)] = []
        var fence: String?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            guard line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).first == " " else { continue }
            found.append((index, hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
        }
        return found
    }
}
