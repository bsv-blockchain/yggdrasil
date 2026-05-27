import Foundation

enum GitHubError: Error, Equatable {
    /// HTTP layer couldn't even reach the server (DNS, TLS, no network…).
    case requestFailed(URLError.Code)
    /// Non-success HTTP status that isn't a 401 we can recover from.
    case httpStatus(Int)
    /// Got a 401, attempted one re-auth + retry, still 401.
    case unauthorized
    /// Got a 2xx but the body didn't decode.
    case decodingFailed(String)
    /// GraphQL response had top-level "errors".
    case graphqlErrors([String])
}
