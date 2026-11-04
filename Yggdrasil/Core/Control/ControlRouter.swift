import Foundation

/// Checks who's asking, then answers JSON-RPC at `/rpc` and MCP (Streamable
/// HTTP, plain JSON responses) at `/mcp`.
@MainActor
final class ControlRouter {
    private let keys: APIKeyStore
    private let catalogue: [ControlAction]
    private let services: AppServices
    /// The 127.0.0.1 port, to check the Host header against.
    var loopbackPort: UInt16 = 0

    init(keys: APIKeyStore, catalogue: [ControlAction], services: AppServices) {
        self.keys = keys
        self.catalogue = catalogue
        self.services = services
    }

    nonisolated func handle(_ request: HTTPRequest, peer: ControlServer.Peer) async -> HTTPResponse {
        // Parsed here, off the main actor: a body can be up to 1 MB.
        let message = try? JSONValue.decode(request.body)
        return await route(request, message: message, peer: peer)
    }

    private func route(_ request: HTTPRequest, message: JSONValue?, peer: ControlServer.Peer) async -> HTTPResponse {
        if peer.viaLoopbackTCP {
            // A page in a browser can reach 127.0.0.1, under its own host
            // name after a DNS rebind; it always sends an Origin.
            let allowed = ["127.0.0.1:\(loopbackPort)", "localhost:\(loopbackPort)"]
            guard let host = request.headers["host"]?.lowercased(), allowed.contains(host) else {
                return .json(Self.failure(nil, -32003, "Wrong Host header."), status: 403)
            }
            guard request.headers["origin"] == nil else {
                return .json(Self.failure(nil, -32003, "Browsers can't use this API."), status: 403)
            }
        }
        // No delay on a bad key: a key is 256 random bits, and a delay would
        // hold one of the server's few connection slots.
        guard let key = authenticate(request) else {
            YggdrasilLog.control.warning("Refused \(request.path, privacy: .public): no valid API key")
            return .json(Self.failure(nil, -32001, "A valid API key is required."), status: 401)
        }
        switch (request.method, request.path) {
        case ("POST", "/rpc"): return await rpc(message, key: key)
        case ("POST", "/mcp"): return await mcp(message, key: key)
        case (_, "/mcp"): return .empty(405)
        default: return .empty(404)
        }
    }

    private func authenticate(_ request: HTTPRequest) -> APIKey? {
        guard let header = request.headers["authorization"],
              header.lowercased().hasPrefix("bearer ") else { return nil }
        let secret = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return try? keys.verify(secret: secret)
    }

    // MARK: - JSON-RPC

    private func rpc(_ message: JSONValue?, key: APIKey) async -> HTTPResponse {
        guard let message,
              let method = message["method"]?.stringValue
        else { return .json(Self.failure(nil, -32700, "Expected a JSON-RPC request."), status: 400) }
        let id = message["id"]
        if method == "actions.list" {
            return .json(Self.success(id, .array(catalogue.map(Self.describe))))
        }
        guard let action = catalogue.first(where: { $0.name == method }) else {
            return .json(Self.failure(id, -32601, "No method \(method)."))
        }
        guard Self.allows(key, action) else {
            return .json(Self.failure(id, -32002, "This key can only read."), status: 403)
        }
        let outcome = await run(action, arguments: message["params"], key: key)
        let response: JSONValue = switch outcome {
        case let .success(result): Self.success(id, result)
        case let .failure(error): Self.failure(id, error.code, error.message, reason: error.reason)
        }
        // A request without an id is a notification: no reply expected.
        return id == nil ? .empty(204) : .json(response)
    }

    // MARK: - MCP

    private func mcp(_ message: JSONValue?, key: APIKey) async -> HTTPResponse {
        guard let message,
              let method = message["method"]?.stringValue
        else { return .json(Self.failure(nil, -32700, "Expected a JSON-RPC message."), status: 400) }
        let id = message["id"]
        guard id != nil else { return .empty(202) }
        switch method {
        case "initialize":
            let requested = message["params"]?["protocolVersion"]?.stringValue
            return .json(Self.success(id, .object([
                "protocolVersion": .string(requested ?? "2025-06-18"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("yggdrasil"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
                ]),
                "instructions": .string(Self.instructions)
            ])))
        case "ping":
            return .json(Self.success(id, .object([:])))
        case "tools/list":
            let tools = catalogue.filter { Self.allows(key, $0) }.map { action in
                JSONValue.object([
                    "name": .string(action.toolName),
                    "description": .string(action.summary),
                    "inputSchema": action.inputSchema
                ])
            }
            return .json(Self.success(id, .object(["tools": .array(tools)])))
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            guard let action = catalogue.first(where: { $0.toolName == name }), Self.allows(key, action) else {
                return .json(Self.failure(id, -32602, "No tool \(name)."))
            }
            let outcome = await run(action, arguments: message["params"]?["arguments"], key: key)
            let content: JSONValue = switch outcome {
            case let .success(result):
                .object(["content": .array([.object(["type": .string("text"), "text": .string(result.jsonText)])])])
            case let .failure(error):
                .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(error.message)])]),
                    "isError": .bool(true)
                ])
            }
            return .json(Self.success(id, content))
        default:
            return .json(Self.failure(id, -32601, "No method \(method)."))
        }
    }

    // MARK: - Running actions

    private struct Failure: Error {
        let code: Int
        let message: String
        let reason: String?
    }

    private func run(_ action: ControlAction, arguments: JSONValue?, key: APIKey) async -> Result<JSONValue, Failure> {
        let raw: [String: JSONValue]
        switch arguments {
        case nil, .null?: raw = [:]
        case let .object(fields)?: raw = fields
        default: return .failure(Failure(
                code: -32602,
                message: "Arguments must be an object.",
                reason: "invalid_argument"
            ))
        }
        let params: ActionParams
        do {
            params = try action.validate(raw)
        } catch {
            return .failure(Failure(code: -32602, message: error.actionMessage, reason: "invalid_argument"))
        }
        YggdrasilLog.control.info("\(key.name, privacy: .public) ran \(action.name, privacy: .public)")
        do {
            return try await .success(action.run(params, .init(services: services, key: key)))
        } catch let error as ActionError {
            return .failure(Failure(code: -32000, message: error.actionMessage, reason: error.reason))
        } catch {
            return .failure(Failure(code: -32000, message: error.actionMessage, reason: "failed"))
        }
    }

    private static func allows(_ key: APIKey, _ action: ControlAction) -> Bool {
        action.scope == .read || key.scope == .full
    }

    private static func describe(_ action: ControlAction) -> JSONValue {
        .object([
            "name": .string(action.name), "summary": .string(action.summary),
            "scope": .string(action.scope.rawValue), "params": action.inputSchema
        ])
    }

    private static func success(_ id: JSONValue?, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
    }

    private static func failure(_ id: JSONValue?, _ code: Int, _ message: String, reason: String? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let reason { error["data"] = .object(["reason": .string(reason)]) }
        return .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "error": .object(error)])
    }

    static let instructions = """
    Yggdrasil runs coding agents (Claude and others) in tabs, each on a git branch in its own \
    worktree, on this Mac or on an ssh host. Use tabs_list to see the tabs and what needs \
    attention, tab_screen to read an agent's terminal, and tab_send to type into it. tab_open \
    opens a new tab; tab_start starts its agent without changing what the user is looking at.
    """
}
