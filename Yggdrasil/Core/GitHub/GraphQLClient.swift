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
    /// The most recent time the viewer engaged with the PR — the latest of their
    /// last review submission and their last comment (issue or review-thread).
    /// nil if they've never engaged. Compared against `headCommittedAt` to tell
    /// whether the author pushed something the viewer hasn't looked at.
    let viewerLastEngagementAt: Date?
    /// Commit date of the current head. Compared against `viewerLastEngagementAt`.
    let headCommittedAt: Date?
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
    let comments: IssueCommentsNode?
    let reviews: ReviewsNode?
    let viewerLatestReview: ViewerReviewNode?
    let reviewThreads: ReviewThreadsNode?
}

private struct ViewerReviewNode: Decodable {
    let state: String?
    let submittedAt: String?
    let commit: CommitInner?
}

private struct IssueCommentsNode: Decodable {
    let totalCount: Int
    let nodes: [AuthoredCommentNode]?
}

private struct ReviewThreadsNode: Decodable {
    let nodes: [ReviewThreadNode]?
}

private struct ReviewThreadNode: Decodable {
    let isResolved: Bool?
    let comments: ThreadCommentsNode?
}

private struct ThreadCommentsNode: Decodable {
    let nodes: [AuthoredCommentNode]?
}

/// A comment (issue or review-thread) with just what we need to decide the
/// viewer's engagement time and thread ownership.
private struct AuthoredCommentNode: Decodable {
    let viewerDidAuthor: Bool?
    let createdAt: String?
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
    let committedDate: String?
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
          commits(last: 1) { totalCount nodes { commit { oid committedDate statusCheckRollup { state } } } }
          comments(last: 100) { totalCount nodes { viewerDidAuthor createdAt } }
          reviews(first: 100) { totalCount nodes { comments { totalCount } } }
          viewerLatestReview { state submittedAt commit { oid } }
          reviewThreads(first: 100) { nodes { isResolved comments(last: 100) { nodes { viewerDidAuthor createdAt } } } }
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
        // Threads awaiting the viewer's reply: unresolved, the viewer authored a
        // comment in it (so it's a conversation they're part of), and the last
        // comment isn't theirs. Excludes bot threads and threads between others
        // the viewer never joined — those are the author's to resolve.
        let unresolvedAwaitingViewer = (pull.reviewThreads?.nodes ?? []).filter { thread in
            guard !(thread.isResolved ?? false) else { return false }
            let comments = thread.comments?.nodes ?? []
            guard comments.contains(where: { $0.viewerDidAuthor == true }) else { return false }
            guard let last = comments.last else { return false }
            return !(last.viewerDidAuthor ?? false)
        }.count

        // The viewer's most recent engagement: latest of their last review and
        // every comment they authored (issue + review-thread). Compared against
        // the head commit date so a push the viewer has already commented on
        // doesn't read as "unseen".
        let iso = ISO8601DateFormatter()
        func parse(_ raw: String?) -> Date? {
            raw.flatMap { iso.date(from: $0) }
        }
        var engagementDates: [Date] = []
        if let submitted = parse(pull.viewerLatestReview?.submittedAt) { engagementDates.append(submitted) }
        let issueComments = pull.comments?.nodes ?? []
        let threadComments = (pull.reviewThreads?.nodes ?? []).flatMap { $0.comments?.nodes ?? [] }
        for comment in issueComments + threadComments where comment.viewerDidAuthor == true {
            if let created = parse(comment.createdAt) { engagementDates.append(created) }
        }

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
            unresolvedThreadsAwaitingViewer: unresolvedAwaitingViewer,
            viewerLastEngagementAt: engagementDates.max(),
            headCommittedAt: parse(pull.commits?.nodes.first?.commit.committedDate)
        )
    }
}
