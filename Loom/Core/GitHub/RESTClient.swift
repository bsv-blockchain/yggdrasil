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

    /// Reusable decoder configured for GitHub's ISO-8601 date format.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
