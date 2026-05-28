@testable import Yggdrasil
import XCTest

/// Pure-logic tests for the GitHub OAuth model: authorize-URL construction,
/// callback parsing, and token-response decoding. No network, no UI.
final class GitHubOAuthTests: XCTestCase {
    private func makeConfig() -> GitHubOAuthConfig {
        GitHubOAuthConfig(
            clientID: "Iv1_test123",
            clientSecret: "secret_abc",
            scopes: ["repo", "read:org"],
            redirectURI: "yggdrasil://oauth-callback"
        )
    }

    // MARK: authorize URL

    func testAuthorizeURLCarriesClientIDScopesStateAndRedirect() throws {
        let url = makeConfig().authorizeURL(state: "STATE_42")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(comps.host, "github.com")
        XCTAssertEqual(comps.path, "/login/oauth/authorize")

        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["client_id"], "Iv1_test123")
        XCTAssertEqual(items["redirect_uri"], "yggdrasil://oauth-callback")
        XCTAssertEqual(items["scope"], "repo read:org")
        XCTAssertEqual(items["state"], "STATE_42")
    }

    func testAuthorizeURLPercentEncodesScopeSeparator() throws {
        let url = makeConfig().authorizeURL(state: "S")
        // The space joining scopes must be encoded — never a raw space in the URL.
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.contains("scope=repo%20read:org"))
    }

    // MARK: callback parsing

    func testParseCallbackReturnsCodeWhenStateMatches() throws {
        let url = URL(string: "yggdrasil://oauth-callback?code=abc123&state=STATE_42")!
        let code = try OAuthCallback.parse(url: url, expectedState: "STATE_42")
        XCTAssertEqual(code, "abc123")
    }

    func testParseCallbackThrowsOnStateMismatch() {
        let url = URL(string: "yggdrasil://oauth-callback?code=abc123&state=WRONG")!
        XCTAssertThrowsError(try OAuthCallback.parse(url: url, expectedState: "STATE_42")) { error in
            XCTAssertEqual(error as? OAuthError, .stateMismatch)
        }
    }

    func testParseCallbackThrowsWhenCodeMissing() {
        let url = URL(string: "yggdrasil://oauth-callback?state=STATE_42")!
        XCTAssertThrowsError(try OAuthCallback.parse(url: url, expectedState: "STATE_42")) { error in
            XCTAssertEqual(error as? OAuthError, .missingCode)
        }
    }

    func testParseCallbackSurfacesProviderErrorParam() {
        let url = URL(string: "yggdrasil://oauth-callback?error=access_denied&error_description=The+user+denied&state=STATE_42")!
        XCTAssertThrowsError(try OAuthCallback.parse(url: url, expectedState: "STATE_42")) { error in
            XCTAssertEqual(error as? OAuthError, .providerError("access_denied: The user denied"))
        }
    }

    // MARK: token response decoding

    func testDecodeTokenResponseSuccess() throws {
        let json = Data(#"{"access_token":"gho_TOKEN","token_type":"bearer","scope":"repo,read:org"}"#.utf8)
        let resp = try GitHubOAuthResponseDecoder.decode(json)
        guard case let .success(token) = resp else {
            return XCTFail("expected success, got \(resp)")
        }
        XCTAssertEqual(token, "gho_TOKEN")
    }

    func testDecodeTokenResponseProviderError() throws {
        let json = Data(#"{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}"#.utf8)
        let resp = try GitHubOAuthResponseDecoder.decode(json)
        guard case let .failure(message) = resp else {
            return XCTFail("expected failure, got \(resp)")
        }
        XCTAssertEqual(message, "bad_verification_code: The code passed is incorrect or expired.")
    }

    func testDecodeTokenResponseMalformedThrows() {
        let json = Data(#"{"unexpected":true}"#.utf8)
        XCTAssertThrowsError(try GitHubOAuthResponseDecoder.decode(json)) { error in
            XCTAssertEqual(error as? OAuthError, .malformedResponse)
        }
    }
}
