import Foundation

/// Outcome of a sync-shaped REST call that supports If-None-Match.
enum CacheableFetch<T> {
    case modified(T)
    case notModified
}

/// GitHub REST client for the slice Phase 1 needs.
struct RESTClient {
    let http: HTTPClient

    func assignedIssues() async throws -> [RawTask] {
        switch try await assignedIssuesIfModified() {
        case let .modified(raws): raws
        case .notModified: []
        }
    }

    func assignedIssuesIfModified() async throws -> CacheableFetch<[RawTask]> {
        let result = try await http.get(
            url: Endpoints.assignedIssues(),
            accept: "application/vnd.github+json"
        )
        if result.status == 304 || result.body == nil {
            return .notModified
        }
        let body = result.body ?? Data()
        let dtos: [RESTIssueDTO]
        do {
            dtos = try Self.decoder.decode([RESTIssueDTO].self, from: body)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let raws = try dtos.map { try RawTask(issue: $0) }
        return .modified(raws)
    }

    /// PRs across all of GitHub where the authenticated user is a requested
    /// reviewer. Backed by `/search/issues`, which wraps results in
    /// `{ items: […] }` — items are the same shape as `RESTIssueDTO`.
    /// No ETag-cached If-None-Match here; search responses change too often
    /// to make the conditional GET worthwhile.
    func reviewRequestedPRs() async throws -> [RawTask] {
        try await searchIssues(url: Endpoints.reviewRequestedPRs())
    }

    /// PRs authored by the authenticated user. Same endpoint shape and
    /// caveats as `reviewRequestedPRs`.
    func authoredPRs() async throws -> [RawTask] {
        try await searchIssues(url: Endpoints.authoredPRs())
    }

    /// Every issue assigned to the authenticated user, regardless of the
    /// owning repo's tracked status. Used by the My Issues table picker.
    func allAssignedIssues() async throws -> [RawTask] {
        try await searchIssues(url: Endpoints.allAssignedIssues())
    }

    private func searchIssues(url: URL) async throws -> [RawTask] {
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        let body = result.body ?? Data()
        struct Envelope: Decodable { let items: [RESTIssueDTO] }
        let dtos: [RESTIssueDTO]
        do {
            dtos = try Self.decoder.decode(Envelope.self, from: body).items
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return try dtos.map { try RawTask(issue: $0) }
    }

    func openPRs(forOwner owner: String, name: String) async throws -> [RawTask] {
        switch try await openPRsIfModified(forOwner: owner, name: name) {
        case let .modified(raws): raws
        case .notModified: []
        }
    }

    func openPRsIfModified(forOwner owner: String, name: String) async throws -> CacheableFetch<[RawTask]> {
        let url = Endpoints.openPullRequests(owner: owner, repo: name)
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        if result.status == 304 || result.body == nil {
            return .notModified
        }
        let body = result.body ?? Data()
        let dtos: [RESTPRDTO]
        do {
            dtos = try Self.decoder.decode([RESTPRDTO].self, from: body)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return .modified(dtos.map { RawTask(pullRequest: $0, owner: owner, name: name) })
    }

    func defaultBranch(owner: String, name: String) async throws -> String {
        let url = Endpoints.repoInfo(owner: owner, repo: name)
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        let body = result.body ?? Data()
        struct RepoDTO: Decodable {
            let defaultBranch: String
            enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
        }
        return try Self.decoder.decode(RepoDTO.self, from: body).defaultBranch
    }

    /// Resolved metadata from `GET /repos/{owner}/{repo}`: default branch plus,
    /// for forks, the upstream (source) repo whose issues/PRs we also pull.
    /// Prefers the fork-network root (`source`) over the immediate `parent`, so
    /// a fork-of-a-fork still resolves to the true home of the issues.
    struct RepoInfo: Equatable {
        let defaultBranch: String
        let isFork: Bool
        let upstreamOwner: String?
        let upstreamName: String?
    }

    func repoInfo(owner: String, name: String) async throws -> RepoInfo {
        let url = Endpoints.repoInfo(owner: owner, repo: name)
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        guard let body = result.body else {
            throw GitHubError.requestFailed(.badServerResponse)
        }
        let dto: RepoInfoDTO
        do {
            dto = try Self.decoder.decode(RepoInfoDTO.self, from: body)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        let upstream = (dto.source?.fullName ?? dto.parent?.fullName)
            .flatMap(Self.splitFullName)
        return RepoInfo(
            defaultBranch: dto.defaultBranch,
            isFork: dto.fork ?? false,
            upstreamOwner: upstream?.owner,
            upstreamName: upstream?.name
        )
    }

    /// Split a `owner/name` full name; nil if malformed (empty half or no slash).
    private static func splitFullName(_ fullName: String) -> (owner: String, name: String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Fetch a single PR by number. Works for any state (open / closed /
    /// merged), unlike the open-PRs list. Used by the "Link PR" flow to
    /// import a PR on demand.
    func pullRequest(owner: String, name: String, number: Int) async throws -> RawTask {
        let url = Endpoints.pullRequest(owner: owner, repo: name, number: number)
        let result = try await http.get(url: url, accept: "application/vnd.github+json")
        guard result.status == 200, let body = result.body else {
            throw GitHubError.requestFailed(.badServerResponse)
        }
        let dto: RESTPRDTO
        do {
            dto = try Self.decoder.decode(RESTPRDTO.self, from: body)
        } catch {
            throw GitHubError.decodingFailed(String(describing: error))
        }
        return RawTask(pullRequest: dto, owner: owner, name: name)
    }

    /// Reusable decoder configured for GitHub's ISO-8601 date format.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Decodes the subset of `GET /repos/{owner}/{repo}` we need: default branch
/// and (for forks) the parent/source repo. File-scoped to keep nesting shallow.
private struct RepoInfoDTO: Decodable {
    let defaultBranch: String
    let fork: Bool?
    let parent: RepoRef?
    let source: RepoRef?

    struct RepoRef: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
        case fork, parent, source
    }
}
