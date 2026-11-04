import XCTest
@testable import Yggdrasil

final class RemoteSessionControlTests: XCTestCase {
    private let host = RemoteHost(id: 1, name: "devbox", sshTarget: "me@devbox", reposRoot: "/src", createdAt: Date())

    private func ok(_ stdout: String = "") -> SubprocessResult {
        SubprocessResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    func testKillRunsHelperKillOverBatchSSH() async throws {
        let runner = StubSubprocessRunner(responses: [ok()])
        try await RemoteSessionControl(runner: runner).kill(host: host, tabID: 42)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(calls[0].arguments.suffix(3).prefix(2)), ["--", "me@devbox"])
        XCTAssertEqual(remote(calls[0]), "~/.yggdrasil/bin/ygg kill 42")
        XCTAssertTrue(calls[0].arguments.contains("BatchMode=yes"))
    }

    func testKillSurfacesSSHFailure() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "Connection refused", exitCode: 255)
        ])
        do {
            try await RemoteSessionControl(runner: runner).kill(host: host, tabID: 1)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? RemoteSessionControl.Failure, .ssh(exitCode: 255, stderr: "Connection refused"))
        }
    }

    private func remote(_ call: StubRunCall) -> String? {
        SSHCommand.decodePosixRemote(call.arguments.last ?? "")
    }

    func testPreflightWithCurrentHelperOnlyRunsCheck() async throws {
        let runner = StubSubprocessRunner(responses: [ok("\(RemoteHelper.version)\n"), ok("")])
        let report = try await RemoteSessionControl(runner: runner).preflight(host: host)
        XCTAssertEqual(report, HostPreflightReport(missingTools: [], helperInstalled: false))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.compactMap(remote), [
            "~/.yggdrasil/bin/ygg version 2>/dev/null || echo 0",
            "~/.yggdrasil/bin/ygg check"
        ])
    }

    func testPreflightInstallsOutdatedHelperThenReportsMissingTools() async throws {
        let runner = StubSubprocessRunner(responses: [ok("0\n"), ok(), ok("missing:dtach\nmissing:gh\n")])
        let report = try await RemoteSessionControl(runner: runner).preflight(host: host)
        XCTAssertEqual(report, HostPreflightReport(missingTools: ["dtach", "gh"], helperInstalled: true))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(remote(calls[1]), RemoteHelper.installCommand)
    }

    func testReportIsReadyOnlyWithoutMissingTools() {
        XCTAssertTrue(HostPreflightReport(missingTools: [], helperInstalled: true).isReady)
        XCTAssertFalse(HostPreflightReport(missingTools: ["dtach"], helperInstalled: false).isReady)
    }
}
