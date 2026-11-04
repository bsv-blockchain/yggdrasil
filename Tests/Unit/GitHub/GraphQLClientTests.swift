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
        // A thread awaits me only if I authored a comment in it AND the last
        // comment isn't mine — bot threads / threads I never joined don't count.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
          "commits": { "totalCount": 4, "nodes": [{ "commit": { "oid": "newhead", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 },
          "reviews": { "totalCount": 1, "nodes": [] },
          "viewerLatestReview": { "state": "APPROVED", "commit": { "oid": "oldhead" } },
          "reviewThreads": { "nodes": [
            { "isResolved": true,  "comments": { "nodes": [{ "viewerDidAuthor": true }, { "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": true }, { "viewerDidAuthor": false }] } },
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
        // Only thread 2 counts: unresolved, I'm in it, someone replied after me.
        // Thread 1 resolved; thread 3 I never joined (bot); thread 4 I spoke
        // last; thread 5 has no comments.
        XCTAssertEqual(detail.unresolvedThreadsAwaitingViewer, 1)
    }

    func testPRDetailDecodesViewerReviewRequest() async throws {
        // An open review request for the viewer — what a re-requested review
        // creates — is the authoritative "your move" signal.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "CHANGES_REQUESTED",
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewRequests": { "nodes": [
            { "requestedReviewer": { "login": "someone", "isViewer": false } },
            { "requestedReviewer": { "login": "me", "isViewer": true } },
            { "requestedReviewer": {} }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)
        XCTAssertTrue(detail.viewerReviewRequested)
    }

    func testPRDetailWithoutViewerReviewRequestIsFalse() async throws {
        // Only other people (and a team, which has no isViewer) are requested.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": null,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewRequests": { "nodes": [
            { "requestedReviewer": { "login": "someone", "isViewer": false } },
            { "requestedReviewer": { "name": "some-team" } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)
        XCTAssertFalse(detail.viewerReviewRequested)
    }

    func testPRDetailCountsAllUnresolvedThreadsOnMyOwnPR() async throws {
        // On a PR I authored, an unresolved thread whose last comment isn't mine
        // is my move even if I never replied in it — the 1385 case. Bot threads
        // count too: they're mine to address or resolve.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "REVIEW_REQUIRED",
          "viewerDidAuthor": true,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewThreads": { "nodes": [
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": false }, { "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": false }, { "viewerDidAuthor": true }] } },
            { "isResolved": true,  "comments": { "nodes": [{ "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [] } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        XCTAssertTrue(detail.viewerDidAuthor)
        // Threads 1 + 2 await me. Thread 3 I answered last; thread 4 resolved;
        // thread 5 empty.
        XCTAssertEqual(detail.unresolvedThreadsAwaitingViewer, 2)
    }

    func testPRDetailOnSomeoneElsesPRStillRequiresMeInTheThread() async throws {
        // Reviewer side is unchanged: a thread I never joined is the author's to
        // resolve, not mine.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "REVIEW_REQUIRED",
          "viewerDidAuthor": false,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewThreads": { "nodes": [
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": false }] } },
            { "isResolved": false, "comments": { "nodes": [{ "viewerDidAuthor": true }, { "viewerDidAuthor": false }] } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        XCTAssertFalse(detail.viewerDidAuthor)
        XCTAssertEqual(detail.unresolvedThreadsAwaitingViewer, 1)
    }

    func testPRDetailTakesLatestReviewRequestTimeForTheViewer() async throws {
        // When I was (re-)asked. Compared against my last engagement so a
        // request I've already answered stops reading as "your move".
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "REVIEW_REQUIRED",
          "viewerDidAuthor": false,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewRequests": { "nodes": [{ "requestedReviewer": { "isViewer": true } }] },
          "timelineItems": { "nodes": [
            { "createdAt": "2026-08-07T12:52:06Z", "requestedReviewer": { "isViewer": true } },
            { "createdAt": "2026-08-19T09:00:00Z", "requestedReviewer": { "isViewer": false } },
            { "createdAt": "2026-08-20T12:38:59Z", "requestedReviewer": { "isViewer": true } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        XCTAssertTrue(detail.viewerReviewRequested)
        // Latest of *my* request events; someone else's 08-19 request is ignored.
        XCTAssertEqual(
            detail.viewerReviewRequestedAt,
            ISO8601DateFormatter().date(from: "2026-08-20T12:38:59Z")
        )
    }

    func testPRDetailReviewRequestTimeNilWhenNeverRequestedFromMe() async throws {
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": null,
          "viewerDidAuthor": false,
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "timelineItems": { "nodes": [
            { "createdAt": "2026-08-19T09:00:00Z", "requestedReviewer": { "isViewer": false } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)
        XCTAssertFalse(detail.viewerReviewRequested)
        XCTAssertNil(detail.viewerReviewRequestedAt)
    }

    func testPRDetailComputesEngagementAndHeadCommitDates() async throws {
        // The 1176 shape: I requested changes, the author pushed, then I
        // commented after the push. viewerLastEngagementAt = my latest activity
        // (the comment), not just my review; others' comments are ignored.
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "CHANGES_REQUESTED",
          "commits": { "totalCount": 5, "nodes": [{ "commit": { "oid": "h", "committedDate": "2026-06-30T11:28:47Z", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 2, "nodes": [
            { "viewerDidAuthor": false, "createdAt": "2026-07-02T09:00:00Z" },
            { "viewerDidAuthor": true,  "createdAt": "2026-07-01T16:42:24Z" }
          ] },
          "reviews": { "totalCount": 1, "nodes": [] },
          "viewerLatestReview": { "state": "CHANGES_REQUESTED", "submittedAt": "2026-06-29T11:50:56Z", "commit": { "oid": "old" } },
          "reviewThreads": { "nodes": [] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        let detail = try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)

        let iso = ISO8601DateFormatter()
        // My last engagement = my comment (07-01), later than my review (06-29);
        // the other person's 07-02 comment does not count.
        XCTAssertEqual(detail.viewerLastEngagementAt, iso.date(from: "2026-07-01T16:42:24Z"))
        XCTAssertEqual(detail.headCommittedAt, iso.date(from: "2026-06-30T11:28:47Z"))
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
        XCTAssertFalse(detail.viewerReviewRequested)
        XCTAssertNil(detail.viewerReviewRequestedAt)
        XCTAssertFalse(detail.viewerDidAuthor)
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
