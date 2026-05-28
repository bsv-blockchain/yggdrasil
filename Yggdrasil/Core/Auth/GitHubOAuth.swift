import Foundation

/// Errors surfaced by the GitHub OAuth login flow.
enum OAuthError: Error, Equatable {
    /// User dismissed the system auth sheet.
    case userCancelled
    /// Callback `state` didn't match the value we generated — possible CSRF / stale sheet.
    case stateMismatch
    /// Callback carried no `code` and no `error`.
    case missingCode
    /// GitHub returned an OAuth error (authorize callback or token exchange). Carries `error: description`.
    case providerError(String)
    /// Response body wasn't the JSON we expected.
    case malformedResponse
    /// No client id/secret configured — login can't start.
    case notConfigured
}

/// Static configuration for the GitHub OAuth App used to log in.
///
/// `clientID`/`clientSecret` come from the registered OAuth App (see RELEASE.md).
/// GitHub OAuth Apps don't support PKCE, so the token exchange needs the secret;
/// for a distributed desktop client the secret is not truly confidential, which
/// is an accepted property of the OAuth-App flow for native apps.
struct GitHubOAuthConfig: Sendable, Equatable {
    var clientID: String
    var clientSecret: String
    var scopes: [String]
    var redirectURI: String
    var authorizeEndpoint: URL = URL(string: "https://github.com/login/oauth/authorize")!
    var tokenEndpoint: URL = URL(string: "https://github.com/login/oauth/access_token")!

    /// Custom-scheme prefix ASWebAuthenticationSession watches for (the part before `://`).
    var callbackScheme: String {
        URLComponents(string: redirectURI)?.scheme ?? ""
    }

    /// Whether enough is configured to start a login.
    var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }

    /// Build the `/login/oauth/authorize` URL for a freshly generated `state`.
    func authorizeURL(state: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        // URLComponents encodes a space in a query value as "+"; GitHub accepts both,
        // but we normalise to "%20" so the scope separator is unambiguous.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        return comps.url!
    }

    /// Form-encoded (`application/x-www-form-urlencoded`) body for
    /// `POST /login/oauth/access_token`. Every value is percent-encoded to the
    /// unreserved set so reserved characters (`:`/`/`/`+`) survive transport.
    func tokenExchangeBody(code: String) -> Data {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let params = [
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
        ]
        let pairs = params.map { name, value -> String in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return "\(name)=\(encoded)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// Parses the redirect-callback URL handed back by ASWebAuthenticationSession.
enum OAuthCallback {
    /// Returns the authorization `code` when `state` matches, else throws an `OAuthError`.
    static func parse(url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        if let error = values["error"], !error.isEmpty {
            let description = values["error_description"]?.replacingOccurrences(of: "+", with: " ")
            throw OAuthError.providerError(description.map { "\(error): \($0)" } ?? error)
        }
        guard values["state"] == expectedState else {
            throw OAuthError.stateMismatch
        }
        guard let code = values["code"], !code.isEmpty else {
            throw OAuthError.missingCode
        }
        return code
    }
}

/// Outcome of decoding a GitHub token-exchange response body.
enum GitHubOAuthResult: Equatable {
    case success(token: String)
    case failure(message: String)
}

/// Decodes the JSON returned by `POST /login/oauth/access_token`.
enum GitHubOAuthResponseDecoder {
    private struct SuccessBody: Decodable {
        let access_token: String
    }

    private struct ErrorBody: Decodable {
        let error: String
        let error_description: String?
    }

    static func decode(_ data: Data) throws -> GitHubOAuthResult {
        let decoder = JSONDecoder()
        if let ok = try? decoder.decode(SuccessBody.self, from: data), !ok.access_token.isEmpty {
            return .success(token: ok.access_token)
        }
        if let err = try? decoder.decode(ErrorBody.self, from: data) {
            let message = err.error_description.map { "\(err.error): \($0)" } ?? err.error
            return .failure(message: message)
        }
        throw OAuthError.malformedResponse
    }
}
