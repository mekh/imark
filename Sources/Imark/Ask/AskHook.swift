import Foundation

/// `Imark --ask-hook`: what a command-line agent runs before each tool call.
///
/// The agents' own tools are off already; this is the lock behind that, for a
/// tool that comes back in a later version or that the reader's setup adds:
/// only the document's three get through. Claude Code and Codex both hand the
/// call over as JSON on standard input and take status 2, with the reason on
/// standard error, as a refusal.
enum AskHook {
    static let flag = "--ask-hook"
    static let refusal = "Ask reads only the document."

    /// Whether the call may run. Input that cannot be read is refused.
    static func allows(_ input: Data) -> Bool {
        guard let call = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let tool = call["tool_name"] as? String else { return false }
        return AskMCPServer.qualifiedToolNames.contains(tool)
    }

    static func run() -> Never {
        if allows(FileHandle.standardInput.readDataToEndOfFile()) { exit(0) }
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(2)
    }

    /// The hook as a line for the agent's shell.
    static func command(executable: String) -> String {
        quoted(executable) + " " + flag
    }

    /// A word for `sh`: the dev build's path has a space in it.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
