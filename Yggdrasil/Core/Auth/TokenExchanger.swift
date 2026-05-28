import Foundation

/// Exchanges an OAuth authorization `code` for an access token.
protocol TokenExchanger: Sendable {
    func exchange(code: String, config: GitHubOAuthConfig) async throws -> String
}

/// Production exchanger: a bare `URLSession` POST to GitHub's token endpoint.
///
/// Deliberately NOT routed through `URLSessionHTTPClient` — that client injects
/// a `Bearer` token from `AuthService` on every request, which is wrong (and
/// circular) for the unauthenticated token-exchange call.
struct URLSessionTokenExchanger: TokenExchanger {
    let session: URLSession

    func exchange(code: String, config: GitHubOAuthConfig) async throws -> String {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = config.tokenExchangeBody(code: code)

        let (data, _) = try await session.data(for: request)
        switch try GitHubOAuthResponseDecoder.decode(data) {
        case let .success(token):
            return token
        case let .failure(message):
            throw OAuthError.providerError(message)
        }
    }
}
