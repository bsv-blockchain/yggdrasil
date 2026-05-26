@testable import Loom
import XCTest

/// In-memory KeychainStore for tests — no real Keychain access.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func write(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
    }

    func delete(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    var contents: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return store
    }
}

final class AuthServiceTests: XCTestCase {
    /// First call falls through to `gh auth token`, stores in keychain, returns token.
    func testFirstCallReadsFromGhAndCachesInKeychain() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FIRST\n", stderr: "", exitCode: 0)
        ])
        let keychain = InMemoryKeychainStore()
        let service = AuthService(
            gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"),
            keychain: keychain
        )

        let token = try await service.currentToken()

        XCTAssertEqual(token, "ghp_FIRST")
        XCTAssertEqual(keychain.read(AuthService.tokenKey), "ghp_FIRST")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1, "gh should be invoked exactly once on the first call")
    }

    /// Second call uses cached memory token — no further gh invocations.
    func testSecondCallReusesMemoryCacheAndDoesNotInvokeGh() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_CACHEME\n", stderr: "", exitCode: 0)
        ])
        let keychain = InMemoryKeychainStore()
        let service = AuthService(
            gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"),
            keychain: keychain
        )

        _ = try await service.currentToken()
        let second = try await service.currentToken()

        XCTAssertEqual(second, "ghp_CACHEME")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1, "memory cache should prevent a second gh invocation")
    }

    /// Restart scenario: keychain has a token at construction → service uses it without calling gh.
    func testHydratesFromKeychainAtConstruction() async throws {
        let runner = StubSubprocessRunner(responses: [])
        let keychain = InMemoryKeychainStore()
        try keychain.write("ghp_FROMKEYCHAIN", forKey: AuthService.tokenKey)

        let service = AuthService(
            gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"),
            keychain: keychain
        )
        let token = try await service.currentToken()
        XCTAssertEqual(token, "ghp_FROMKEYCHAIN")
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.isEmpty, "should not invoke gh when keychain already has a token")
    }

    /// `invalidate()` drops memory + keychain; next `currentToken()` re-reads from gh.
    func testInvalidateForcesGhRefresh() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FIRST\n", stderr: "", exitCode: 0),
            SubprocessResult(stdout: "ghp_SECOND\n", stderr: "", exitCode: 0)
        ])
        let keychain = InMemoryKeychainStore()
        let service = AuthService(
            gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"),
            keychain: keychain
        )

        let first = try await service.currentToken()
        await service.invalidate()
        XCTAssertNil(keychain.read(AuthService.tokenKey))

        let second = try await service.currentToken()
        XCTAssertEqual(first, "ghp_FIRST")
        XCTAssertEqual(second, "ghp_SECOND")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
    }

    /// Propagates GHCLIAuthError when gh isn't authenticated and there's nothing in keychain.
    func testPropagatesNotAuthenticatedFromGh() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "no login", exitCode: 1)
        ])
        let keychain = InMemoryKeychainStore()
        let service = AuthService(
            gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"),
            keychain: keychain
        )

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
