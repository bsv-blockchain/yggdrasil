import XCTest
@testable import Yggdrasil

/// The built `yggctl`, from inside the app bundle, against a control server
/// on a throwaway socket.
@MainActor
final class YggctlIntegrationTests: XCTestCase {
    private var server: ControlServer!
    private var socketPath: String!
    private var key = ""

    override func setUp() async throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        let keys = APIKeyStore(database: services.database)
        key = try keys.create(name: "cli", scope: .read).secret
        let catalogue = [
            ControlAction(
                name: "echo.get", summary: "Returns its number doubled.", scope: .read,
                params: [.init("n", .integer, "A number.")]
            ) { params, _ in try .int(params.int("n") * 2) }
        ]
        let router = ControlRouter(keys: keys, catalogue: catalogue, services: services)
        server = ControlServer { request, peer in await router.handle(request, peer: peer) }
        socketPath = NSTemporaryDirectory() + "ygg-cli-\(UUID().uuidString.prefix(6)).sock"
        try server.listen(.unix(path: socketPath))
    }

    override func tearDown() async throws {
        server.stop()
    }

    func testRunsAnActionWithTypedArguments() async throws {
        let result = try await run(["echo.get", "n=21"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    func testBridgesMCPOverTheSocket() async throws {
        let input = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo_get","arguments":{"n":4}}}

        """
        let result = try await run(["mcp"], stdin: input)
        XCTAssertEqual(result.code, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "no reply to the notification")
        XCTAssertTrue(lines[0].contains(#""name":"yggdrasil""#), lines[0])
        XCTAssertTrue(lines[1].contains(#""text":"8""#), lines[1])
    }

    func testAnOversizedMessageIsAnsweredAndTheRelayGoesOn() async throws {
        // The app refuses it before reading it all and closes; writing the
        // rest mustn't kill yggctl with SIGPIPE.
        let big = String(repeating: "x", count: 1_200_000)
        let input = """
        {"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"\(big)"}}
        {"jsonrpc":"2.0","id":2,"method":"ping"}

        """
        let result = try await run(["mcp"], stdin: input)
        XCTAssertEqual(result.code, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, result.stdout)
        XCTAssertTrue(lines.first?.contains(#""id":1"#) ?? false)
        XCTAssertTrue(lines.last?.contains(#""result""#) ?? false)
    }

    func testAWrongKeyReachesTheMCPClientAsAnError() async throws {
        let input = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
        let result = try await run(["mcp"], key: "ygg_wrong", stdin: input)
        XCTAssertTrue(result.stdout.contains(#""id":1"#), result.stdout)
        XCTAssertTrue(result.stdout.contains("A valid API key is required."), result.stdout)
    }

    func testAWrongKeyExitsWith4() async throws {
        let result = try await run(["echo.get", "n=1"], key: "ygg_wrong")
        XCTAssertEqual(result.code, 4)
    }

    func testNoAppExitsWith3() async throws {
        let result = try await run(["echo.get", "n=1"], socket: socketPath + ".missing")
        XCTAssertEqual(result.code, 3)
    }

    private struct Outcome {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    private func run(
        _ arguments: [String], key: String? = nil, socket: String? = nil, stdin: String? = nil
    ) async throws -> Outcome {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/yggctl")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path), "yggctl is bundled")
        let environment = ["YGGDRASIL_API_KEY": key ?? self.key, "YGGDRASIL_SOCKET": socket ?? socketPath!]
        return try await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = environment
            let out = Pipe(), err = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
            try input.fileHandleForWriting.close()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Outcome(
                code: process.terminationStatus,
                stdout: String(bytes: stdout, encoding: .utf8) ?? "",
                stderr: String(bytes: stderr, encoding: .utf8) ?? ""
            )
        }.value
    }
}
