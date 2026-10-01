import XCTest
@testable import Yggdrasil

/// Worktree creation moved off the click and into the background.
///
/// The click used to run `git fetch` of a PR head while holding the repo's
/// worktree lock, so opening several PRs at once left the later ones waiting on
/// that lock until they hit its 30s timeout. Preparations now queue in-process,
/// one at a time per repo, which means the lock is never contended and nothing
/// is racing a timeout while the user watches.
final class WorktreePreparerTests: XCTestCase {
    private func repo(id: Int64, name: String = "teranode") -> Repo {
        Repo(
            id: id, owner: "bsv-blockchain", name: name,
            defaultBranch: "main", localMainPath: "/repos/\(name)",
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Predicting the path

    /// The tab is inserted before git runs, so it needs a path up front. It is
    /// deterministic, which is the whole reason this works without making
    /// `worktree_path` nullable.
    func testPredictsTheWorktreePath() {
        XCTAssertEqual(
            WorktreePreparer.predictedWorktreePath(repo: repo(id: 1), branch: "claude-review-pr-7"),
            "/repos/teranode/.worktrees/claude-review-pr-7"
        )
    }

    /// Slashes in a branch become dashes on disk, same as WorktreeManager.
    func testPredictedPathSlugsTheBranch() {
        XCTAssertEqual(
            WorktreePreparer.predictedWorktreePath(repo: repo(id: 1), branch: "claude-fix/the-thing"),
            "/repos/teranode/.worktrees/claude-fix-the-thing"
        )
    }

    func testPredictedPathIsNilWithoutALocalClone() {
        var bare = repo(id: 1)
        bare.localMainPath = nil
        XCTAssertNil(WorktreePreparer.predictedWorktreePath(repo: bare, branch: "x"))
    }

    // MARK: - Running the work

    func testSuccessMarksTheTabReadyAtTheRealPath() async {
        let recorder = Recorder()
        let preparer = WorktreePreparer(
            prepare: { _, _, _ in "/repos/teranode/.worktrees/actual" },
            record: recorder.record
        )
        await preparer.prepare(tabID: 1, repo: repo(id: 1), branch: "b", baseRef: nil)

        let events = recorder.events
        XCTAssertEqual(events, [
            .state(1, .preparing, nil),
            .path(1, "/repos/teranode/.worktrees/actual"),
            .state(1, .ready, nil)
        ])
    }

    /// A failure has to land somewhere the user can see it. Before this, the
    /// error went into a popup they had probably already closed.
    func testFailureRecordsTheErrorOnTheTab() async {
        let recorder = Recorder()
        let preparer = WorktreePreparer(
            prepare: { _, _, _ in throw WorktreeError.unknownRef("origin/nope") },
            record: recorder.record
        )
        await preparer.prepare(tabID: 2, repo: repo(id: 1), branch: "b", baseRef: nil)

        let events = recorder.events
        XCTAssertEqual(events.first, .state(2, .preparing, nil))
        guard case let .state(id, state, error) = events.last else { return XCTFail("no terminal state") }
        XCTAssertEqual(id, 2)
        XCTAssertEqual(state, .failed)
        XCTAssertNotNil(error)
    }

    /// The point of the whole change: two tabs in the same repo must not run
    /// their git work at the same time, because that is what fought over the
    /// lock.
    func testWorkInOneRepoIsSerialised() async {
        let tracker = ConcurrencyTracker()
        let recorder = Recorder()
        let preparer = WorktreePreparer(
            prepare: { _, _, _ in
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(20))
                await tracker.leave()
                return "/p"
            },
            record: recorder.record
        )

        await preparer.enqueue(tabID: 1, repo: repo(id: 1), branch: "a", baseRef: nil)
        await preparer.enqueue(tabID: 2, repo: repo(id: 1), branch: "b", baseRef: nil)
        await preparer.enqueue(tabID: 3, repo: repo(id: 1), branch: "c", baseRef: nil)
        await preparer.drain()

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "two preparations in one repo overlapped")
        let readied = recorder.events.filter { if case .state(_, .ready, _) = $0 { true } else { false } }
        XCTAssertEqual(readied.count, 3, "all three still completed")
    }

    /// Different repos have different locks, so they have no reason to wait for
    /// each other.
    func testWorkInDifferentReposRunsConcurrently() async {
        let tracker = ConcurrencyTracker()
        let preparer = WorktreePreparer(
            prepare: { _, _, _ in
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(30))
                await tracker.leave()
                return "/p"
            },
            record: { _ in }
        )

        await preparer.enqueue(tabID: 1, repo: repo(id: 1, name: "teranode"), branch: "a", baseRef: nil)
        await preparer.enqueue(tabID: 2, repo: repo(id: 2, name: "syn"), branch: "b", baseRef: nil)
        await preparer.drain()

        let peak = await tracker.peak
        XCTAssertEqual(peak, 2)
    }
}

private enum PreparationEvent: Equatable {
    case state(Int64, YggdrasilTab.PreparationState, String?)
    case path(Int64, String)
}

/// Lock rather than an actor: `record` has to be synchronous so events land in
/// order, instead of racing whatever the assertion sees.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PreparationEvent] = []

    var events: [PreparationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: WorktreePreparer.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .state(id, state, error): storage.append(.state(id, state, error))
        case let .path(id, path): storage.append(.path(id, path))
        }
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
