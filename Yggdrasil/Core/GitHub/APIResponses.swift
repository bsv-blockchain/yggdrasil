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
    let labels: [Label]?
    let milestone: Milestone?

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

    struct Label: Decodable, Equatable {
        let name: String
        let color: String
    }

    struct Milestone: Decodable {
        let title: String
    }

    enum CodingKeys: String, CodingKey {
        case url
        case repositoryURL = "repository_url"
        case htmlURL = "html_url"
        case number, title, user, state, body, assignees, labels, milestone
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
    let type: YggdrasilTask.Kind
    let number: Int
    let title: String
    let body: String?
    let state: YggdrasilTask.State
    let authorLogin: String
    let githubURL: String
    let apiURL: String
    let createdAt: Date
    let updatedAt: Date
    let assignees: [String]
    /// Labels attached to the issue/PR. Surfaced in the issue-details
    /// picker as coloured chips.
    let labels: [Label]
    /// Milestone title (if any). Single string.
    let milestoneTitle: String?

    struct Label: Hashable, Codable {
        let name: String
        let color: String
    }
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
        self.state = YggdrasilTask.State(rawValue: issue.state) ?? .open
        self.authorLogin = issue.user.login
        self.githubURL = issue.htmlURL
        self.apiURL = issue.pullRequest?.url ?? issue.url
        self.createdAt = issue.createdAt
        self.updatedAt = issue.updatedAt
        self.assignees = issue.assignees.map(\.login)
        self.labels = (issue.labels ?? []).map { RawTask.Label(name: $0.name, color: $0.color) }
        self.milestoneTitle = issue.milestone?.title
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
            : (YggdrasilTask.State(rawValue: pull.state) ?? .open)
        self.authorLogin = pull.user.login
        self.githubURL = pull.htmlURL
        self.apiURL = pull.url
        self.createdAt = pull.createdAt
        self.updatedAt = pull.updatedAt
        self.assignees = pull.assignees.map(\.login)
        // RESTPRDTO doesn't decode labels/milestone; the PR endpoint flow
        // doesn't need them and the issue-details picker is issues-only.
        self.labels = []
        self.milestoneTitle = nil
    }
}
