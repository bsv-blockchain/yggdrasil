import Foundation

/// Builds URLs for GitHub REST and GraphQL endpoints.
enum Endpoints {
    static let restBase = URL(string: "https://api.github.com")!
    static let graphqlURL = URL(string: "https://api.github.com/graphql")!

    /// `/issues?filter=assigned&state=open&per_page=100`
    static func assignedIssues(perPage: Int = 100) -> URL {
        var components = URLComponents(url: restBase.appendingPathComponent("issues"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "assigned"),
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        return components.url!
    }

    /// `/search/issues?q=is:pr+is:open+author:@me&per_page=100`
    ///
    /// PRs the authenticated user authored. Same `{ items: […] }` envelope
    /// as the other search endpoints. Used to populate the Open Assigned
    /// picker (issues-assigned-to-me + PRs-I-authored).
    static func authoredPRs(perPage: Int = 100) -> URL {
        var components = URLComponents(url: restBase.appendingPathComponent("search/issues"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "is:pr is:open author:@me archived:false"),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        return components.url!
    }

    /// `/search/issues?q=is:pr+is:open+review-requested:@me&per_page=100`
    ///
    /// GitHub's `/search/issues` returns both issues and PRs; the `is:pr`
    /// qualifier narrows to PRs. `review-requested:@me` matches PRs where
    /// the authenticated user is a requested reviewer (either directly or
    /// via a team). Uses the same `RESTIssueDTO` payload shape as
    /// `/issues`, wrapped in a `{ items: […] }` envelope.
    static func reviewRequestedPRs(perPage: Int = 100) -> URL {
        var components = URLComponents(url: restBase.appendingPathComponent("search/issues"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "is:pr is:open review-requested:@me archived:false"),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        return components.url!
    }

    /// `/repos/{owner}/{repo}/pulls?state=open&per_page=100`
    static func openPullRequests(owner: String, repo: String, perPage: Int = 100) -> URL {
        var components = URLComponents(
            url: restBase
                .appendingPathComponent("repos")
                .appendingPathComponent(owner)
                .appendingPathComponent(repo)
                .appendingPathComponent("pulls"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        return components.url!
    }
}
