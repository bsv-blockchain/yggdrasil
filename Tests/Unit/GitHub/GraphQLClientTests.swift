import Foundation
import XCTest
@testable import Yggdrasil

final class GraphQLClientTests: XCTestCase {
    func testPRDetailDecodesAllFields() async throws {
        let body = try Fixtures.data("pr-detail.graphql")
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = GraphQLClient(http: http)

        let detail = try await client.prDetail(owner: "bsv-blockchain", repo: "teranode", number: 655)

        XCTAssertEqual(detail.mergeable, true)
        XCTAssertEqual(detail.mergeableState, "CLEAN")
        XCTAssertEqual(detail.reviewState, "APPROVED")
        XCTAssertEqual(detail.ciState, "SUCCESS")
        XCTAssertEqual(detail.commentsTotal, 5)
        XCTAssertEqual(detail.reviewsTotal, 2)
    }

    func testPRDetailHandlesUnknownMergeableAndNullCI() async throws {
        let body = try Fixtures.data("pr-detail-no-ci.graphql")
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = GraphQLClient(http: http)

        let detail = try await client.prDetail(owner: "bsv-blockchain", repo: "teranode", number: 655)

        XCTAssertNil(detail.mergeable, "UNKNOWN mergeable maps to nil")
        XCTAssertEqual(detail.mergeableState, "UNKNOWN")
        XCTAssertNil(detail.reviewState)
        XCTAssertNil(detail.ciState, "null statusCheckRollup maps to nil ciState")
        XCTAssertEqual(detail.commentsTotal, 0)
    }

    func testPRDetailSurfacesGraphQLErrors() async {
        let body: Data
        do {
            body = try Fixtures.data("pr-detail-errors.graphql")
        } catch {
            return XCTFail("could not load fixture: \(error)")
        }
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = GraphQLClient(http: http)

        do {
            _ = try await client.prDetail(owner: "bsv-blockchain", repo: "nope", number: 1)
            XCTFail("expected to throw")
        } catch let GitHubError.graphqlErrors(messages) {
            XCTAssertEqual(messages.count, 1)
            XCTAssertTrue(messages[0].contains("Could not resolve"))
        } catch {
            XCTFail("expected .graphqlErrors, got \(error)")
        }
    }

    func testPRDetailSumsInlineReviewComments() async throws {
        // Inline review-thread comments (author replies to review feedback) are
        // summed across reviews — they don't show up in `comments.totalCount`.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": null,
          "commits": { "totalCount": 3, "nodes": [{ "commit": { "oid": "abc123", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 6 },
          "reviews": { "totalCount": 2, "nodes": [
            { "comments": { "totalCount": 3 } },
            { "comments": { "totalCount": 2 } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        XCTAssertEqual(detail.commentsTotal, 6)
        XCTAssertEqual(detail.reviewsTotal, 2)
        XCTAssertEqual(detail.reviewCommentsTotal, 5, "inline review comments summed across reviews")
        XCTAssertEqual(detail.commitsTotal, 3)
        XCTAssertEqual(detail.headSHA, "abc123")
    }

    func testPRDetailDecodesViewerReviewAndThreads() async throws {
        // viewerLatestReview + reviewThreads drive the outstanding-action pill.
        // Threads awaiting me = unresolved with a last comment I didn't author.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
          "commits": { "totalCount": 4, "nodes": [{ "commit": { "oid": "newhead", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 },
          "reviews": { "totalCount": 1, "nodes": [] },
          "viewerLatestReview": { "state": "APPROVED", "commit": { "oid": "oldhead" } },
          "reviewThreads": { "nodes": [
            { "isResolved": true,  "comments": { "nodes": [{ "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": true }] } },
            { "isResolved": false, "comments": { "nodes": [] } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        XCTAssertEqual(detail.viewerLatestReviewState, "APPROVED")
        XCTAssertEqual(detail.viewerReviewedHeadSHA, "oldhead")
        XCTAssertEqual(detail.headSHA, "newhead")
        // Only the one unresolved thread whose last comment isn't mine counts.
        XCTAssertEqual(detail.unresolvedThreadsAwaitingViewer, 1)
    }

    func testPRDetailMissingViewerReviewDefaultsToNilAndZero() async throws {
        // Older mocks / PRs with no reviewThreads block still decode.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": null,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)
        XCTAssertNil(detail.viewerLatestReviewState)
        XCTAssertNil(detail.viewerReviewedHeadSHA)
        XCTAssertEqual(detail.unresolvedThreadsAwaitingViewer, 0)
    }

    func testPostsToGraphQLEndpointWithVariables() async throws {
        let body = try Fixtures.data("pr-detail.graphql")
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: body, etag: nil, rateLimitRemaining: 4999)
        ])
        let client = GraphQLClient(http: http)
        _ = try await client.prDetail(owner: "bsv-blockchain", repo: "teranode", number: 655)
        XCTAssertEqual(http.calledURLs.first?.absoluteString, "https://api.github.com/graphql")
    }
}
