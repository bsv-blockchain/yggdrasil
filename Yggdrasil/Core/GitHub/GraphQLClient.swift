import Foundation

/// Decoded per-PR detail, ready to be mapped to a `github_status` row.
struct PRDetail: Equatable {
    let mergeable: Bool?
    let mergeableState: String?
    let reviewState: String?
    let ciState: String?
    let commentsTotal: Int
    let reviewsTotal: Int
    let commitsTotal: Int
    let headSHA: String?
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
    let reviews: TotalCountNode?
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
          reviews(first: 1) { totalCount }
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
        return PRDetail(
            mergeable: mergeable,
            mergeableState: pull.mergeStateStatus,
            reviewState: pull.reviewDecision,
            ciState: ciState,
            commentsTotal: pull.comments?.totalCount ?? 0,
            reviewsTotal: pull.reviews?.totalCount ?? 0,
            commitsTotal: pull.commits?.totalCount ?? 0,
            headSHA: pull.commits?.nodes.first?.commit.oid
        )
    }
}
