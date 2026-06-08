import XCTest
@testable import Yggdrasil

final class AuthServiceTests: XCTestCase {
    /// First call shells out to `gh auth token` and caches the result.
    func testFirstCallReadsFromGhAndCaches() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FIRST\n", stderr: "", exitCode: 0)
        ])
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"))

        let token = try await service.currentToken()

        XCTAssertEqual(token, "ghp_FIRST")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1, "gh should be invoked exactly once on the first call")
    }

    /// Second call uses the in-memory cache — no further gh invocations.
    func testSecondCallReusesMemoryCacheAndDoesNotInvokeGh() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_CACHEME\n", stderr: "", exitCode: 0)
        ])
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"))

        _ = try await service.currentToken()
        let second = try await service.currentToken()

        XCTAssertEqual(second, "ghp_CACHEME")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1, "memory cache should prevent a second gh invocation")
    }

    /// `invalidate()` drops the cache; next `currentToken()` re-shells.
    func testInvalidateForcesGhRefresh() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FIRST\n", stderr: "", exitCode: 0),
            SubprocessResult(stdout: "ghp_SECOND\n", stderr: "", exitCode: 0)
        ])
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"))

        let first = try await service.currentToken()
        await service.invalidate()
        let second = try await service.currentToken()

        XCTAssertEqual(first, "ghp_FIRST")
        XCTAssertEqual(second, "ghp_SECOND")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
    }

    /// Propagates GHCLIAuthError when gh isn't authenticated.
    func testPropagatesNotAuthenticatedFromGh() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "no login", exitCode: 1)
        ])
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"))

        do {
            _ = try await service.currentToken()
            XCTFail("expected to throw")
        } catch GHCLIAuthError.notAuthenticated {
            // expected
        } catch {
            XCTFail("expected .notAuthenticated, got \(error)")
        }
    }
}
