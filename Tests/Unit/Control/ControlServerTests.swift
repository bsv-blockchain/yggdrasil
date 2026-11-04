import Darwin
import XCTest
@testable import Yggdrasil

// swiftlint:disable type_body_length

/// The control API's transport: HTTP over a Unix socket and 127.0.0.1, API
/// keys, the browser guards, and JSON-RPC and MCP on top. Uses a two-action
/// catalogue so this is about the plumbing, not the actions.
@MainActor
final class ControlServerTests: XCTestCase {
    private var services: AppServices!
    private var keys: APIKeyStore!
    private var server: ControlServer!
    private var socketPath: String!
    private var port: UInt16 = 0
    private var readKey = ""
    private var fullKey = ""
    private var pokes = 0

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        keys = APIKeyStore(database: services.database)
        readKey = try keys.create(name: "reader", scope: .read).secret
        fullKey = try keys.create(name: "writer", scope: .full).secret
        let catalogue = [
            ControlAction(
                name: "echo.get", summary: "Returns its text.", scope: .read,
                params: [.init("text", .string, "What to return.")]
            ) { params, _ in try .string(params.string("text")) },
            ControlAction(name: "thing.poke", summary: "Changes something.", scope: .full,
                          params: []) { [weak self] _, _ in
                self?.pokes += 1
                return .bool(true)
            },
            ControlAction(name: "thing.fail", summary: "Always fails.", scope: .read, params: []) { _, _ in
                throw ActionError.notRunning
            }
        ]
        let router = ControlRouter(keys: keys, catalogue: catalogue, services: services)
        server = ControlServer { request, peer in await router.handle(request, peer: peer) }
        socketPath = NSTemporaryDirectory() + "ygg-\(UUID().uuidString.prefix(8)).sock"
        try server.listen(.unix(path: socketPath))
        port = try server.listen(.loopback(port: 0))
        router.loopbackPort = port
    }

    override func tearDown() async throws {
        server.stop()
        services = nil
    }

    // MARK: - Parsing

    func testRequestIsParsedOnceItsBodyIsComplete() throws {
        let head = "POST /rpc HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nAuthorization: Bearer k\r\n\r\n"
        XCTAssertNil(try HTTPParser.parse(Data((head + "ab").utf8), maxBody: 100))
        let request = try XCTUnwrap(HTTPParser.parse(Data((head + "abcd").utf8), maxBody: 100))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/rpc")
        XCTAssertEqual(request.headers["authorization"], "Bearer k")
        XCTAssertEqual(request.body, Data("abcd".utf8))
    }

    func testABodyOverTheLimitIsRefusedBeforeItArrives() {
        let head = "POST /rpc HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(Data(head.utf8), maxBody: 1_000_000)) { error in
            XCTAssertEqual(error as? HTTPParser.Failure, .tooLarge)
        }
    }

    // MARK: - Authentication

    func testRPCOverTheSocketWithAKey() async throws {
        let response = try await unix(rpc("echo.get", ["text": .string("hi")]), key: readKey)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["result"], .string("hi"))
    }

    func testNoKeyOrAWrongKeyGets401() async throws {
        let missing = try await unix(rpc("echo.get", ["text": .string("hi")]), key: nil)
        XCTAssertEqual(missing.status, 401)
        let wrong = try await unix(rpc("echo.get", ["text": .string("hi")]), key: fullKey + "x")
        XCTAssertEqual(wrong.status, 401)
    }

    func testAReadKeyCantChangeAnything() async throws {
        let refused = try await unix(rpc("thing.poke"), key: readKey)
        XCTAssertEqual(refused.status, 403)
        let allowed = try await unix(rpc("thing.poke"), key: fullKey)
        XCTAssertEqual(allowed.json?["result"], .bool(true))
    }

    func testARevokedKeyStopsWorking() async throws {
        let key = try XCTUnwrap(keys.list().first { $0.name == "reader" })
        try keys.revoke(id: XCTUnwrap(key.id))
        let response = try await unix(rpc("echo.get", ["text": .string("hi")]), key: readKey)
        XCTAssertEqual(response.status, 401)
    }

    // MARK: - Loopback HTTP and browsers

    func testLoopbackHTTPWithTheRightHost() async throws {
        let response = try await tcp(rpc("echo.get", ["text": .string("hi")]), key: readKey)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["result"], .string("hi"))
    }

    func testAnotherHostNameIsRefused() async throws {
        // A DNS-rebinding page reaches 127.0.0.1 under its own name.
        let response = try await tcp(
            rpc("echo.get", ["text": .string("hi")]),
            key: readKey,
            host: "evil.example:\(port)"
        )
        XCTAssertEqual(response.status, 403)
    }

    func testABrowserRequestIsRefused() async throws {
        let response = try await tcp(
            rpc("echo.get", ["text": .string("hi")]), key: readKey, extraHeaders: ["Origin": "https://evil.example"]
        )
        XCTAssertEqual(response.status, 403)
    }

    func testARequestWithoutAHostIsRefused() async throws {
        let response = try await tcp(rpc("echo.get", ["text": .string("hi")]), key: readKey, sendHost: false)
        XCTAssertEqual(response.status, 403)
    }

    func testTheHostIsCheckedBeforeTheKey() async throws {
        let response = try await tcp(rpc("thing.poke"), key: "ygg_wrong", host: "evil.example:\(port)")
        XCTAssertEqual(response.status, 403)
    }

    // MARK: - JSON-RPC errors

    func testErrorsCarryAStableReason() async throws {
        let failed = try await unix(rpc("thing.fail"), key: readKey)
        XCTAssertEqual(failed.json?["error"]?["data"]?["reason"], .string("not_running"))
        let unknown = try await unix(rpc("no.such"), key: readKey)
        XCTAssertEqual(unknown.json?["error"]?["code"], .number(-32601))
        let missing = try await unix(rpc("echo.get"), key: readKey)
        XCTAssertEqual(missing.json?["error"]?["code"], .number(-32602))
    }

    // MARK: - MCP

    func testMCPInitializeListAndCall() async throws {
        let initialize = try await unix(
            mcp("initialize", ["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])]),
            key: readKey, path: "/mcp"
        )
        XCTAssertEqual(initialize.json?["result"]?["serverInfo"]?["name"], .string("yggdrasil"))
        XCTAssertEqual(initialize.json?["result"]?["protocolVersion"], .string("2025-06-18"))

        let initialized = try await unix(mcp("notifications/initialized", nil, id: nil), key: readKey, path: "/mcp")
        XCTAssertEqual(initialized.status, 202)

        let list = try await unix(mcp("tools/list"), key: readKey, path: "/mcp")
        guard case let .array(tools)? = list.json?["result"]?["tools"] else { return XCTFail("no tools") }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), ["echo_get", "thing_fail"], "a read key only sees what it may call")
        let echo = try XCTUnwrap(tools.first { $0["name"] == .string("echo_get") })
        XCTAssertEqual(echo["inputSchema"]?["required"], .array([.string("text")]))

        let call = try await unix(
            mcp("tools/call", ["name": .string("echo_get"), "arguments": .object(["text": .string("hi")])]),
            key: readKey, path: "/mcp"
        )
        XCTAssertEqual(call.json?["result"]?["content"], .array([.object([
            "type": .string("text"), "text": .string("\"hi\"")
        ])]))

        let failed = try await unix(mcp("tools/call", ["name": .string("thing_fail")]), key: readKey, path: "/mcp")
        XCTAssertEqual(failed.json?["result"]?["isError"], .bool(true))
    }

    func testAReadKeyCantRunAFullActionAsANotification() async throws {
        // Without an id nothing is sent back on success, so the refusal has
        // to come before the action runs.
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("thing.poke")]).encoded()
        let refused = try await unix(message, key: readKey)
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(pokes, 0)
        let allowed = try await unix(message, key: fullKey)
        XCTAssertEqual(allowed.status, 204)
        XCTAssertEqual(pokes, 1)
    }

    func testMCPHasNoEventStream() async throws {
        let response = try await unix(Data(), key: readKey, path: "/mcp", method: "GET")
        XCTAssertEqual(response.status, 405)
    }

    func testAReadKeyCantCallAFullToolOverMCP() async throws {
        let call = try await unix(mcp("tools/call", ["name": .string("thing_poke")]), key: readKey, path: "/mcp")
        XCTAssertNotNil(call.json?["error"], "refused, not run")
        XCTAssertNil(call.json?["result"])
    }

    func testOnlyTheLoopbackHostNamesWithTheirPortGetThrough() async throws {
        let body = rpc("echo.get", ["text": .string("hi")])
        for host in ["localhost:\(port)", "LOCALHOST:\(port)"] {
            let response = try await tcp(body, key: readKey, host: host)
            XCTAssertEqual(response.status, 200, host)
        }
        for host in ["127.0.0.1", "localhost", "127.0.0.1:1", "localhost.evil.example:\(port)", ""] {
            let response = try await tcp(body, key: readKey, host: host)
            XCTAssertEqual(response.status, 403, host)
        }
        let nullOrigin = try await tcp(body, key: readKey, extraHeaders: ["Origin": "null"])
        XCTAssertEqual(nullOrigin.status, 403)
    }

    // MARK: - Robustness

    func testAHugeIntegerIsRefusedNotACrash() throws {
        let action = ControlAction(name: "n.get", summary: "n", scope: .read, params: [.init(
            "n",
            .integer,
            "n"
        )]) { _, _ in
            .null
        }
        XCTAssertThrowsError(try action.validate(["n": .number(1e19)])) { error in
            XCTAssertEqual(error as? ActionError, .invalidArgument("n"))
        }
        XCTAssertNil(JSONValue.number(-1e300).intValue)
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
    }

    func testJSONKeepsBooleansAndNumbersApart() throws {
        let value = try JSONValue.decode(Data(#"{"a":true,"b":1,"c":[0,false,"x",null],"d":1.5}"#.utf8))
        XCTAssertEqual(value, .object([
            "a": .bool(true), "b": .number(1), "c": .array([.number(0), .bool(false), .string("x"), .null]),
            "d": .number(1.5)
        ]))
    }

    func testDeeplyNestedJSONIsRefusedQuickly() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        XCTAssertThrowsError(try JSONValue.decode(Data(deep.utf8)))
    }

    func testRestartingOnTheSamePathKeepsTheNewSocket() async throws {
        server.stop()
        let again = ControlServer { _, _ in .empty(204) }
        defer { again.stop() }
        try again.listen(.unix(path: socketPath))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the old listener's cleanup left it alone")
    }

    func testConnectionsOverTheCapAreClosedUntilOthersEnd() async throws {
        let socketPath = try XCTUnwrap(socketPath)
        let idle = try (0 ..< ControlServer.maxConnections)
            .map { _ in try Self.connect(unixPath: socketPath, port: nil) }
        try await Task.sleep(for: .milliseconds(200))
        let turnedAway = try await unix(rpc("echo.get", ["text": .string("hi")]), key: readKey)
        XCTAssertEqual(turnedAway.status, 0, "closed without an answer")

        idle.forEach { close($0) }
        try await Task.sleep(for: .milliseconds(200))
        let served = try await unix(rpc("echo.get", ["text": .string("hi")]), key: readKey)
        XCTAssertEqual(served.status, 200)
    }

    func testListenersAreNotInheritedByAgents() {
        // Agents are spawned with forkpty: anything without close-on-exec
        // would stay open in every agent.
        XCTAssertFalse(server.descriptors.isEmpty)
        for descriptor in server.descriptors {
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        }
    }

    // MARK: - Helpers

    private struct Response {
        let status: Int
        let json: JSONValue?
    }

    private func rpc(_ method: String, _ params: [String: JSONValue]? = nil) -> Data {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method)]
        if let params { message["params"] = .object(params) }
        return JSONValue.object(message).encoded()
    }

    private func mcp(_ method: String, _ params: [String: JSONValue]? = nil, id: Int? = 1) -> Data {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { message["id"] = .int(id) }
        if let params { message["params"] = .object(params) }
        return JSONValue.object(message).encoded()
    }

    // swiftlint:disable:next function_parameter_count
    private func request(
        _ body: Data, key: String?, path: String, method: String, host: String?, extraHeaders: [String: String]
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        if let host { head += "Host: \(host)\r\n" }
        head += "Content-Type: application/json\r\n"
        head += "Accept: application/json, text/event-stream\r\nContent-Length: \(body.count)\r\n"
        if let key { head += "Authorization: Bearer \(key)\r\n" }
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }

    private func unix(_ body: Data, key: String?, path: String = "/rpc",
                      method: String = "POST") async throws -> Response {
        let bytes = request(body, key: key, path: path, method: method, host: "localhost", extraHeaders: [:])
        let socketPath = socketPath!
        return try await Task.detached { try Self.exchange(bytes, unixPath: socketPath, port: nil) }.value
    }

    private func tcp(
        _ body: Data, key: String?, host: String? = nil, sendHost: Bool = true, extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        let bytes = request(
            body, key: key, path: "/rpc", method: "POST",
            host: sendHost ? host ?? "127.0.0.1:\(port)" : nil, extraHeaders: extraHeaders
        )
        let port = port
        return try await Task.detached { try Self.exchange(bytes, unixPath: nil, port: port) }.value
    }

    private nonisolated static func exchange(_ bytes: Data, unixPath: String?, port: UInt16?) throws -> Response {
        let descriptor = try connect(unixPath: unixPath, port: port)
        defer { close(descriptor) }
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0 ..< count])
        }
        let text = String(bytes: received, encoding: .utf8) ?? ""
        let parts = text.components(separatedBy: "\r\n\r\n")
        let status = Int(parts[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        return Response(status: status, json: try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))
    }

    private nonisolated static func connect(unixPath: String?, port: UInt16?) throws -> Int32 {
        let descriptor = socket(unixPath == nil ? AF_INET : AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected: Int32
        if let unixPath {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                _ = unixPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port ?? 0).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }
}

// swiftlint:enable type_body_length
