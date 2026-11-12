import Foundation

/// What a tool hands back: MCP content blocks (text, images).
struct ToolResult: @unchecked Sendable {
    var content: [[String: Any]]
    var isError = false

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": text]])
    }

    /// A JSON object rendered as pretty-printed text, which agents read easily.
    static func json(_ object: [String: Any]) -> ToolResult {
        .text(prettyJSON(object))
    }
}

/// A failure to report back to the agent as a tool error, with advice on what to do.
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func prettyJSON(_ object: Any) -> String {
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

struct Tool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let handler: @Sendable (_ arguments: [String: Any]) async throws -> ToolResult
}

/// A minimal Model Context Protocol server: newline-delimited JSON-RPC 2.0 on
/// standard input and output, offering tools only.
///
/// Standard output carries protocol messages and nothing else, so diagnostics
/// go to standard error.
final class MCPServer: @unchecked Sendable {
    private let name: String
    private let version: String
    private let instructions: String
    private let tools: [String: Tool]
    private let toolOrder: [String]
    private let outputLock = NSLock()
    /// Run before exiting when the client closes the connection.
    var onShutdown: (@Sendable () async -> Void)?

    init(name: String, version: String, instructions: String, tools: [Tool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.toolOrder = tools.map(\.name)
    }

    /// Reads messages on a background thread until the client closes standard input.
    func start() {
        Thread.detachNewThread { [self] in
            while let line = readLine(strippingNewline: true) {
                if line.allSatisfy(\.isWhitespace) { continue }
                receive(line)
            }
            Task {
                await onShutdown?()
                exit(0)
            }
        }
    }

    private func receive(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let message = object as? [String: Any]
        else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // Responses to requests we never sent, and notifications, need no reply.
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        Task {
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String
                respond(
                    id,
                    result: [
                        "protocolVersion": requested ?? "2025-06-18",
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": name, "version": version],
                        "instructions": instructions,
                    ])
            case "ping":
                respond(id, result: [:])
            case "tools/list":
                respond(
                    id,
                    result: [
                        "tools": toolOrder.compactMap { tools[$0] }.map {
                            ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
                        }
                    ])
            case "tools/call":
                guard let toolName = params["name"] as? String, let tool = tools[toolName] else {
                    return respond(id, errorCode: -32602, message: "Unknown tool: \(params["name"] ?? "")")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result: ToolResult
                do {
                    result = try await tool.handler(arguments)
                } catch {
                    var failure = ToolResult.text(error.localizedDescription)
                    failure.isError = true
                    result = failure
                }
                respond(id, result: ["content": result.content, "isError": result.isError])
            default:
                respond(id, errorCode: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func respond(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(_ id: Any, errorCode: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        else {
            log("Could not encode a reply.")
            return
        }
        data.append(0x0A)
        outputLock.lock()
        FileHandle.standardOutput.write(data)
        outputLock.unlock()
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("gifmaker-mcp: \(message)\n".utf8))
}

/// A number that prints in JSON with at most `places` decimals (4.02, not 4.0199999999999996).
func decimal(_ value: Double, places: Int = 2) -> NSNumber {
    NSDecimalNumber(string: String(format: "%.\(places)f", value))
}
