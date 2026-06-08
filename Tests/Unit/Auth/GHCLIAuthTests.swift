import XCTest
@testable import Yggdrasil

/// Captures the recorded invocation passed into a stub `SubprocessRunner`.
struct StubRunCall: Equatable {
    let executable: String
    let arguments: [String]
}

actor StubSubprocessRunner: SubprocessRunner {
    private(set) var calls: [StubRunCall] = []
    private var responses: [SubprocessResult]

    init(responses: [SubprocessResult]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String]) async throws -> SubprocessResult {
        calls.append(StubRunCall(executable: executable, arguments: arguments))
        guard !responses.isEmpty else {
            throw NSError(domain: "StubSubprocessRunner", code: -1)
        }
        return responses.removeFirst()
    }

    func recordedCalls() async -> [StubRunCall] {
        calls
    }
}

final class GHCLIAuthTests: XCTestCase {
    func testReturnsTrimmedTokenFromStdout() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_TOKENVALUE\n", stderr: "", exitCode: 0)
        ])
        let auth = GHCLIAuth(runner: runner, ghExecutable: "/usr/local/bin/gh")
        let token = try await auth.currentToken()
        XCTAssertEqual(token, "ghp_TOKENVALUE")
    }

    func testInvokesGhWithAuthTokenArguments() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "abc\n", stderr: "", exitCode: 0)
        ])
        let auth = GHCLIAuth(runner: runner, ghExecutable: "/opt/homebrew/bin/gh")
        _ = try await auth.currentToken()
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/opt/homebrew/bin/gh")
        XCTAssertEqual(calls[0].arguments, ["auth", "token"])
    }

    func testThrowsNotAuthenticatedOnNonZeroExit() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "you are not logged in", exitCode: 1)
        ])
        let auth = GHCLIAuth(runner: runner, ghExecutable: "/usr/local/bin/gh")
        do {
            _ = try await auth.currentToken()
            XCTFail("expected to throw")
        } catch GHCLIAuthError.notAuthenticated {
            // expected
        } catch {
            XCTFail("expected .notAuthenticated, got \(error)")
        }
    }

    func testThrowsUnexpectedWhenStdoutEmpty() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "   \n", stderr: "", exitCode: 0)
        ])
        let auth = GHCLIAuth(runner: runner, ghExecutable: "/usr/local/bin/gh")
        do {
            _ = try await auth.currentToken()
            XCTFail("expected to throw")
        } catch GHCLIAuthError.unexpected {
            // expected
        } catch {
            XCTFail("expected .unexpected, got \(error)")
        }
    }
}
