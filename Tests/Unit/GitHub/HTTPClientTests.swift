@testable import Yggdrasil
import XCTest

/// URLProtocol stub: per-host queues of canned responses. Set responses BEFORE the
/// request fires; `start()` returns them in FIFO order.
final class StubURLProtocol: URLProtocol {
    /// Each entry is a canned reply or a thrown error.
    enum Reply {
        case response(status: Int, body: Data, headers: [String: String])
        case error(NSError)
    }

    /// Captured request the test can inspect after the fact.
    struct Recorded {
        let url: URL
        let method: String
        let headers: [String: String]
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var recorded: [Recorded] = []

    static func reset() {
        replies = []
        recorded = []
    }

    // URLProtocol declares these as `class func`, so overrides must also use `class func`.
    // swiftlint:disable static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // swiftlint:enable static_over_final_class

    override func startLoading() {
        let captured = Recorded(
            url: request.url ?? URL(string: "about:blank")!,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:]
        )
        StubURLProtocol.recorded.append(captured)

        guard !StubURLProtocol.replies.isEmpty else {
            let err = NSError(domain: "StubURLProtocol", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "no canned reply"])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }

        switch StubURLProtocol.replies.removeFirst() {
        case let .response(status, body, headers):
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(err):
            client?.urlProtocol(self, didFailWithError: err)
        }
    }

    override func stopLoading() {}
}

private func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeAuthService(token: String = "ghp_TEST") -> AuthService {
    let keychain = InMemoryKeychainStore()
    try? keychain.write(token, forKey: AuthService.tokenKey)
    return AuthService(
        gh: GHCLIAuth(runner: StubSubprocessRunner(responses: []), ghExecutable: "/bin/gh"),
        keychain: keychain
    )
}

final class HTTPClientTests: XCTestCase {
    private var db: YggdrasilDatabase!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        db = try YggdrasilDatabase.inMemory()
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    func testInjectsAuthorizationHeader() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [
            .response(status: 200, body: Data("ok".utf8), headers: [:])
        ]
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: makeAuthService(token: "ghp_AUTH"),
            etags: ETagStore(database: db)
        )
        _ = try await client.get(url: url, accept: "application/vnd.github+json")
        XCTAssertEqual(StubURLProtocol.recorded.first?.headers["Authorization"], "Bearer ghp_AUTH")
    }

    func testSendsAcceptAndUserAgentHeaders() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [.response(status: 200, body: Data(), headers: [:])]
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: makeAuthService(),
            etags: ETagStore(database: db)
        )
        _ = try await client.get(url: url, accept: "application/vnd.github+json")
        let req = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(req.headers["Accept"], "application/vnd.github+json")
        XCTAssertTrue((req.headers["User-Agent"] ?? "").hasPrefix("Yggdrasil/"))
    }

    func testStoresAndResendsEtag() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/issues"))
        StubURLProtocol.replies = [
            .response(status: 200, body: Data("[]".utf8), headers: ["Etag": "W/\"abc\""]),
            .response(status: 304, body: Data(), headers: [:])
        ]
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: makeAuthService(),
            etags: ETagStore(database: db)
        )

        let first = try await client.get(url: url, accept: "application/json")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.etag, "W/\"abc\"")
        XCTAssertNotNil(first.body)
        XCTAssertNil(StubURLProtocol.recorded[0].headers["If-None-Match"],
                     "first request must not have If-None-Match")

        let second = try await client.get(url: url, accept: "application/json")
        XCTAssertEqual(second.status, 304)
        XCTAssertNil(second.body, "304 result body must be nil")
        XCTAssertEqual(StubURLProtocol.recorded[1].headers["If-None-Match"], "W/\"abc\"")
    }

    func testParsesRateLimitRemaining() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [
            .response(status: 200, body: Data("ok".utf8), headers: [
                "X-RateLimit-Remaining": "4321",
                "X-RateLimit-Limit": "5000"
            ])
        ]
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: makeAuthService(),
            etags: ETagStore(database: db)
        )
        let result = try await client.get(url: url, accept: "application/json")
        XCTAssertEqual(result.rateLimitRemaining, 4321)
    }

    func test401TriggersAuthInvalidateAndOneRetry() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [
            .response(status: 401, body: Data("unauthorized".utf8), headers: [:]),
            .response(status: 200, body: Data("ok".utf8), headers: [:])
        ]
        // Auth service starts with a stale token; AND a stub gh that can re-mint one.
        let keychain = InMemoryKeychainStore()
        try keychain.write("ghp_STALE", forKey: AuthService.tokenKey)
        let auth = AuthService(
            gh: GHCLIAuth(
                runner: StubSubprocessRunner(responses: [
                    SubprocessResult(stdout: "ghp_FRESH\n", stderr: "", exitCode: 0)
                ]),
                ghExecutable: "/bin/gh"
            ),
            keychain: keychain
        )
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: auth,
            etags: ETagStore(database: db)
        )

        let result = try await client.get(url: url, accept: "application/json")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2, "expected exactly one retry")
        // First request used the stale token; the retry used the freshly minted one.
        XCTAssertEqual(StubURLProtocol.recorded[0].headers["Authorization"], "Bearer ghp_STALE")
        XCTAssertEqual(StubURLProtocol.recorded[1].headers["Authorization"], "Bearer ghp_FRESH")
    }

    func test401TwiceSurfacesError() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [
            .response(status: 401, body: Data(), headers: [:]),
            .response(status: 401, body: Data(), headers: [:])
        ]
        let keychain = InMemoryKeychainStore()
        try? keychain.write("t", forKey: AuthService.tokenKey)
        let auth = AuthService(
            gh: GHCLIAuth(
                runner: StubSubprocessRunner(responses: [
                    SubprocessResult(stdout: "t2\n", stderr: "", exitCode: 0)
                ]),
                ghExecutable: "/bin/gh"
            ),
            keychain: keychain
        )
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: auth,
            etags: ETagStore(database: db ?? (try? YggdrasilDatabase.inMemory())!)
        )
        do {
            _ = try await client.get(url: url, accept: "application/json")
            XCTFail("expected to throw")
        } catch GitHubError.unauthorized {
            // expected
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
    }

    func testTransportErrorBubblesAsRequestFailed() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/foo"))
        StubURLProtocol.replies = [
            .error(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        ]
        let client = URLSessionHTTPClient(
            session: makeStubbedSession(),
            auth: makeAuthService(),
            etags: ETagStore(database: db ?? (try? YggdrasilDatabase.inMemory())!)
        )
        do {
            _ = try await client.get(url: url, accept: "application/json")
            XCTFail("expected to throw")
        } catch GitHubError.requestFailed {
            // expected
        } catch {
            XCTFail("expected .requestFailed, got \(error)")
        }
    }
}
