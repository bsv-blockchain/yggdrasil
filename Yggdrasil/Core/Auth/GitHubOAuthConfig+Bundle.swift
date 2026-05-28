import Foundation

extension GitHubOAuthConfig {
    /// Scopes requested for the in-app GitHub login. `repo` + `read:org` match
    /// what the REST/GraphQL sync needs (assigned issues, review-requested PRs).
    static let defaultScopes = ["repo", "read:org"]

    /// Custom-scheme redirect the app registers in `CFBundleURLTypes`.
    static let defaultRedirectURI = "yggdrasil://oauth-callback"

    /// Build the config from the registered OAuth App credentials.
    ///
    /// Credentials resolve in order: environment variables (handy for local dev
    /// — `YGGDRASIL_GH_OAUTH_CLIENT_ID` / `..._CLIENT_SECRET`), then the
    /// `GitHubOAuthClientID` / `GitHubOAuthClientSecret` Info.plist keys
    /// (injected at release build time). Empty when neither is set, which leaves
    /// `isConfigured == false` and the Sign-in button disabled.
    static func fromBundle(_ bundle: Bundle = .main,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> GitHubOAuthConfig {
        let info = bundle.infoDictionary ?? [:]
        let clientID = environment["YGGDRASIL_GH_OAUTH_CLIENT_ID"]
            ?? (info["GitHubOAuthClientID"] as? String)
            ?? ""
        let clientSecret = environment["YGGDRASIL_GH_OAUTH_CLIENT_SECRET"]
            ?? (info["GitHubOAuthClientSecret"] as? String)
            ?? ""
        return GitHubOAuthConfig(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: defaultScopes,
            redirectURI: defaultRedirectURI
        )
    }
}

/// Generates the opaque `state` value guarding the OAuth round-trip against CSRF.
enum OAuthState {
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        // URL-safe base64 without padding.
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
