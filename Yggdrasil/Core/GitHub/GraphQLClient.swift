import Foundation

/// Decoded per-PR detail, ready to be mapped to a `github_status` row.
struct PRDetail: Equatable {
    let mergeable: Bool?
    let mergeableState: String?
    let reviewState: String?
    let ciState: String?
    let commentsTotal: Int
    let reviewsTotal: Int
    /// Inline review-thread comments (incl. author replies to review feedback).
    /// Counted separately from issue comments so "the author responded to my
    /// review" registers as activity.
    let reviewCommentsTotal: Int
    let commitsTotal: Int
    let headSHA: String?
    /// The viewer's latest review state ("APPROVED"/"CHANGES_REQUESTED"/
    /// "COMMENTED"/"DISMISSED"/"PENDING"), or nil if they haven't reviewed.
    let viewerLatestReviewState: String?
    /// The commit oid the viewer's latest review covered — compared to `headSHA`
    /// to tell whether an approval is still current after new pushes.
    let viewerReviewedHeadSHA: String?
    /// Count of unresolved review threads whose last comment isn't the viewer's
    /// — i.e. threads awaiting the viewer's reply/re-review.
    let unresolvedThreadsAwaitingViewer: Int
}

// MARK: - GraphQL response envelope

private struct GraphQLEnvelope: Decodable {
    let data: DataNode?
    let errors: [GraphQLErrorNode]?
}

private struct GraphQLErrorNode: Decodable {
    let message: String
}

private struct DataNode: Decodable {
    let repository: RepositoryNode?
}

private struct RepositoryNode: Decodable {
    let pullRequest: PullRequestNode
}

private struct PullRequestNode: Decodable {
    let mergeable: String
    let mergeStateStatus: String?
    let reviewDecision: String?
    let commits: CommitsNode?
    let comments: TotalCountNode?
    let reviews: ReviewsNode?
    let viewerLatestReview: ViewerReviewNode?
    let reviewThreads: ReviewThreadsNode?
}

private struct ViewerReviewNode: Decodable {
    let state: String?
    let commit: CommitInner?
}

private struct ReviewThreadsNode: Decodable {
    let nodes: [ReviewThreadNode]?
}

private struct ReviewThreadNode: Decodable {
    let isResolved: Bool?
    let comments: ThreadCommentsNode?
}

private struct ThreadCommentsNode: Decodable {
    let nodes: [ThreadCommentNode]?
}

private struct ThreadCommentNode: Decodable {
    let viewerDidAuthor: Bool?
}

private struct ReviewsNode: Decodable {
    let totalCount: Int?
    let nodes: [ReviewNodeWrap]?
}

private struct ReviewNodeWrap: Decodable {
    let comments: TotalCountNode?
}

private struct CommitsNode: Decodable {
    let totalCount: Int?
    let nodes: [CommitNodeWrap]
}

private struct CommitNodeWrap: Decodable {
    let commit: CommitInner
}

private struct CommitInner: Decodable {
    let oid: String?
    let statusCheckRollup: StatusCheckRollupNode?
}

private struct StatusCheckRollupNode: Decodable {
    let state: String?
}

private struct TotalCountNode: Decodable {
    let totalCount: Int
}

// MARK: - GraphQLClient

struct GraphQLClient {
    let http: HTTPClient

    private static let prDetailQuery = """
    query PRDetail($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          mergeable
          mergeStateStatus
          reviewDecision
          commits(last: 1) { totalCount nodes { commit { oid statusCheckRollup { state } } } }
          comments(first: 1) { totalCount }
          reviews(first: 100) { totalCount nodes { comments { totalCount } } }
          viewerLatestReview { state commit { oid } }
          reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { viewerDidAuthor } } } }
        }
      }
    }
    """

    func prDetail(owner: String, repo: String, number: Int) async throws -> PRDetail {
        let payload: [String: Any] = [
            "query": Self.prDetailQuery,
            "variables": ["owner": owner, "name": repo, "number": number]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try await http.post(
            url: Endpoints.graphqlURL,
            body: body,
            accept: "application/json"
        )
        let envelope = try Self.decode(result.body ?? Data())

        if let errors = envelope.errors, !errors.isEmpty {
            throw GitHubError.graphqlErrors(errors.map(\.message))
        }
        guard let pull = envelope.data?.repository?.pullRequest else {
            throw GitHubError.decodingFailed("missing data.repository.pullRequest")
        }
        return Self.mapToDetail(pull)
    }

    private static func decode(_ data: Data) throws -> GraphQLEnvelope {
        do {
            return try JSONDecoder().decode(GraphQLEnvelope.self, from: data)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
    }

    private static func mapToDetail(_ pull: PullRequestNode) -> PRDetail {
        let mergeable: Bool? = switch pull.mergeable {
        case "MERGEABLE": true
        case "CONFLICTING": false
        default: nil
        }
        let ciState = pull.commits?.nodes.first?.commit.statusCheckRollup?.state
        // Threads awaiting the viewer: unresolved, with a last comment the
        // viewer didn't author. A thread with no comments doesn't count.
        let unresolvedAwaitingViewer = (pull.reviewThreads?.nodes ?? []).filter { thread in
            guard !(thread.isResolved ?? false) else { return false }
            guard let last = thread.comments?.nodes?.last else { return false }
            return !(last.viewerDidAuthor ?? false)
        }.count
        return PRDetail(
            mergeable: mergeable,
            mergeableState: pull.mergeStateStatus,
            reviewState: pull.reviewDecision,
            ciState: ciState,
            commentsTotal: pull.comments?.totalCount ?? 0,
            reviewsTotal: pull.reviews?.totalCount ?? 0,
            reviewCommentsTotal: pull.reviews?.nodes?
                .reduce(0) { $0 + ($1.comments?.totalCount ?? 0) } ?? 0,
            commitsTotal: pull.commits?.totalCount ?? 0,
            headSHA: pull.commits?.nodes.first?.commit.oid,
            viewerLatestReviewState: pull.viewerLatestReview?.state,
            viewerReviewedHeadSHA: pull.viewerLatestReview?.commit?.oid,
            unresolvedThreadsAwaitingViewer: unresolvedAwaitingViewer
        )
    }
}
