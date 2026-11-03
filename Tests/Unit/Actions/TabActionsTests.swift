import GRDB
import XCTest
@testable import Yggdrasil

// swiftlint:disable type_body_length

/// The tab actions the sidebar, menus and pickers share, without their
/// dialogs. Runs against an in-memory database; GitHub syncs are counted, not
/// run, and every UserDefaults write goes to a throwaway suite.
@MainActor
final class TabActionsTests: XCTestCase {
    private var services: AppServices!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var syncRequests = 0

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        syncRequests = 0
        services.requestSync = { [unowned self] in syncRequests += 1 }
        suiteName = "TabActionsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Let the background worktree builds finish before their folder goes.
        await services.worktreePreparer.drain()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        services = nil
    }

    // MARK: - Branch planning

    func testFreeFormBranchGetsTheAgentPrefixAndTheTypedBase() {
        let plan = TabActions.plan(branchInput: "feat/x", agentName: "Claude", baseBranch: " main ")
        XCTAssertEqual(plan.branch, "claude-feat/x")
        XCTAssertEqual(plan.baseRef, "main")
    }

    func testPRBranchKeepsItsNameAndStartsFromThePRHead() {
        let plan = TabActions.plan(
            branchInput: "https://github.com/acme/widget/pull/12", agentName: "Claude", baseBranch: "main"
        )
        XCTAssertEqual(plan.branch, "pr-12")
        XCTAssertEqual(plan.baseRef, "refs/pull/12/head")
        XCTAssertEqual(plan.repoSlug, "acme/widget")
    }

    func testIssueBranchKeepsItsNameAndUsesTheTypedBase() {
        let plan = TabActions.plan(branchInput: "issue-7", agentName: "Claude", baseBranch: "")
        XCTAssertEqual(plan.branch, "issue-7")
        XCTAssertNil(plan.baseRef)
    }

    func testBranchAlreadyCarryingTheAgentPrefixIsNotPrefixedTwice() {
        XCTAssertEqual(
            TabActions.plan(branchInput: "claude-x", agentName: "Claude", baseBranch: nil).branch,
            "claude-x"
        )
    }

    // MARK: - Open

    func testOpenInsertsATabLinkedToTheSyncedTaskAndSelectsIt() async throws {
        let repo = try addRepo()
        let taskID = try addTask(repo: repo, type: .pullRequest, number: 12)
        let tabID = try await TabActions.open(
            .init(repo: repo, branchInput: "pr-12", baseBranch: nil, host: nil, agent: defaultAgent()),
            services: services
        )
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(tab.branchName, "pr-12")
        XCTAssertEqual(tab.taskID, taskID)
        XCTAssertNil(tab.hostID)
        XCTAssertEqual(tab.worktreePath, try "\(XCTUnwrap(repo.localMainPath))/.worktrees/pr-12")
        XCTAssertEqual(services.tabs.selectedID, tabID)
        XCTAssertEqual(syncRequests, 1)
    }

    func testOpenWithoutSelectLeavesTheSelectionAlone() async throws {
        let repo = try addRepo()
        let first = try await TabActions.open(
            .init(repo: repo, branchInput: "a", baseBranch: nil, host: nil, agent: defaultAgent()), services: services
        )
        let second = try await TabActions.open(
            .init(repo: repo, branchInput: "b", baseBranch: nil, host: nil, agent: defaultAgent(), select: false),
            services: services
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(services.tabs.selectedID, first)
    }

    func testOpenOnThisMacNeedsALocalClone() async throws {
        let repo = try addRepo(localPath: nil)
        do {
            _ = try await TabActions.open(
                .init(repo: repo, branchInput: "a", baseBranch: nil, host: nil, agent: defaultAgent()),
                services: services
            )
            XCTFail("expected repoNotCloned")
        } catch {
            XCTAssertEqual(error as? ActionError, .repoNotCloned("acme/widget"))
        }
        XCTAssertTrue(services.tabs.tabs.isEmpty)
    }

    func testOpenTaskUsesThePickerBranchAndLinksTheTask() async throws {
        let repo = try addRepo()
        let taskID = try addTask(repo: repo, type: .pullRequest, number: 12)
        let fetched = try await services.database.queue.read { db in try YggdrasilTask.fetchOne(db, key: taskID) }
        let task = try XCTUnwrap(fetched)
        let tabID = try await TabActions.openTask(
            task, repo: repo, mode: .review, host: nil, agent: defaultAgent(), services: services
        )
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(tab.branchName, "claude-review-pr-12")
        XCTAssertEqual(tab.taskID, taskID)
    }

    func testOpenIssueFromMyIssuesLeavesTheTaskUnlinked() async throws {
        let repo = try addRepo()
        let tabID = try await TabActions.openIssue(
            number: 7, title: "Bug", url: "https://github.com/acme/widget/issues/7",
            repo: repo, host: nil, agent: defaultAgent(), services: services
        )
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(tab.branchName, "claude-issue-7")
        XCTAssertNil(tab.taskID)
    }

    // MARK: - Close

    func testCloseDropsTheRowItsReviewRequestAndItsMute() async throws {
        let repo = try addRepo()
        let taskID = try addTask(repo: repo, type: .pullRequest, number: 12)
        try await services.database.queue.write { db in
            try db.execute(
                sql: "INSERT INTO pr_review_request (task_id, requested_at) VALUES (?, ?)", arguments: [taskID, Date()]
            )
        }
        let tabID = try addTab(branch: "review-pr-12", path: "\(repo.localMainPath!)/.worktrees/x", taskID: taskID)
        AttentionDismissal.dismiss(tabID: tabID, signature: "sig", defaults: defaults)

        let problems = try await TabActions.close(
            id: tabID,
            deleteWorktree: false,
            services: services,
            defaults: defaults
        )

        XCTAssertEqual(problems, [])
        XCTAssertNil(try services.tabStore.get(id: tabID))
        XCTAssertNil(AttentionDismissal.dismissedSignature(tabID: tabID, defaults: defaults))
        let requests = try await services.database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pr_review_request") ?? -1
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(syncRequests, 1)
    }

    func testCloseWithWorktreeRemovesItWithGit() async throws {
        let main = try await makeClone()
        let repo = try addRepo(localPath: main.path)
        let worktree = main.appendingPathComponent(".worktrees/feat")
        try await git(["worktree", "add", "-q", "-b", "feat", worktree.path], in: main)
        let tabID = try addTab(branch: "feat", path: worktree.path)
        XCTAssertNotNil(services.tabs.repoByTabID[tabID]?.id, "the tab must resolve to \(repo.fullName)")

        let problems = try await TabActions.close(
            id: tabID,
            deleteWorktree: true,
            services: services,
            defaults: defaults
        )

        XCTAssertEqual(problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testOpenAdHocStartsAnAgentInTheFolder() throws {
        let tabID = try TabActions.openAdHoc(path: root.path, agent: defaultAgent(), services: services)
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(tab.branchName, "ad-hoc")
        XCTAssertEqual(tab.worktreePath, root.path)
        XCTAssertEqual(services.sessions.sessions.first(where: { $0.id == tabID })?.cwd, root.path)
        XCTAssertEqual(services.tabs.selectedID, tabID)
    }

    func testClosingAWorktreeOutsideATrackedRepoSaysItWasLeft() async throws {
        let tabID = try addTab(branch: "x", path: root.appendingPathComponent("loose").path)
        let problems = try await TabActions.close(
            id: tabID,
            deleteWorktree: true,
            services: services,
            defaults: defaults
        )
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("left in place"), problems[0])
        XCTAssertNil(try services.tabStore.get(id: tabID))
    }

    func testClosingAnUnknownTabThrows() async {
        do {
            _ = try await TabActions.close(id: 999, deleteWorktree: false, services: services, defaults: defaults)
            XCTFail("expected unknownTab")
        } catch {
            XCTAssertEqual(error as? ActionError, .unknownTab(999))
        }
    }

    // MARK: - Attention, setup, links, order

    func testMuteBeforeTheFirstStatusIsRefused() throws {
        let tabID = try addTab(branch: "x", path: "/x")
        XCTAssertThrowsError(try TabActions.mute(tabID: tabID, services: services, defaults: defaults)) { error in
            XCTAssertEqual(error as? ActionError, .noStatusYet)
        }
    }

    func testMuteStoresTheCurrentSignatureAndUnmuteDropsIt() throws {
        let tabID = try addTab(branch: "x", path: "/x")
        services.tabStatus.set(
            TabStatus(icon: .awaitingInput, showsUnreadBadgeDot: false, tooltipLines: [], attentionSignature: "s1"),
            forTabID: tabID
        )
        try TabActions.mute(tabID: tabID, services: services, defaults: defaults)
        XCTAssertEqual(AttentionDismissal.dismissedSignature(tabID: tabID, defaults: defaults), "s1")
        try TabActions.unmute(tabID: tabID, services: services, defaults: defaults)
        XCTAssertNil(AttentionDismissal.dismissedSignature(tabID: tabID, defaults: defaults))
    }

    func testRetrySetupOutsideATrackedRepoIsRefused() throws {
        let tabID = try addTab(branch: "x", path: "/nowhere/x")
        XCTAssertThrowsError(try TabActions.retrySetup(tabID: tabID, services: services)) { error in
            XCTAssertEqual(error as? ActionError, .notInTrackedRepo)
        }
    }

    func testLinkingAPROutsideATrackedRepoIsRefused() async throws {
        let tabID = try addTab(branch: "x", path: "/nowhere/x")
        do {
            try await TabActions.linkPR(tabID: tabID, number: 3, services: services)
            XCTFail("expected notInTrackedRepo")
        } catch {
            XCTAssertEqual(error as? ActionError, .notInTrackedRepo)
        }
    }

    func testUnlinkDropsAnIssueTabsPRFirst() throws {
        let repo = try addRepo()
        let issue = try addTask(repo: repo, type: .issue, number: 1)
        let pullRequest = try addTask(repo: repo, type: .pullRequest, number: 2)
        let tabID = try addTab(branch: "issue-1", path: "/x", taskID: issue)
        try services.tabStore.setPRTaskID(id: tabID, prTaskID: pullRequest)
        try TabActions.unlinkPR(tabID: tabID, services: services)
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(tab.taskID, issue)
        XCTAssertNil(tab.prTaskID)
    }

    func testReorderMovesATabToTheGivenPosition() throws {
        let first = try addTab(branch: "a", path: "/a")
        let second = try addTab(branch: "b", path: "/b")
        let third = try addTab(branch: "c", path: "/c")
        try TabActions.reorder(tabID: third, to: 0, services: services)
        XCTAssertEqual(services.tabs.tabs.compactMap(\.id), [third, first, second])
        services.tabs.reload()
        XCTAssertEqual(services.tabs.tabs.compactMap(\.id), [third, first, second], "the order is persisted")
    }

    func testSelectChangesTheSelection() throws {
        _ = try addTab(branch: "a", path: "/a")
        let second = try addTab(branch: "b", path: "/b")
        try TabActions.select(tabID: second, services: services)
        XCTAssertEqual(services.tabs.selectedID, second)
    }

    // MARK: - Pane layout and diff scope

    func testSetLayoutPersistsItAndTellsTheMountedPane() throws {
        let tabID = try addTab(branch: "a", path: "/a")
        let note = expectation(forNotification: PaneLayout.changedNotification, object: tabID)
        try TabActions.setLayout(tabID: tabID, layout: "github", services: services, defaults: defaults)
        wait(for: [note], timeout: 1)
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(PaneLayout.load(for: tab, defaults: defaults), .solo(.github))
    }

    func testAnUnknownLayoutIsRefused() throws {
        let tabID = try addTab(branch: "a", path: "/a")
        XCTAssertThrowsError(try TabActions.setLayout(tabID: tabID, layout: "sideways", services: services)) { error in
            XCTAssertEqual(error as? ActionError, .invalidArgument("layout"))
        }
    }

    func testSetDiffScopePersistsItAndTellsTheMountedDiff() throws {
        let tabID = try addTab(branch: "a", path: "/a")
        let note = expectation(forNotification: DiffSubPane.scopeChangedNotification, object: tabID)
        try TabActions.setDiffScope(tabID: tabID, scope: "uncommitted", services: services, defaults: defaults)
        wait(for: [note], timeout: 1)
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        XCTAssertEqual(DiffSubPane.Coordinator.loadScope(for: tab, defaults: defaults), .uncommitted)
    }

    // MARK: - Helpers

    private func makeClone() async throws -> URL {
        let main = root.appendingPathComponent("widget")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: main)
        try await git(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"],
            in: main
        )
        return main
    }

    private func git(_ args: [String], in dir: URL) async throws {
        let result = try await GitRunner().run(args: args, cwd: dir)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private func defaultAgent() throws -> CodingAgent {
        try XCTUnwrap(services.agentStore.getDefault())
    }

    private func addRepo(localPath: String? = "<root>") throws -> Repo {
        let path = localPath.map { $0 == "<root>" ? root.appendingPathComponent("widget").path : $0 }
        let repo = try services.database.queue.write { db -> Repo in
            var repo = Repo(
                id: nil, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: path, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
        services.tabs.reload()
        return repo
    }

    private func addTask(repo: Repo, type: YggdrasilTask.Kind, number: Int) throws -> Int64 {
        try services.database.queue.write { db in
            var task = YggdrasilTask(
                id: nil, repoID: repo.id!, type: type, number: number,
                title: "T\(number)", body: nil, state: .open, authorLogin: "someone",
                githubURL: "https://github.com/acme/widget/\(number)", apiURL: "",
                createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(),
                etag: nil, labelsJSON: "[]", milestoneTitle: nil
            )
            try task.insert(db)
            return task.id!
        }
    }

    private func addTab(branch: String, path: String, taskID: Int64? = nil) throws -> Int64 {
        let tab = try services.tabStore.insert(branchName: branch, worktreePath: path, agentID: nil, taskID: taskID)
        services.tabs.reload()
        return try XCTUnwrap(tab.id)
    }
}

// swiftlint:enable type_body_length
