/// Persistent store for the GitHub OAuth access token obtained via the
/// ASWebAuthenticationSession login flow. Abstracted so `AuthService` and tests
/// don't depend on a concrete backend.
protocol OAuthTokenStore: Sendable {
    func readToken() -> String?
    func writeToken(_ token: String) throws
    func clearToken() throws
}

/// Backs the OAuth token with the GRDB `setting` key-value table.
///
/// We deliberately reuse the settings table rather than the macOS Keychain:
/// ad-hoc-signed local builds get a fresh keychain ACL on every rebuild, which
/// pops a password prompt on each relaunch (see `AuthService`'s rationale and
/// `decisions.md`). The token already lives in plaintext in `gh`'s `hosts.yml`,
/// so storing it alongside other app settings is a consistent trade for a
/// developer tool with the sandbox disabled.
struct SettingsOAuthTokenStore: OAuthTokenStore {
    static let settingKey = "github_oauth_token"
    let settings: SettingsStore

    func readToken() -> String? {
        let value = try? settings.get(forKey: Self.settingKey)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func writeToken(_ token: String) throws {
        try settings.set(token, forKey: Self.settingKey)
    }

    func clearToken() throws {
        // Empty string reads back as "no token" (see readToken); avoids needing a delete API.
        try settings.set("", forKey: Self.settingKey)
    }
}
