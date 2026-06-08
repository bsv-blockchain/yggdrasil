import Foundation
import XCTest
@testable import Yggdrasil

/// Test-only `HTTPClient` impl that returns canned bodies / statuses.
final class CannedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResult]
    private(set) var calledURLs: [URL] = []

    init(responses: [HTTPResult]) {
        self.responses = responses
    }

    func get(url: URL, accept _: String) async throws -> HTTPResult {
        lock.lock()
        defer { lock.unlock() }
        calledURLs.append(url)
        // Built-in canned response for the review-requested search endpoint:
        // TaskSyncService calls /search/issues unconditionally now, and most
        // existing tests don't care about the review path, so default it to
        // "no PRs to review" instead of consuming a queued response. Tests
        // that DO want to assert review behavior should override by enqueuing
        // a body and matching the assertion accordingly.
        if url.path.contains("/search/issues") {
            return HTTPResult(
                status: 200,
                body: Data("{\"items\":[]}".utf8),
                etag: nil,
                rateLimitRemaining: nil
            )
        }
        guard !responses.isEmpty else {
            throw GitHubError.requestFailed(.badServerResponse)
        }
        return responses.removeFirst()
    }

    func post(url: URL, body _: Data, accept _: String) async throws -> HTTPResult {
        lock.lock()
        defer { lock.unlock() }
        calledURLs.append(url)
        guard !responses.isEmpty else {
            throw GitHubError.requestFailed(.badServerResponse)
        }
        return responses.removeFirst()
    }
}

/// Utility for loading bundled JSON fixtures. The Fixtures directory is bundled
/// as a folder-reference resource (see project.yml YggdrasilTests target).
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: RESTClientTests.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        // Fallback: maybe XcodeGen flattened them into the bundle root.
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        throw NSError(domain: "Fixtures", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name).json in \(bundle.bundlePath)"])
    }
}

final class RESTClientTests: XCTestCase {
    func testAssignedIssuesDecodesFixture() async throws {
        let body = try Fixtures.data("issues-assigned")
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)

        let raws = try await client.assignedIssues()

        XCTAssertEqual(raws.count, 3)

        // Issue (no PR side-channel)
        let issue = raws[0]
        XCTAssertEqual(issue.type, .issue)
        XCTAssertEqual(issue.repoOwner, "bsv-blockchain")
        XCTAssertEqual(issue.repoName, "teranode")
        XCTAssertEqual(issue.number, 42)
        XCTAssertEqual(issue.title, "Investigate flaky integration test")
        XCTAssertEqual(issue.authorLogin, "alice")
        XCTAssertEqual(Set(issue.assignees), Set(["sigi", "alice"]))
        XCTAssertEqual(issue.state, .open)

        // Different repo
        XCTAssertEqual(raws[1].repoName, "bdk")
        XCTAssertEqual(raws[1].body, nil)

        // Item with pull_request set is classified as a PR
        XCTAssertEqual(raws[2].type, .pullRequest)
        XCTAssertEqual(raws[2].number, 100)
    }

    func testEmptyAssignedIssues() async throws {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data("[]".utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        let raws = try await client.assignedIssues()
        XCTAssertTrue(raws.isEmpty)
    }

    func testAssignedIssuesNotModifiedReturnsNotModified() async throws {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 304, body: nil, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        let result = try await client.assignedIssuesIfModified()
        switch result {
        case .notModified: break // expected
        case .modified: XCTFail("expected .notModified")
        }
    }

    func testAssignedIssuesUsesCorrectURL() async throws {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data("[]".utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        _ = try await client.assignedIssues()
        XCTAssertEqual(http.calledURLs.count, 1)
        let url = try XCTUnwrap(http.calledURLs.first)
        XCTAssertEqual(url.host, "api.github.com")
        XCTAssertEqual(url.path, "/issues")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(items["filter"], "assigned")
        XCTAssertEqual(items["state"], "open")
        XCTAssertEqual(items["per_page"], "100")
    }

    func testOpenPRsDecodesFixture() async throws {
        let body = try Fixtures.data("pulls-list")
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        let raws = try await client.openPRs(forOwner: "bsv-blockchain", name: "teranode")
        XCTAssertEqual(raws.count, 2)
        XCTAssertEqual(raws[0].type, .pullRequest)
        XCTAssertEqual(raws[0].number, 655)
        XCTAssertEqual(raws[0].title, "Add diff engine")
        XCTAssertEqual(raws[0].assignees, ["sigi"])
        XCTAssertEqual(raws[1].assignees, []) // unassigned PR also surfaces
    }

    func testOpenPRsURL() async throws {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data("[]".utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        _ = try await client.openPRs(forOwner: "bsv-blockchain", name: "teranode")
        let url = try XCTUnwrap(http.calledURLs.first)
        XCTAssertEqual(url.path, "/repos/bsv-blockchain/teranode/pulls")
    }

    func testDecodingErrorSurfacesAsGitHubError() async {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data("not json".utf8),
                       etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        do {
            _ = try await client.assignedIssues()
            XCTFail("expected to throw")
        } catch GitHubError.decodingFailed {
            // expected
        } catch {
            XCTFail("expected .decodingFailed, got \(error)")
        }
    }

    func testDefaultBranchDecodesBody() async throws {
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data("{\"default_branch\":\"master\"}".utf8),
                       etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        let branch = try await client.defaultBranch(owner: "o", name: "r")
        XCTAssertEqual(branch, "master")
        XCTAssertEqual(http.calledURLs.first?.path, "/repos/o/r")
    }

    func testDefaultBranchThrowsOnEmptyBody() async {
        // 304/empty body must throw so callers fall back to "main".
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: nil, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = RESTClient(http: http)
        do {
            _ = try await client.defaultBranch(owner: "o", name: "r")
            XCTFail("expected to throw on empty body")
        } catch {
            // expected — caller uses try? and falls back to "main"
        }
    }

    func testDefaultBranchThrowsOnFailedRequest() async {
        // No queued response → CannedHTTPClient throws (offline-style failure).
        let http = CannedHTTPClient(responses: [])
        let client = RESTClient(http: http)
        do {
            _ = try await client.defaultBranch(owner: "o", name: "r")
            XCTFail("expected to throw on failed request")
        } catch {
            // expected
        }
    }
}
