import Foundation

/// Single source of truth for the live GitHub auth token.
///
/// The canonical store is whatever `gh auth token` reports — gh CLI manages
/// the auth lifecycle (login, refresh, scopes) and stashes the token in
/// `~/.config/gh/hosts.yml`. We treat that file as the source of truth and
/// shell out exactly once per launch on the first request, then cache the
/// result in memory for the rest of the process lifetime. `invalidate()`
/// (called when the HTTP client sees a 401) drops the in-memory cache so
/// the next request re-shells.
///
/// We deliberately do NOT mirror the token into the macOS Keychain. With
/// ad-hoc-signed local builds the keychain ACL doesn't recognise the same
/// app across rebuilds, so every relaunch popped a password prompt. The
/// in-memory cache plus a ~30ms `gh auth token` shell-out at startup is a
/// fine trade.
actor AuthService {
    private let gh: GHCLIAuth
    private let oauthStore: OAuthTokenStore?
    private var cached: String?

    init(gh: GHCLIAuth, oauthStore: OAuthTokenStore? = nil) {
        self.gh = gh
        self.oauthStore = oauthStore
    }

    func currentToken() async throws -> String {
        if let cached {
            return cached
        }
        // An OAuth token from the in-app login flow takes precedence over the
        // gh CLI. Only when none is stored do we shell out to `gh auth token`.
        if let oauth = oauthStore?.readToken(), !oauth.isEmpty {
            cached = oauth
            return oauth
        }
        let token = try await gh.currentToken()
        cached = token
        return token
    }

    func invalidate() {
        cached = nil
    }

    /// Record a freshly obtained OAuth token: persist it and prime the cache.
    func setOAuthToken(_ token: String) {
        try? oauthStore?.writeToken(token)
        cached = token
    }

    /// Forget the OAuth token (store + cache). The next `currentToken()` falls
    /// back to the gh CLI.
    func signOut() {
        try? oauthStore?.clearToken()
        cached = nil
    }
}
