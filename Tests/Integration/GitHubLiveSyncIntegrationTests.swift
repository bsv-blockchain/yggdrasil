@testable import Loom
import XCTest

/// Hits the real GitHub API. Guarded by LOOM_TEST_GITHUB_TOKEN — runs only when the
/// env var is set. CI feeds it from a repo secret; local devs can `export` their own
/// `gh auth token` value to exercise this path.
final class GitHubLiveSyncIntegrationTests: XCTestCase {
    func testRealAssignedIssuesFetchReturnsArray() async throws {
        guard let token = ProcessInfo.processInfo.environment["LOOM_TEST_GITHUB_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("Set LOOM_TEST_GITHUB_TOKEN to run live GitHub integration tests")
        }

        let db = try LoomDatabase.inMemory()
        let keychain = InMemoryKeychainStore()
        try keychain.write(token, forKey: AuthService.tokenKey)
        let auth = AuthService(
            gh: GHCLIAuth(runner: StubSubprocessRunner(responses: []), ghExecutable: "/bin/gh"),
            keychain: keychain
        )
        let http = URLSessionHTTPClient(
            session: .shared, auth: auth, etags: ETagStore(database: db)
        )

        let client = RESTClient(http: http)
        // Just verify the call succeeds and returns a typed [RawTask] (possibly empty
        // — depends on what's assigned to whoever the token belongs to).
        _ = try await client.assignedIssues()
    }
}
