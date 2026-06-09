import XCTest
@testable import Yggdrasil

/// Verifies the clone path shells out to `gh repo clone <owner>/<name> <dir>`
/// (so private repos authenticate via gh) and surfaces gh's stderr on failure.
final class GitHubClonerTests: XCTestCase {
    func testInvokesGhRepoCloneWithSlugAndTarget() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "", exitCode: 0)
        ])
        let cloner = GitHubCloner(runner: runner, ghExecutable: "/opt/homebrew/bin/gh")

        try await cloner.clone(owner: "bsv-blockchain", name: "teranode", to: "/tmp/teranode")

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/opt/homebrew/bin/gh")
        XCTAssertEqual(calls[0].arguments, ["repo", "clone", "bsv-blockchain/teranode", "/tmp/teranode"])
    }

    func testThrowsCloneFailedWithStderrOnNonZeroExit() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "could not resolve host", exitCode: 1)
        ])
        let cloner = GitHubCloner(runner: runner, ghExecutable: "/opt/homebrew/bin/gh")

        do {
            try await cloner.clone(owner: "o", name: "r", to: "/tmp/r")
            XCTFail("expected to throw")
        } catch let GitHubClonerError.cloneFailed(stderr, exitCode) {
            XCTAssertEqual(stderr, "could not resolve host")
            XCTAssertEqual(exitCode, 1)
        } catch {
            XCTFail("expected cloneFailed, got \(error)")
        }
    }
}
