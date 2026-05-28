import Foundation

/// Abstraction over the system auth UI (ASWebAuthenticationSession), so the
/// orchestrator can be tested without presenting a real browser sheet.
/// Implementations present `url`, watch for a redirect to `callbackScheme://`,
/// and return the full callback URL — or throw `OAuthError.userCancelled`.
protocol WebAuthPresenter: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Drives the GitHub OAuth login: generate state → present the system auth
/// sheet (where passkeys work natively) → parse the redirect → exchange the
/// code for a token → persist it via `AuthService`.
@MainActor
final class GitHubOAuthLoginService {
    let config: GitHubOAuthConfig
    let presenter: WebAuthPresenter
    let exchanger: TokenExchanger
    let authService: AuthService
    let makeState: () -> String

    init(config: GitHubOAuthConfig, presenter: WebAuthPresenter, exchanger: TokenExchanger,
         authService: AuthService, makeState: @escaping () -> String) {
        self.config = config
        self.presenter = presenter
        self.exchanger = exchanger
        self.authService = authService
        self.makeState = makeState
    }

    /// Run the full login flow. On success the token is stored in `AuthService`.
    func login() async throws {
        guard config.isConfigured else { throw OAuthError.notConfigured }
        let state = makeState()
        let authorizeURL = config.authorizeURL(state: state)
        let callbackURL = try await presenter.authenticate(
            url: authorizeURL, callbackScheme: config.callbackScheme
        )
        let code = try OAuthCallback.parse(url: callbackURL, expectedState: state)
        let token = try await exchanger.exchange(code: code, config: config)
        await authService.setOAuthToken(token)
        YggdrasilLog.auth.info("GitHub OAuth login succeeded; token stored")
    }

    /// Forget the OAuth token; subsequent API calls fall back to the gh CLI.
    func logout() async {
        await authService.signOut()
        YggdrasilLog.auth.info("Signed out of GitHub OAuth; cleared stored token")
    }
}
