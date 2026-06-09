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
