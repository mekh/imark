import Foundation

/// `Imark --ask-mcp <document>`: the document's three tools as an MCP server on
/// standard input and output, for the command-line agents.
///
/// An agent like Claude Code brings tools of its own that reach the whole disk
/// and a shell. Ask switches all of them off and hands the agent this server
/// instead, so it gets exactly what an API model gets through Imark's own loop
/// — the headings, a stretch of lines, a search — and only for the one file.
/// The app's own executable plays the server, so there is nothing else to ship
/// and nothing that can drift from the app's version of the tools.
///
/// Messages are JSON-RPC, one per line, as MCP's stdio transport has them.
enum AskMCPServer {
    static let flag = "--ask-mcp"
    static let name = "imark"

    /// The names an agent sees the tools under once they are prefixed with the
    /// server's: `mcp__imark__read` and so on. Pre-approved by name, so an
    /// agent running without anybody to ask may call them and nothing else.
    static var qualifiedToolNames: [String] {
        DocumentTools.definitions.map { "mcp__\(name)__\($0.name)" }
    }

    static func run(documentPath: String) -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = respond(to: message, document: { try? String(contentsOfFile: documentPath, encoding: .utf8) }),
                  var bytes = try? JSONSerialization.data(withJSONObject: reply)
            else { continue }
            bytes.append(0x0A)
            FileHandle.standardOutput.write(bytes)
        }
        exit(0)
    }

    /// The reply to one message, or nil for a notification, which gets none.
    /// The document is read on every call rather than once: it is the file on
    /// disk the agent is asked about, and a save while it works is part of it.
    static func respond(to message: [String: Any], document: () -> String?) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        func result(_ value: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": value]
        }
        func failure(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            // Whatever version the client speaks: the server uses nothing that
            // changed between them.
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": Updates.current],
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": DocumentTools.definitions.map {
                [
                    "name": $0.name, "description": $0.description, "inputSchema": $0.schema,
                    // Said in so many words: Codex never asks before a tool
                    // call, and refuses one that is not marked as only reading.
                    "annotations": ["readOnlyHint": true, "openWorldHint": false],
                ]
            }])
        case "tools/call":
            guard let tool = params["name"] as? String else { return failure(-32602, "tools/call needs a name") }
            guard let text = document() else {
                return result(["content": [["type": "text", "text": "The document cannot be read."]], "isError": true])
            }
            let answer = DocumentTools(text: text).call(tool, params["arguments"] as? [String: Any] ?? [:])
            return result(["content": [["type": "text", "text": answer.text]], "isError": answer.isError])
        default:
            return failure(-32601, "No method \(method)")
        }
    }
}
