@testable import Yggdrasil
import XCTest

final class TokenExchangerTests: XCTestCase {
    private func makeConfig() -> GitHubOAuthConfig {
        GitHubOAuthConfig(
            clientID: "Iv1_test123",
            clientSecret: "secret_abc",
            scopes: ["repo"],
            redirectURI: "yggdrasil://oauth-callback"
        )
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: pure body builder

    func testTokenExchangeBodyIsFormEncodedWithAllParams() throws {
        let body = makeConfig().tokenExchangeBody(code: "the+code")
        let string = String(data: body, encoding: .utf8) ?? ""
        let pairs = Dictionary(uniqueKeysWithValues: string.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "")
        })

        XCTAssertEqual(pairs["client_id"], "Iv1_test123")
        XCTAssertEqual(pairs["client_secret"], "secret_abc")
        XCTAssertEqual(pairs["redirect_uri"], "yggdrasil%3A%2F%2Foauth-callback")
        // "+" in the code must be percent-encoded, not left as a literal "+".
        XCTAssertEqual(pairs["code"], "the%2Bcode")
    }

    // MARK: exchange over URLSession

    func testExchangeReturnsTokenAndPostsToTokenEndpoint() async throws {
        StubURLProtocol.replies = [
            .response(status: 200,
                      body: Data(#"{"access_token":"gho_LIVE","token_type":"bearer"}"#.utf8),
                      headers: ["Content-Type": "application/json"]),
        ]
        let exchanger = URLSessionTokenExchanger(session: makeStubbedSession())

        let token = try await exchanger.exchange(code: "abc", config: makeConfig())

        XCTAssertEqual(token, "gho_LIVE")
        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.url.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(recorded.headers["Accept"], "application/json")
    }

    func testExchangeThrowsProviderErrorOnBadCode() async {
        StubURLProtocol.replies = [
            .response(status: 200,
                      body: Data(#"{"error":"bad_verification_code","error_description":"expired"}"#.utf8),
                      headers: [:]),
        ]
        let exchanger = URLSessionTokenExchanger(session: makeStubbedSession())

        do {
            _ = try await exchanger.exchange(code: "abc", config: makeConfig())
            XCTFail("expected throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .providerError("bad_verification_code: expired"))
        } catch {
            XCTFail("expected OAuthError, got \(error)")
        }
    }

    func testExchangeThrowsMalformedOnGarbage() async {
        StubURLProtocol.replies = [
            .response(status: 200, body: Data(#"{"nope":1}"#.utf8), headers: [:]),
        ]
        let exchanger = URLSessionTokenExchanger(session: makeStubbedSession())

        do {
            _ = try await exchanger.exchange(code: "abc", config: makeConfig())
            XCTFail("expected throw")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("expected OAuthError, got \(error)")
        }
    }
}
