@testable import Yggdrasil
import XCTest

/// In-memory token store for AuthService tests.
final class MemoryOAuthTokenStore: OAuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) { self.token = token }

    func readToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func writeToken(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        token = value
    }

    func clearToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

final class OAuthTokenStoreTests: XCTestCase {
    /// AuthService returns a stored OAuth token and never shells out to gh.
    func testOAuthTokenPreferredOverGhCLI() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FROM_GH\n", stderr: "", exitCode: 0)
        ])
        let store = MemoryOAuthTokenStore(token: "gho_OAUTH")
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"), oauthStore: store)

        let token = try await service.currentToken()

        XCTAssertEqual(token, "gho_OAUTH")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 0, "gh must not be invoked when an OAuth token exists")
    }

    /// With no stored OAuth token, AuthService falls back to gh.
    func testFallsBackToGhWhenNoOAuthToken() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FROM_GH\n", stderr: "", exitCode: 0)
        ])
        let store = MemoryOAuthTokenStore(token: nil)
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"), oauthStore: store)

        let token = try await service.currentToken()

        XCTAssertEqual(token, "ghp_FROM_GH")
    }

    /// setOAuthToken persists the token and serves it on the next read.
    func testSetOAuthTokenPersistsAndServes() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FROM_GH\n", stderr: "", exitCode: 0)
        ])
        let store = MemoryOAuthTokenStore(token: nil)
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"), oauthStore: store)

        await service.setOAuthToken("gho_NEW")
        let token = try await service.currentToken()

        XCTAssertEqual(token, "gho_NEW")
        XCTAssertEqual(store.readToken(), "gho_NEW", "token must be persisted to the store")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 0)
    }

    /// signOut clears the stored token and in-memory cache; next read falls back to gh.
    func testSignOutClearsTokenAndFallsBackToGh() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_FROM_GH\n", stderr: "", exitCode: 0)
        ])
        let store = MemoryOAuthTokenStore(token: "gho_OAUTH")
        let service = AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"), oauthStore: store)

        _ = try await service.currentToken() // caches gho_OAUTH
        await service.signOut()
        let token = try await service.currentToken()

        XCTAssertNil(store.readToken(), "store must be cleared on sign out")
        XCTAssertEqual(token, "ghp_FROM_GH")
    }

    /// The SettingsStore-backed store round-trips a token through the real DB layer.
    func testSettingsBackedStoreRoundTrips() throws {
        let db = try YggdrasilDatabase.inMemory()
        let store = SettingsOAuthTokenStore(settings: SettingsStore(database: db))

        XCTAssertNil(store.readToken())
        try store.writeToken("gho_PERSISTED")
        XCTAssertEqual(store.readToken(), "gho_PERSISTED")
        try store.clearToken()
        XCTAssertNil(store.readToken())
    }
}
