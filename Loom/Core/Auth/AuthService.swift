import Foundation

/// Single source of truth for the live GitHub auth token.
///
/// - On construction, hydrates from `KeychainStore`.
/// - On first `currentToken()` call when nothing is cached, invokes `gh auth token`.
/// - On `invalidate()` (e.g. HTTP client saw a 401), drops both caches.
actor AuthService {
    /// Keychain key under which the token lives. Single key — we never juggle multiple.
    static let tokenKey = "github_token"

    private let gh: GHCLIAuth
    private let keychain: KeychainStore
    private var cached: String?

    init(gh: GHCLIAuth, keychain: KeychainStore) {
        self.gh = gh
        self.keychain = keychain
        self.cached = keychain.read(Self.tokenKey)
    }

    func currentToken() async throws -> String {
        if let cached {
            return cached
        }
        let token = try await gh.currentToken()
        try? keychain.write(token, forKey: Self.tokenKey)
        cached = token
        return token
    }

    func invalidate() {
        cached = nil
        try? keychain.delete(Self.tokenKey)
    }
}
