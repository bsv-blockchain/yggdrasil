@testable import Yggdrasil
import XCTest

/// Stub presenter that returns a canned callback URL (or throws).
final class StubWebAuthPresenter: WebAuthPresenter, @unchecked Sendable {
    var result: Result<URL, Error>
    private(set) var presentedURL: URL?
    private(set) var callCount = 0

    init(result: Result<URL, Error>) { self.result = result }

    func authenticate(url: URL, callbackScheme _: String) async throws -> URL {
        callCount += 1
        presentedURL = url
        return try result.get()
    }
}

/// Stub exchanger that returns a fixed token and records the code it saw.
final class StubTokenExchanger: TokenExchanger, @unchecked Sendable {
    let token: String
    private(set) var seenCode: String?

    init(token: String) { self.token = token }

    func exchange(code: String, config _: GitHubOAuthConfig) async throws -> String {
        seenCode = code
        return token
    }
}

@MainActor
final class GitHubOAuthLoginServiceTests: XCTestCase {
    private func makeConfig(clientID: String = "Iv1_test") -> GitHubOAuthConfig {
        GitHubOAuthConfig(
            clientID: clientID,
            clientSecret: "secret",
            scopes: ["repo"],
            redirectURI: "yggdrasil://oauth-callback"
        )
    }

    private func makeAuthService(store: OAuthTokenStore) -> AuthService {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "ghp_GH\n", stderr: "", exitCode: 0),
        ])
        return AuthService(gh: GHCLIAuth(runner: runner, ghExecutable: "/bin/gh"), oauthStore: store)
    }

    func testSuccessfulLoginStoresToken() async throws {
        let store = MemoryOAuthTokenStore()
        let auth = makeAuthService(store: store)
        let presenter = StubWebAuthPresenter(
            result: .success(URL(string: "yggdrasil://oauth-callback?code=CODE9&state=FIXED")!)
        )
        let exchanger = StubTokenExchanger(token: "gho_RESULT")
        let service = GitHubOAuthLoginService(
            config: makeConfig(), presenter: presenter, exchanger: exchanger,
            authService: auth, makeState: { "FIXED" }
        )

        try await service.login()

        XCTAssertEqual(store.readToken(), "gho_RESULT")
        XCTAssertEqual(exchanger.seenCode, "CODE9")
        XCTAssertEqual(presenter.presentedURL?.absoluteString.contains("state=FIXED"), true)
    }

    func testLoginThrowsNotConfiguredWhenClientIDMissing() async {
        let store = MemoryOAuthTokenStore()
        let presenter = StubWebAuthPresenter(result: .success(URL(string: "yggdrasil://x")!))
        let service = GitHubOAuthLoginService(
            config: makeConfig(clientID: ""), presenter: presenter,
            exchanger: StubTokenExchanger(token: "x"),
            authService: makeAuthService(store: store), makeState: { "S" }
        )

        do {
            try await service.login()
            XCTFail("expected throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("expected OAuthError.notConfigured, got \(error)")
        }
        XCTAssertEqual(presenter.callCount, 0, "must not present UI when unconfigured")
        XCTAssertNil(store.readToken())
    }

    func testLoginPropagatesUserCancelAndStoresNothing() async {
        let store = MemoryOAuthTokenStore()
        let presenter = StubWebAuthPresenter(result: .failure(OAuthError.userCancelled))
        let service = GitHubOAuthLoginService(
            config: makeConfig(), presenter: presenter,
            exchanger: StubTokenExchanger(token: "x"),
            authService: makeAuthService(store: store), makeState: { "S" }
        )

        do {
            try await service.login()
            XCTFail("expected throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .userCancelled)
        } catch {
            XCTFail("expected OAuthError.userCancelled, got \(error)")
        }
        XCTAssertNil(store.readToken())
    }

    func testLoginThrowsOnStateMismatch() async {
        let store = MemoryOAuthTokenStore()
        let presenter = StubWebAuthPresenter(
            result: .success(URL(string: "yggdrasil://oauth-callback?code=C&state=TAMPERED")!)
        )
        let service = GitHubOAuthLoginService(
            config: makeConfig(), presenter: presenter,
            exchanger: StubTokenExchanger(token: "x"),
            authService: makeAuthService(store: store), makeState: { "EXPECTED" }
        )

        do {
            try await service.login()
            XCTFail("expected throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .stateMismatch)
        } catch {
            XCTFail("expected OAuthError.stateMismatch, got \(error)")
        }
        XCTAssertNil(store.readToken())
    }

    func testLogoutClearsToken() async {
        let store = MemoryOAuthTokenStore(token: "gho_OLD")
        let service = GitHubOAuthLoginService(
            config: makeConfig(), presenter: StubWebAuthPresenter(result: .success(URL(string: "x://y")!)),
            exchanger: StubTokenExchanger(token: "x"),
            authService: makeAuthService(store: store), makeState: { "S" }
        )

        await service.logout()

        XCTAssertNil(store.readToken())
    }
}
