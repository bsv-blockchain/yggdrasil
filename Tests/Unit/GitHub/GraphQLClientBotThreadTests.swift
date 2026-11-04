import Foundation
import XCTest
@testable import Yggdrasil

/// Bot replies in review threads: who counts as waiting on the viewer. Each
/// test holds one thread so the count pins that thread's verdict alone.
final class GraphQLClientBotThreadTests: XCTestCase {
    private let mine = #"{ "viewerDidAuthor": true, "author": { "__typename": "User" } }"#
    private let person = #"{ "viewerDidAuthor": false, "author": { "__typename": "User" } }"#
    private let bot = #"{ "viewerDidAuthor": false, "author": { "__typename": "Bot" } }"#

    func testBotReplyAfterMineDoesNotAwaitMe() async throws {
        // A github-actions reply after mine kept a review tab amber (teranode #2017).
        let count = try await awaiting(thread: [mine, bot], viewerDidAuthor: false)
        XCTAssertEqual(count, 0)
    }

    func testPersonReplyBeforeATrailingBotStillAwaitsMe() async throws {
        let count = try await awaiting(thread: [mine, person, bot], viewerDidAuthor: false)
        XCTAssertEqual(count, 1)
    }

    func testBotThreadOnMyOwnPRStillAwaitsMe() async throws {
        // A thread a bot opened on my PR is still mine to address or resolve.
        let count = try await awaiting(thread: [bot], viewerDidAuthor: true)
        XCTAssertEqual(count, 1)
    }

    func testBotReplyAfterMineOnMyOwnPRDoesNotAwaitMe() async throws {
        let count = try await awaiting(thread: [person, mine, bot], viewerDidAuthor: true)
        XCTAssertEqual(count, 0)
    }

    func testCommentWithoutAnAuthorCountsAsAPerson() async throws {
        // A deleted account comes back as null; no author key at all must decode too.
        let deleted = #"{ "viewerDidAuthor": false, "author": null }"#
        let noKey = #"{ "viewerDidAuthor": false }"#
        let afterDeleted = try await awaiting(thread: [mine, deleted], viewerDidAuthor: false)
        let afterNoKey = try await awaiting(thread: [mine, noKey], viewerDidAuthor: false)
        XCTAssertEqual(afterDeleted, 1)
        XCTAssertEqual(afterNoKey, 1)
    }

    private func awaiting(thread comments: [String], viewerDidAuthor: Bool) async throws -> Int {
        let json = """
        { "data": { "repository": { "pullRequest": {
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "REVIEW_REQUIRED",
          "viewerDidAuthor": \(viewerDidAuthor),
          "commits": { "totalCount": 1, "nodes": [{ "commit": { "oid": "h", "statusCheckRollup": null } }] },
          "comments": { "totalCount": 0 }, "reviews": { "totalCount": 0, "nodes": [] },
          "reviewThreads": { "nodes": [
            { "isResolved": false, "comments": { "nodes": [\(comments.joined(separator: ", "))] } }
          ] }
        }}}}
        """
        let http = CannedHTTPClient(responses: [
            HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
        ])
        return try await GraphQLClient(http: http).prDetail(owner: "o", repo: "r", number: 1)
            .unresolvedThreadsAwaitingViewer
    }
}
