import XCTest
@testable import Yggdrasil

final class SSHSubprocessRunnerTests: XCTestCase {
    private let host = RemoteHost(id: 1, name: "devbox", sshTarget: "me@devbox", reposRoot: "/src", createdAt: Date())

    func testRunsCommandThroughHelperOverBatchSSH() async throws {
        let stub = StubSubprocessRunner(responses: [SubprocessResult(stdout: "ok\n", stderr: "", exitCode: 0)])
        let result = try await SSHSubprocessRunner(host: host, transport: stub)
            .run(executable: "git", arguments: ["-C", "/src/o/r", "log", "--format=%s it's"])
        XCTAssertEqual(result.stdout, "ok\n")
        let calls = await stub.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/ssh")
        XCTAssertTrue(calls[0].arguments.contains("BatchMode=yes"))
        XCTAssertEqual(
            SSHCommand.decodePosixRemote(calls[0].arguments.last ?? ""),
            "~/.yggdrasil/bin/ygg run -- 'git' '-C' '/src/o/r' 'log' '--format=%s it'\\''s'"
        )
    }

    func testPassesExitCodeAndStderrThrough() async throws {
        let stub = StubSubprocessRunner(responses: [SubprocessResult(stdout: "", stderr: "fatal: x", exitCode: 128)])
        let result = try await SSHSubprocessRunner(host: host, transport: stub).run(executable: "git", arguments: [])
        XCTAssertEqual(result.exitCode, 128)
        XCTAssertEqual(result.stderr, "fatal: x")
    }
}
