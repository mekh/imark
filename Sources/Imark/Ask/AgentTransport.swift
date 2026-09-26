import Foundation

/// What a command-line agent's output is read with, a line at a time. Kept
/// apart from the process so the tests can feed it recorded output.
protocol AgentStreamParser {
    /// The agent has said its last: an answer or a failure.
    var done: Bool { get }
    /// It said the session to continue does not exist.
    var sessionMissing: Bool { get }
    mutating func feed(_ line: String, since start: Date) -> [AskEvent]
}

/// Asks a command-line agent through its own command: its login, its
/// subscription, no key in Imark. How each is started and what it prints
/// differ, and live in the subclasses; running the process, reading its
/// lines, and asking again when its session is gone are the same.
class AgentTransport: AskTransport {
    private var process: Process?
    private var cancelled = false
    private var parser: any AgentStreamParser
    private var buffer = Data()
    private var errors = Data()
    private var request: AskRequest?
    private var emit: ((AskEvent) -> Void)?
    private var started = Date()
    /// Set once the session could not be continued and the question went again
    /// with the chat written out, so that does not loop.
    private var retriedWithoutSession = false
    /// Which launch the output belongs to. A question asked again leaves the
    /// first process to wind down, and its last words must not end the second.
    private var generation = 0

    /// The server the agent starts for the document's tools: the app itself.
    /// Replaced by the tests, whose executable is not the app.
    static var mcpExecutable: String? = Bundle.main.executablePath

    /// Where the agents run and keep their sessions: a folder of their own, so
    /// no project's instructions come along and the sessions stay out of the
    /// reader's projects.
    static var workingFolder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Imark/Ask", isDirectory: true)
    }()

    init() {
        parser = Self.idle
    }

    /// Before the first launch.
    private static let idle: any AgentStreamParser = IdleParser()

    private struct IdleParser: AgentStreamParser {
        var done: Bool { true }
        var sessionMissing: Bool { false }
        mutating func feed(_ line: String, since start: Date) -> [AskEvent] { [] }
    }

    // MARK: - What each agent says for itself

    /// "Claude Code", for messages.
    class var agentName: String { "" }
    /// What reads one launch's output; a question asked again gets a new one.
    func makeParser(for request: AskRequest, resume: Bool) -> any AgentStreamParser {
        fatalError("an agent says how its output is read")
    }
    func arguments(for request: AskRequest, resume: Bool) -> [String] { [] }
    /// What goes in on standard input.
    func prompt(for request: AskRequest, resume: Bool) -> String { request.question }
    func prepare(_ environment: inout [String: String]) {}

    // MARK: - Running it

    func start(_ request: AskRequest, emit: @escaping (AskEvent) -> Void) {
        self.request = request
        self.emit = emit
        launch(resume: request.chat.session != nil && !request.chat.turns.isEmpty)
    }

    func cancel() {
        cancelled = true
        emit = nil
        process?.terminate()
    }

    private func launch(resume: Bool) {
        guard let request else { return }
        let name = Self.agentName
        guard let executable = Assistants.executable(for: request.assistant) else {
            return send(.failed(AskFailure(message: "\(name) is not set up: choose its executable in Settings ▸ Assistants.", remedy: .settings)))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: request, resume: resume)
        var environment = ProcessInfo.processInfo.environment
        // The agent's own folder first: one installed with npm is a Node
        // script, and the `node` beside it is the one it was installed with.
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + Assistants.searchPath
        prepare(&environment)
        process.environment = environment
        try? FileManager.default.createDirectory(at: Self.workingFolder, withIntermediateDirectories: true)
        process.currentDirectoryURL = Self.workingFolder

        let input = Pipe()
        let output = Pipe()
        let failure = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = failure

        parser = makeParser(for: request, resume: resume)
        buffer = Data()
        errors = Data()
        started = Date()
        generation += 1
        let current = generation

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.receive(data)
            }
        }
        failure.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.errors.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            failure.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.receive(rest)
                self.ended()
            }
        }

        do {
            try process.run()
        } catch {
            return send(.failed(AskFailure(message: "\(name) could not be started: \(error.localizedDescription)", remedy: .install)))
        }
        self.process = process
        // The question goes in on standard input: as an argument, one that
        // starts with a dash would be read as a flag.
        input.fileHandleForWriting.write(Data(prompt(for: request, resume: resume).utf8))
        try? input.fileHandleForWriting.close()
    }

    private func receive(_ data: Data) {
        guard !cancelled, !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8) else { continue }
            for event in parser.feed(text, since: started) { handle(event) }
        }
    }

    private func handle(_ event: AskEvent) {
        if case .failed = event, parser.sessionMissing, !retriedWithoutSession, request?.chat.session != nil {
            // Agents clear old sessions out on their own. The chat is still
            // here: ask again with it written out.
            retriedWithoutSession = true
            request?.chat.session = nil
            process = nil
            return launch(resume: false)
        }
        send(event)
    }

    /// The process is gone and the parser never heard an end: whatever it
    /// said on its way out is the reason.
    private func ended() {
        guard !cancelled, emit != nil, !parser.done else { return }
        let said = String(data: errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = said.split(separator: "\n").last.map(String.init) ?? ""
        send(.failed(failure(said: last)))
    }

    /// What the last line on standard error means; the agent may know better.
    func failure(said: String) -> AskFailure {
        AskFailure(message: said.isEmpty ? "\(Self.agentName) stopped without answering." : said)
    }

    private func send(_ event: AskEvent) {
        guard !cancelled else { return }
        emit?(event)
        switch event {
        case .finished, .failed: emit = nil
        default: break
        }
    }

    /// The first question of a chat, or any question once its session is gone:
    /// then the earlier turns are written out ahead of it.
    static func conversation(for request: AskRequest) -> String {
        let earlier = AskTransports.history(request.chat.turns)
        var text = AskPrompt.opening(
            for: request.chat, question: earlier.first?.question ?? request.question,
            name: request.document.lastPathComponent, tools: request.tools, document: .none
        )
        guard !earlier.isEmpty else { return text }
        for (index, turn) in earlier.enumerated() {
            if index > 0 { text += "\n\nQuestion: \(turn.question)" }
            text += "\n\nYour answer: \(turn.answer)"
        }
        text += "\n\nQuestion: \(request.question)"
        return text
    }
}
