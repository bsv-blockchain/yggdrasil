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
    private var cached: String?

    init(gh: GHCLIAuth) {
        self.gh = gh
    }

    func currentToken() async throws -> String {
        if let cached {
            return cached
        }
        let token = try await gh.currentToken()
        cached = token
        return token
    }

    func invalidate() {
        cached = nil
    }
}
