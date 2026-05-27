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
