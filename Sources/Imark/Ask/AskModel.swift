import Foundation

/// One conversation about a passage of a document — or about the document as a
/// whole, when it has no quote.
///
/// The passage is found again the way a note is: by its words, in the block
/// the lines point at, the nth time they occur there. Lines alone would lose it
/// the first time a paragraph was added above; words alone would find the
/// first of several.
struct AskChat: Codable, Equatable {
    var id: String
    /// The document, as a resolved path: the same file reached through a
    /// symlink is the same document.
    var document: String
    var quote: String
    /// The tightest block holding the quote, as the page numbers lines: from
    /// zero, the end being the line after the last one.
    var line: Int?
    var end: Int?
    /// The top-level block, which is where a note goes when an answer is kept.
    var blockEnd: Int?
    var occurrence: Int
    /// The heading the passage sits under, for the prompt and the chat list.
    var section: String
    var created: Date
    var updated: Date
    var assistant: String
    var model: String
    /// A command-line agent's own session, so a follow-up continues it rather
    /// than sending the whole chat again.
    var session: String?
    var turns: [AskTurn]

    var isAboutDocument: Bool { quote.isEmpty }

    /// What the page needs to draw the chat. Dates go as milliseconds, which is
    /// what `new Date()` takes.
    var page: [String: Any] {
        [
            "id": id,
            "quote": quote,
            "line": line.map { $0 as Any } ?? NSNull(),
            "end": end.map { $0 as Any } ?? NSNull(),
            "blockEnd": blockEnd.map { $0 as Any } ?? NSNull(),
            "occurrence": occurrence,
            "section": section,
            "created": created.timeIntervalSince1970 * 1000,
            "updated": updated.timeIntervalSince1970 * 1000,
            "assistant": Assistants.name(of: assistant),
            "model": model,
            "turns": turns.map(\.page),
        ]
    }
}

struct AskTurn: Codable, Equatable {
    var question: String
    var answer: String = ""
    var activity: [AskActivity] = []
    var usage: AskUsage?
    var error: String?
    /// Who answered, and with which model: a chat goes on with whoever is
    /// picked, so one chat can have several. Nil in chats kept before it was
    /// written down.
    var assistant: String?
    var model: String?

    /// "Claude Code · haiku", for the usage of the answer.
    var answeredBy: String? {
        guard let assistant else { return nil }
        guard let model, !model.isEmpty else { return assistant }
        return "\(assistant) · \(Assistants.shortModel(model))"
    }

    var page: [String: Any] {
        [
            "question": question,
            "answer": answer,
            "activity": activity.map(\.page),
            "usage": usage?.page ?? NSNull(),
            "error": error ?? NSNull(),
            "by": answeredBy ?? NSNull(),
        ]
    }
}

/// A line in the chat saying what the assistant looked at before answering.
struct AskActivity: Codable, Equatable {
    enum Kind: String, Codable { case outline, read, search }

    var kind: Kind
    var text: String

    var page: [String: Any] { ["kind": kind.rawValue, "text": text] }
}

/// What one answer cost, as reported by whoever ran the model. Every figure is
/// optional because providers report different subsets, and a figure nobody
/// reported is shown as missing rather than as a zero somebody would believe.
struct AskUsage: Codable, Equatable {
    var input: Int?
    var cachedInput: Int?
    var output: Int?
    var reasoning: Int?
    /// Requests to the model behind this one answer: one, plus one for every
    /// round of tools.
    var rounds: Int = 1
    var seconds: Double?
    var firstToken: Double?
    var cost: Double?
    /// Who the cost comes from, said next to it: an estimate from a command-line
    /// agent is not what an API bills.
    var costSource: String?
    /// The model runs on this Mac, so there is nothing to pay.
    var local: Bool = false
    /// How much of the model's context the chat fills now, when that is known.
    var context: Int?
    var window: Int?
    /// Codex counts a session's tokens from its start and says only the sum;
    /// kept, so the next answer in the session can take it away from its own.
    var sessionTotal: SessionTotal?

    struct SessionTotal: Codable, Equatable {
        var input = 0
        var cachedInput = 0
        var output = 0
        var reasoning = 0
    }

    var page: [String: Any] {
        func value<T>(_ x: T?) -> Any { x.map { $0 as Any } ?? NSNull() }
        return [
            "input": value(input), "cachedInput": value(cachedInput),
            "output": value(output), "reasoning": value(reasoning),
            "rounds": rounds, "seconds": value(seconds), "firstToken": value(firstToken),
            "cost": value(cost), "costSource": value(costSource), "local": local,
            "context": value(context), "window": value(window),
        ]
    }

    /// Adds another request's figures to these: an answer that took three rounds
    /// of tools cost the three together.
    mutating func add(_ other: AskUsage) {
        func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        input = sum(input, other.input)
        cachedInput = sum(cachedInput, other.cachedInput)
        output = sum(output, other.output)
        reasoning = sum(reasoning, other.reasoning)
        if let c = other.cost { cost = (cost ?? 0) + c }
        costSource = costSource ?? other.costSource
        context = other.context ?? context
        window = other.window ?? window
    }
}

/// What a transport tells the chat while it works, always on the main thread.
enum AskEvent: Equatable {
    /// A command-line agent's session, to continue on the next question.
    case session(String)
    case activity(AskActivity)
    /// Text to add to the answer.
    case delta(String)
    /// The answer so far is thrown away: the model said something before
    /// reaching for a tool, and only what it says after the last tool answers.
    case restart
    case usage(AskUsage)
    case finished
    case failed(AskFailure)
}

struct AskFailure: Error, Equatable {
    enum Remedy: String { case signIn, install, settings, none }

    var message: String
    var remedy: Remedy = .none
}
