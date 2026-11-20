import XCTest
@testable import Yggdrasil

/// The starting-prompt templates are Settings, so the API can change them:
/// the global ones through settings.set, a repository's own through
/// repo.setStartingPrompt.
@MainActor
final class StartingPromptActionsTests: XCTestCase {
    private var services: AppServices!
    private var context: ControlAction.Context!

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        context = ControlAction.Context(services: services, key: nil)
    }

    func testTheGlobalTemplatesAreSettings() async throws {
        XCTAssertEqual(SettingsActions.read(services: services).reviewPrompt, "/cr {number}", "the default")
        let set = try XCTUnwrap(ActionCatalog.all.first { $0.name == "settings.set" })
        let result = try await set.run(
            set.validate(["reviewPrompt": .string("/review {url}"), "issuePrompt": .string("")]), context
        )
        let settings = SettingsActions.read(services: services)
        XCTAssertEqual(settings.reviewPrompt, "/review {url}")
        XCTAssertEqual(settings.issuePrompt, "", "empty is off")
        XCTAssertEqual(result["reviewPrompt"]?.stringValue, "/review {url}")
    }

    func testARepositorysOwnTemplateCanBeSetTurnedOffAndCleared() async throws {
        let repo = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.name == "repo.setStartingPrompt" })
        _ = try await action.run(
            action.validate([
                "repo": .string("acme/widget"),
                "kind": .string("review"),
                "prompt": .string("/x {number}")
            ]),
            context
        )
        _ = try await action.run(
            action.validate(["repo": .string("acme/widget"), "kind": .string("issue"), "prompt": .string("")]), context
        )
        var row = try await fetch(repo)
        XCTAssertEqual(row?.reviewPrompt, "/x {number}")
        XCTAssertEqual(row?.issuePrompt, "")
        XCTAssertEqual(try ControlEncoding.repo(XCTUnwrap(row))["reviewPrompt"]?.stringValue, "/x {number}")

        _ = try await action.run(action.validate(["repo": .string("acme/widget"), "kind": .string("review")]), context)
        row = try await fetch(repo)
        XCTAssertNil(row?.reviewPrompt, "left out: the global one again")
        XCTAssertThrowsError(try action.validate(["repo": .string("acme/widget"), "kind": .string("pr")]))
    }

    private func fetch(_ repo: Repo) async throws -> Repo? {
        try await services.database.queue.read { db in try Repo.fetchOne(db, key: repo.id) }
    }
}
