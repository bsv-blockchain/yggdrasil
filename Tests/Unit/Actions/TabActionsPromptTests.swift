import GRDB
import XCTest
@testable import Yggdrasil

/// A new review or issue tab starts its Claude with the user's template; the
/// prompt waits in `SessionsModel` until the agent's first start.
@MainActor
final class TabActionsPromptTests: XCTestCase {
    private var services: AppServices!
    private var root: URL!

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-prompts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await services.worktreePreparer.drain()
        try? FileManager.default.removeItem(at: root)
        services = nil
    }

    // MARK: - Pickers and My Issues

    func testAReviewRequestStartsWithTheReviewTemplate() async throws {
        let repo = try addRepo()
        let task = try addTask(repo: repo, type: .pullRequest, number: 12)
        let tabID = try await TabActions.openTask(
            task,
            repo: repo,
            mode: .review,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: tabID), "/cr 12")
    }

    func testAnAssignedIssueStartsWithTheIssueTemplate() async throws {
        let repo = try addRepo()
        let task = try addTask(repo: repo, type: .issue, number: 5)
        let tabID = try await TabActions.openTask(
            task,
            repo: repo,
            mode: .assigned,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: tabID), "/fix-issue 5")
    }

    func testYourOwnPRGetsNoPrompt() async throws {
        let repo = try addRepo()
        let task = try addTask(repo: repo, type: .pullRequest, number: 12)
        let tabID = try await TabActions.openTask(
            task,
            repo: repo,
            mode: .assigned,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertNil(services.sessions.takePrompt(tabID: tabID))
    }

    func testAnIssueFromMyIssuesStartsWithTheIssueTemplate() async throws {
        let repo = try addRepo()
        try services.settingsStore.set("/fix-issue {url}", forKey: StartingPrompt.settingKey(.issue))
        let tabID = try await TabActions.openIssue(
            number: 7, title: "Bug", url: "https://github.com/acme/widget/issues/7",
            repo: repo, host: nil, agent: claude(), services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: tabID), "/fix-issue https://github.com/acme/widget/issues/7")
    }

    // MARK: - Settings

    func testAnEmptyGlobalTemplateTurnsItOff() async throws {
        let repo = try addRepo()
        try services.settingsStore.set("", forKey: StartingPrompt.settingKey(.review))
        let task = try addTask(repo: repo, type: .pullRequest, number: 12)
        let tabID = try await TabActions.openTask(
            task,
            repo: repo,
            mode: .review,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertNil(services.sessions.takePrompt(tabID: tabID))
    }

    func testTheReposOverrideWinsAndCanTurnItOff() async throws {
        var repo = try addRepo()
        try RepoActions.setStartingPrompt(
            repoID: XCTUnwrap(repo.id),
            kind: .review,
            template: "/deep-review {number}",
            services: services
        )
        try RepoActions.setStartingPrompt(
            repoID: XCTUnwrap(repo.id),
            kind: .issue,
            template: "",
            services: services
        )
        repo = try XCTUnwrap(try fetchRepo(XCTUnwrap(repo.id)))
        XCTAssertEqual(repo.reviewPrompt, "/deep-review {number}")
        XCTAssertEqual(repo.issuePrompt, "")

        let pull = try addTask(repo: repo, type: .pullRequest, number: 12)
        let reviewTab = try await TabActions.openTask(
            pull,
            repo: repo,
            mode: .review,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: reviewTab), "/deep-review 12")
        let issue = try addTask(repo: repo, type: .issue, number: 5)
        let issueTab = try await TabActions.openTask(
            issue,
            repo: repo,
            mode: .assigned,
            host: nil,
            agent: claude(),
            services: services
        )
        XCTAssertNil(services.sessions.takePrompt(tabID: issueTab))

        try RepoActions.setStartingPrompt(
            repoID: XCTUnwrap(repo.id),
            kind: .review,
            template: nil,
            services: services
        )
        let back = try XCTUnwrap(try fetchRepo(XCTUnwrap(repo.id)))
        XCTAssertNil(back.reviewPrompt, "back to the global one")
    }

    // MARK: - Choices and agents

    func testAnExplicitPromptOrNoneReplacesTheTemplate() async throws {
        let repo = try addRepo()
        let first = try addTask(repo: repo, type: .pullRequest, number: 12)
        let custom = try await TabActions.openTask(
            first, repo: repo, mode: .review, host: nil, agent: claude(), prompt: .custom("look around"),
            services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: custom), "look around")
        let second = try addTask(repo: repo, type: .pullRequest, number: 13)
        let none = try await TabActions.openTask(
            second, repo: repo, mode: .review, host: nil, agent: claude(), prompt: .none, services: services
        )
        XCTAssertNil(services.sessions.takePrompt(tabID: none))
    }

    func testAnotherAgentSkipsTheTemplateButRefusesAnExplicitPrompt() async throws {
        let repo = try addRepo()
        let codex = try services.agentStore.add(name: "Codex", command: "codex", args: [])
        let first = try addTask(repo: repo, type: .pullRequest, number: 12)
        let tabID = try await TabActions.openTask(
            first,
            repo: repo,
            mode: .review,
            host: nil,
            agent: codex,
            services: services
        )
        XCTAssertNil(services.sessions.takePrompt(tabID: tabID))
        let second = try addTask(repo: repo, type: .pullRequest, number: 13)
        do {
            _ = try await TabActions.openTask(
                second, repo: repo, mode: .review, host: nil, agent: codex, prompt: .custom("go"), services: services
            )
            XCTFail("expected promptNeedsClaude")
        } catch {
            XCTAssertEqual(error as? ActionError, .promptNeedsClaude)
        }
    }

    // MARK: - New Session and tab.open

    func testOpenClassifiesThePROrIssueTheBranchNames() async throws {
        let repo = try addRepo()
        let requested = try addTask(repo: repo, type: .pullRequest, number: 12)
        try markReviewRequested(requested)
        let mine = try addTask(repo: repo, type: .pullRequest, number: 13)
        try markAuthored(mine)
        let requestedPrompt = try await openPrompt(repo, "pr-12")
        let minePrompt = try await openPrompt(repo, "pr-13")
        let unsyncedPrompt = try await openPrompt(repo, "pr-14")
        let issuePrompt = try await openPrompt(repo, "issue-5")
        let plainPrompt = try await openPrompt(repo, "feature")
        XCTAssertEqual(requestedPrompt, "/cr 12", "review requested")
        XCTAssertNil(minePrompt, "your own PR")
        XCTAssertNil(unsyncedPrompt, "not synced: can't tell whose it is")
        XCTAssertEqual(issuePrompt, "/fix-issue 5", "an issue needs no lookup")
        XCTAssertNil(plainPrompt, "a plain branch")
    }

    func testAPRAssignedToYouThatSomeoneElseWroteIsOneToReview() async throws {
        // As Review Requests lists it, on every path: tab.open, and
        // openTask even when it isn't in the list (it already has a tab).
        let repo = try addRepo()
        let assigned = try addTask(repo: repo, type: .pullRequest, number: 20)
        try markAssigned(assigned)
        let opened = try await openPrompt(repo, "pr-20")
        XCTAssertEqual(opened, "/cr 20")
        let again = try await TabActions.openTask(
            assigned, repo: repo, mode: .assigned, host: nil, agent: claude(), services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: again), "/cr 20")
    }

    func testYourOwnPRYouWereAskedToReviewIsOneToReview() async throws {
        // Review Requests lists it, so it starts like the others there.
        let repo = try addRepo()
        let both = try addTask(repo: repo, type: .pullRequest, number: 21)
        try markAuthored(both)
        try markReviewRequested(both)
        let opened = try await openPrompt(repo, "pr-21")
        XCTAssertEqual(opened, "/cr 21")
    }

    func testTheSheetSuggestsTheTemplateForAnyPRButYourOwn() throws {
        let repo = try addRepo()
        let mine = try addTask(repo: repo, type: .pullRequest, number: 13)
        try markAuthored(mine)
        func suggestion(_ input: String) throws -> String {
            try TabActions.suggestedPrompt(branchInput: input, repo: repo, agent: claude(), services: services)
        }
        XCTAssertEqual(try suggestion("pr-14"), "/cr 14", "visible and editable, so an unsynced PR counts")
        XCTAssertEqual(try suggestion("https://github.com/acme/widget/pull/15"), "/cr 15")
        XCTAssertEqual(try suggestion("issue-5"), "/fix-issue 5")
        XCTAssertEqual(try suggestion("pr-13"), "")
        XCTAssertEqual(try suggestion("feature"), "")
        let codex = try services.agentStore.add(name: "Codex", command: "codex", args: [])
        XCTAssertEqual(
            try TabActions.suggestedPrompt(branchInput: "pr-14", repo: repo, agent: codex, services: services),
            ""
        )
    }

    // MARK: - Helpers

    private func openPrompt(_ repo: Repo, _ branch: String) async throws -> String? {
        let tabID = try await TabActions.open(
            .init(repo: repo, branchInput: branch, baseBranch: nil, host: nil, agent: claude(), select: false),
            services: services
        )
        return services.sessions.takePrompt(tabID: tabID)
    }

    private func fetchRepo(_ id: Int64) throws -> Repo? {
        try services.database.queue.read { db in try Repo.fetchOne(db, key: id) }
    }

    private func claude() throws -> CodingAgent {
        try XCTUnwrap(services.agentStore.getDefault())
    }

    private func addRepo() throws -> Repo {
        let repo = try services.database.queue.write { db -> Repo in
            var repo = Repo(
                id: nil, owner: "acme", name: "widget", defaultBranch: "main",
                localMainPath: root.appendingPathComponent("widget").path, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
        services.tabs.reload()
        return repo
    }

    private func addTask(repo: Repo, type: YggdrasilTask.Kind, number: Int) throws -> YggdrasilTask {
        try services.database.queue.write { db in
            var task = YggdrasilTask(
                id: nil, repoID: repo.id!, type: type, number: number,
                title: "T\(number)", body: nil, state: .open, authorLogin: "someone",
                githubURL: "https://github.com/acme/widget/\(type == .issue ? "issues" : "pull")/\(number)", apiURL: "",
                createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(),
                etag: nil, labelsJSON: "[]", milestoneTitle: nil
            )
            try task.insert(db)
            return task
        }
    }

    private func markReviewRequested(_ task: YggdrasilTask) throws {
        try services.database.queue.write { db in
            try PRReviewRequest(taskID: task.id!, requestedAt: Date()).insert(db)
        }
    }

    private func markAssigned(_ task: YggdrasilTask) throws {
        try services.database.queue.write { db in
            try PRAssigned(taskID: task.id!, recordedAt: Date()).insert(db)
        }
    }

    private func markAuthored(_ task: YggdrasilTask) throws {
        try services.database.queue.write { db in
            try PRAuthored(taskID: task.id!, recordedAt: Date()).insert(db)
        }
    }
}
