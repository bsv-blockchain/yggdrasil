import Foundation

/// Decode-only DTO for a single entry of GET `/issues?filter=assigned`.
struct RESTIssueDTO: Decodable {
    let url: String
    let repositoryURL: String
    let htmlURL: String
    let number: Int
    let title: String
    let user: User
    let state: String
    let body: String?
    let createdAt: Date
    let updatedAt: Date
    let assignees: [User]
    let pullRequest: PullRequestRef?

    struct User: Decodable {
        let login: String
    }

    struct PullRequestRef: Decodable {
        let url: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case url
            case htmlURL = "html_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case url
        case repositoryURL = "repository_url"
        case htmlURL = "html_url"
        case number, title, user, state, body, assignees
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

/// Decode-only DTO for a single entry of GET `/repos/{owner}/{repo}/pulls`.
struct RESTPRDTO: Decodable {
    let url: String
    let htmlURL: String
    let number: Int
    let title: String
    let user: User
    let state: String
    let body: String?
    let createdAt: Date
    let updatedAt: Date
    let assignees: [User]
    let draft: Bool?
    let mergedAt: Date?

    struct User: Decodable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case url
        case htmlURL = "html_url"
        case number, title, user, state, body, assignees, draft
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
    }
}

/// REST-layer's post-decode, pre-DB representation. Sync service maps repoOwner+repoName
/// to a `repo_id` and writes `task` rows.
struct RawTask: Equatable {
    let repoOwner: String
    let repoName: String
    let type: LoomTask.Kind
    let number: Int
    let title: String
    let body: String?
    let state: LoomTask.State
    let authorLogin: String
    let githubURL: String
    let apiURL: String
    let createdAt: Date
    let updatedAt: Date
    let assignees: [String]
}

extension RawTask {
    /// Parse `repositoryURL` like `https://api.github.com/repos/<owner>/<name>` to (owner, name).
    static func parseOwnerName(fromRepositoryURL urlString: String) -> (owner: String, name: String)? {
        guard let url = URL(string: urlString) else { return nil }
        // Path is `/repos/<owner>/<name>` — drop "repos" and take next two components.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let reposIdx = parts.firstIndex(of: "repos"),
              parts.count > reposIdx + 2 else { return nil }
        return (parts[reposIdx + 1], parts[reposIdx + 2])
    }

    init(issue: RESTIssueDTO) throws {
        guard let (owner, name) = RawTask.parseOwnerName(fromRepositoryURL: issue.repositoryURL) else {
            throw GitHubError.decodingFailed("could not parse owner/name from \(issue.repositoryURL)")
        }
        self.repoOwner = owner
        self.repoName = name
        self.type = issue.pullRequest == nil ? .issue : .pullRequest
        self.number = issue.number
        self.title = issue.title
        self.body = issue.body
        self.state = LoomTask.State(rawValue: issue.state) ?? .open
        self.authorLogin = issue.user.login
        self.githubURL = issue.htmlURL
        self.apiURL = issue.pullRequest?.url ?? issue.url
        self.createdAt = issue.createdAt
        self.updatedAt = issue.updatedAt
        self.assignees = issue.assignees.map(\.login)
    }

    init(pullRequest pull: RESTPRDTO, owner: String, name: String) {
        self.repoOwner = owner
        self.repoName = name
        self.type = .pullRequest
        self.number = pull.number
        self.title = pull.title
        self.body = pull.body
        self.state = pull.mergedAt != nil
            ? .merged
            : (LoomTask.State(rawValue: pull.state) ?? .open)
        self.authorLogin = pull.user.login
        self.githubURL = pull.htmlURL
        self.apiURL = pull.url
        self.createdAt = pull.createdAt
        self.updatedAt = pull.updatedAt
        self.assignees = pull.assignees.map(\.login)
    }
}
