import Foundation

/// Builds a tab's worktree in the background, one tab at a time per repo.
///
/// Opening a task used to create the worktree and *then* insert the tab, so the
/// click blocked on `git fetch` of a PR head. On a large repo that is slow, and
/// `WorktreeManager` holds the repo's lock across it — so opening several PRs
/// at once left the later ones waiting on that lock until they hit its 30s
/// timeout. The picker now inserts the tab immediately and hands the git work
/// here.
///
/// Serialising per repo is what removes the contention: the lock still exists
/// for other processes, but this process no longer queues against itself, so a
/// legitimately slow fetch can take as long as it takes without anyone racing a
/// timeout. Different repos have different locks and run concurrently, and so
/// does the same repo on another host, which is a different checkout.
actor WorktreePreparer {
    /// Reported as the work progresses. The caller decides how to persist it,
    /// which keeps this type free of the store and the UI.
    enum Event {
        case state(Int64, YggdrasilTab.PreparationState, String?)
        case path(Int64, String)
    }

    /// Returns the worktree's real path on disk (on `host`, when not nil).
    typealias Prepare = @Sendable (Repo, RemoteHost?, String, String?) async throws -> String
    typealias Record = @Sendable (Event) -> Void

    private let prepareWorktree: Prepare
    private let record: Record
    /// One checkout: a repo on this Mac (host nil) or on a host.
    private struct QueueKey: Hashable {
        let hostID: Int64?
        let repoID: Int64
    }

    /// Tail of the chain per checkout; new work awaits it before starting.
    private var queues: [QueueKey: Task<Void, Never>] = [:]
    /// Tabs whose preparation has been called off — closing a tab mid-prep
    /// would otherwise still create the worktree and branch it asked to be rid
    /// of, leaving them on disk with no tab referencing them.
    private var cancelled: Set<Int64> = []

    init(prepare: @escaping Prepare, record: @escaping Record) {
        prepareWorktree = prepare
        self.record = record
    }

    /// Where the worktree will land, derived without touching git so the tab
    /// can be inserted before any of this runs. Matches `WorktreeManager`'s
    /// layout; the real path is written back afterwards, because an existing
    /// worktree on the legacy layout can live elsewhere.
    static func predictedWorktreePath(repo: Repo, branch: String) -> String? {
        guard let main = repo.localMainPath else { return nil }
        return predictedWorktreePath(checkout: main, branch: branch)
    }

    /// Same layout under any checkout, e.g. the repo's pinned one on a host.
    static func predictedWorktreePath(checkout: String, branch: String) -> String {
        "\(checkout)/.worktrees/\(BranchSlug.slug(for: branch))"
    }

    /// Queue the work behind anything already pending for this repo.
    func enqueue(tabID: Int64, repo: Repo, host: RemoteHost? = nil, branch: String, baseRef: String?) {
        guard let repoID = repo.id else {
            record(.state(tabID, .failed, "Repo is not tracked locally"))
            return
        }
        cancelled.remove(tabID)
        let key = QueueKey(hostID: host?.id, repoID: repoID)
        let previous = queues[key]
        queues[key] = Task { [weak self] in
            await previous?.value
            await self?.prepare(tabID: tabID, repo: repo, host: host, branch: branch, baseRef: baseRef)
        }
    }

    /// Run one preparation. Separate from `enqueue` so the work itself is
    /// directly testable without the queueing.
    /// Call off a queued or running preparation. The git work itself has no
    /// cancellation points, so this is checked at the boundary — enough to stop
    /// work that hasn't started, which is the case that matters when a user
    /// closes a tab they just opened.
    func cancel(tabID: Int64) {
        cancelled.insert(tabID)
    }

    func prepare(tabID: Int64, repo: Repo, host: RemoteHost? = nil, branch: String, baseRef: String?) async {
        guard !cancelled.contains(tabID) else {
            cancelled.remove(tabID)
            return
        }
        record(.state(tabID, .preparing, nil))
        do {
            let path = try await prepareWorktree(repo, host, branch, baseRef)
            record(.path(tabID, path))
            record(.state(tabID, .ready, nil))
        } catch {
            record(.state(tabID, .failed, String(describing: error)))
        }
    }

    /// Wait for everything queued at the moment of the call. Not a barrier:
    /// work enqueued while this awaits is not covered. Used by the tests.
    func drain() async {
        for task in queues.values {
            await task.value
        }
    }
}
