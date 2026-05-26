import Foundation

/// HTTP response from a Loom REST/GraphQL call after the client applied auth,
/// ETag handling, and the 401-retry policy.
struct HTTPResult: Equatable {
    let status: Int
    /// `nil` when the server returned 304 Not Modified.
    let body: Data?
    let etag: String?
    let rateLimitRemaining: Int?
}

protocol HTTPClient: Sendable {
    func get(url: URL, accept: String) async throws -> HTTPResult
    func post(url: URL, body: Data, accept: String) async throws -> HTTPResult
}

/// URLSession-backed implementation.
/// - Injects `Authorization: Bearer <token>` from `AuthService`.
/// - Round-trips ETag via `ETagStore`; surfaces `body == nil` on 304.
/// - On 401: invalidates the AuthService cache, fetches a fresh token, retries once.
/// - Logs `X-RateLimit-Remaining` with a warn below the spec's 100-call threshold.
final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let auth: AuthService
    private let etags: ETagStore
    private let userAgent: String

    init(session: URLSession, auth: AuthService, etags: ETagStore, userAgent: String = "Loom/0.1") {
        self.session = session
        self.auth = auth
        self.etags = etags
        self.userAgent = userAgent
    }

    func get(url: URL, accept: String) async throws -> HTTPResult {
        try await perform(url: url, method: "GET", body: nil, accept: accept)
    }

    func post(url: URL, body: Data, accept: String) async throws -> HTTPResult {
        try await perform(url: url, method: "POST", body: body, accept: accept)
    }

    private func perform(
        url: URL,
        method: String,
        body: Data?,
        accept: String,
        attempt: Int = 1
    ) async throws -> HTTPResult {
        let token = try await auth.currentToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if method == "GET", let etag = try etags.get(for: url) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            LoomLog.sync.error("HTTP request failed: \(error.code.rawValue) \(error.localizedDescription)")
            throw GitHubError.requestFailed(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.requestFailed(.badServerResponse)
        }

        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        if let remaining, remaining < 100 {
            LoomLog.sync.warning("GitHub rate-limit remaining: \(remaining, privacy: .public)")
        }

        if http.statusCode == 401 {
            if attempt == 1 {
                LoomLog.auth.info("Got 401 — invalidating cached token and retrying once")
                await auth.invalidate()
                return try await perform(
                    url: url, method: method, body: body, accept: accept, attempt: attempt + 1
                )
            }
            throw GitHubError.unauthorized
        }

        if http.statusCode == 304 {
            return HTTPResult(status: 304, body: nil, etag: nil, rateLimitRemaining: remaining)
        }

        if !(200 ..< 300).contains(http.statusCode) {
            throw GitHubError.httpStatus(http.statusCode)
        }

        let etag = http.value(forHTTPHeaderField: "Etag")
        if method == "GET", let etag {
            try etags.set(etag, for: url)
        }

        return HTTPResult(
            status: http.statusCode, body: data, etag: etag, rateLimitRemaining: remaining
        )
    }
}
