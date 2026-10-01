import Foundation
import GRDB

/// Drives `TabStatusModel`. For each open tab, periodically probes git state,
/// reads the last-known GitHub status from the `github_status` table, and
/// aggregates into a `TabStatus` that the sidebar row reads.
///
/// Tabs are probed in bounded-concurrency batches rather than one after
/// another. A single git probe takes ~2.5s on a large repo, so a sequential
/// sweep of 29 tabs ran for over a minute — and until a tab's turn came round
/// it had no status at all, which is why the "Needs me" filter came up empty
/// unless you waited.
actor StatusPoller {
    /// Enough to collapse the sweep (~73s to ~12s at 29 tabs) without putting
    /// a git subprocess per tab on the machine at once.
    private static let maxConcurrentProbes = 6

    private let database: YggdrasilDatabase
    private let probe: GitStateProbe
    private let sessionProbe: AgentSessionProbe
    private let model: TabStatusModel
    private let tabsModel: TabsModel
    private var task: Task<Void, Never>?
    /// A git probe that never returns would otherwise wedge the whole poller:
    /// the batch waits for all its members and the loop waits for the batch.
    private static let probeDeadline: Duration = .seconds(20)

    /// Per-tab transcript cache, so an untouched session costs no file read.
    /// Rebuilt each tick from the live tabs, which prunes closed ones.
    private var sessionCaches: [Int64: AgentSessionProbe.Cache] = [:]
    /// Last git state that actually succeeded, per tab. A failed probe reuses
    /// it rather than publishing a fabricated clean tree, which would drop a
    /// dirty tab's icon and flicker it back on the next tick.
    private var lastGitStates: [Int64: GitState] = [:]

    init(
        database: YggdrasilDatabase,
        tabsModel: TabsModel,
        model: TabStatusModel,
        probe: GitStateProbe = GitStateProbe(),
        sessionProbe: AgentSessionProbe = AgentSessionProbe()
    ) {
        self.database = database
        self.tabsModel = tabsModel
        self.model = model
        self.probe = probe
        self.sessionProbe = sessionProbe
    }

    func start(interval: Duration = .seconds(5)) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One result per tab, computed off the actor so the batch runs in
    /// parallel.
    /// Everything one tab's probe needs, carried together rather than as six
    /// loose arguments.
    private struct ProbeInput {
        let tab: YggdrasilTab
        let tabID: Int64
        let agent: AgentIdentity
        let previousSession: AgentSessionProbe.Cache?
        let lastGitState: GitState?
    }

    private struct Probed {
        let tabID: Int64
        let status: TabStatus
        let sessionCache: AgentSessionProbe.Cache?
        /// Carried forward so the next tick can reuse it if git fails then.
        let gitState: GitState?
    }

    private func tick() async {
        let snapshot = await MainActor.run {
            (tabs: tabsModel.tabs, agents: tabsModel.agentByTabID)
        }
        var freshCaches: [Int64: AgentSessionProbe.Cache] = [:]

        var freshGitStates: [Int64: GitState] = [:]

        for start in stride(from: 0, to: snapshot.tabs.count, by: Self.maxConcurrentProbes) {
            // `stop()` cancels the outer task, but nothing below checks for it
            // — without this an `AppServices.reload()` leaves the old sweep
            // running beside the new one, doubling the git processes and
            // letting the two interleaved ticks clobber each other's caches.
            if Task.isCancelled { return }
            let batch = snapshot.tabs[start ..< min(start + Self.maxConcurrentProbes, snapshot.tabs.count)]
            let probed = await withTaskGroup(of: Probed?.self) { group in
                for tab in batch {
                    guard let tabID = tab.id else { continue }
                    // Its worktree doesn't exist yet — probing it is a
                    // guaranteed subprocess failure and a warning line, per
                    // tab per tick.
                    guard tab.isReady else { continue }
                    let agent = snapshot.agents[tabID] ?? .claude
                    let previous = sessionCaches[tabID]
                    let lastGit = lastGitStates[tabID]
                    let input = ProbeInput(
                        tab: tab, tabID: tabID, agent: agent,
                        previousSession: previous, lastGitState: lastGit
                    )
                    group.addTask { [self] in await probeTab(input) }
                }
                var results: [Probed] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }
            for result in probed {
                freshCaches[result.tabID] = result.sessionCache
                freshGitStates[result.tabID] = result.gitState
                await MainActor.run { model.set(result.status, forTabID: result.tabID) }
            }
        }
        sessionCaches = freshCaches
        lastGitStates = freshGitStates
    }

    /// `nonisolated` so a batch actually runs in parallel instead of queueing
    /// on the actor.
    private nonisolated func probeTab(_ input: ProbeInput) async -> Probed? {
        let tab = input.tab
        let tabID = input.tabID
        let agent = input.agent
        let previousSession = input.previousSession
        let lastGitState = input.lastGitState
        // A failed probe used to `continue`, leaving the tab with no status at
        // all — one transient failure hid it from the sidebar filters until a
        // later sweep happened to succeed. Reuse the last state that worked
        // instead; fabricating a clean tree would drop a dirty tab's icon and
        // flicker it back, which is a different kind of wrong.
        var gitState = lastGitState ?? GitState(dirty: false, remote: .noRemote)
        var gitSucceeded = lastGitState != nil
        do {
            let gitProbe = probe
            let path = tab.worktreePath
            gitState = try await withDeadline(Self.probeDeadline) {
                try await gitProbe.probe(worktreePath: path)
            }
            gitSucceeded = true
        } catch {
            YggdrasilLog.sync.warning(
                "StatusPoller git probe failed for tab \(tabID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }

        // Read once: a second read for the fingerprint could straddle a sync
        // write and describe state B while the amber it fingerprints came from
        // state A, making the mute lapse instantly or mute something unseen.
        let row = readGitHubRow(taskID: tab.taskID)
        let github = Self.aggregate(from: row)
        let (sample, cache) = sessionProbe.probe(
            worktreePath: tab.worktreePath, agent: agent, previous: previousSession
        )
        let claude = ClaudeStateDetector.evaluate(activity: sample, now: Date())
        let signature = AttentionSignature.make(row: row, session: sample)

        return Probed(
            tabID: tabID,
            status: TabStatus.aggregate(
                claude: claude, git: gitState, github: github,
                attentionSignature: signature
            ),
            sessionCache: cache,
            gitState: gitSucceeded ? gitState : nil
        )
    }

    /// Run `work`, giving up after `deadline`. `ProcessRunner` has no timeout
    /// and ignores cancellation, so a `git` that never exits would otherwise
    /// hang this tab's probe — and with it the batch, the tick, and every
    /// tab's status until the app restarts.
    private nonisolated func withDeadline<T: Sendable>(
        _ deadline: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw ProbeTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProbeTimeout() }
            return first
        }
    }

    private struct ProbeTimeout: Error {}

    /// The github_status row, read once per tab per tick and used for both the
    /// aggregate and the attention fingerprint.
    private nonisolated func readGitHubRow(taskID: Int64?) -> GitHubStatus? {
        guard let taskID else { return nil }
        do {
            return try database.queue.read { db in try GitHubStatus.fetchOne(db, key: taskID) }
        } catch {
            YggdrasilLog.sync.warning(
                "StatusPoller GitHub read failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    static func aggregate(from row: GitHubStatus?) -> GitHubAggregate {
        guard let row else { return GitHubAggregate(ciState: nil, unread: 0) }
        return GitHubAggregate(
            ciState: row.ciState,
            reviewState: row.reviewState,
            unread: row.newCommentsSinceSeen,
            newCommits: row.newCommitsSinceSeen,
            hasActivity: row.reviewActionOutstanding,
            reviewApproved: row.reviewApprovedByViewer,
            threadsAwaitingReply: row.authorReplyOutstanding
                ? row.unresolvedThreadsAwaitingViewer : 0,
            viewerDidAuthorPR: row.viewerDidAuthorPR
        )
    }
}
