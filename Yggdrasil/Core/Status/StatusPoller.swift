import Foundation
import GRDB

/// Drives `TabStatusModel`. For each open tab, periodically probes git state,
/// reads the last-known GitHub status from the `github_status` table, and
/// aggregates into a `TabStatus` that the sidebar row reads.
///
/// Claude state detection is scaffolded but currently surfaces `.unknown` —
/// JSONL discovery + tail is a follow-up.
actor StatusPoller {
    private let database: YggdrasilDatabase
    private let probe: GitStateProbe
    private let model: TabStatusModel
    private let tabsModel: TabsModel
    private var task: Task<Void, Never>?

    init(
        database: YggdrasilDatabase,
        tabsModel: TabsModel,
        model: TabStatusModel,
        probe: GitStateProbe = GitStateProbe()
    ) {
        self.database = database
        self.tabsModel = tabsModel
        self.model = model
        self.probe = probe
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

    private func tick() async {
        let tabs = await MainActor.run { tabsModel.tabs }
        for tab in tabs {
            guard let tabID = tab.id else { continue }
            // Git side — cheap subprocess probe.
            let gitState: GitState
            do {
                gitState = try await probe.probe(worktreePath: tab.worktreePath)
            } catch {
                YggdrasilLog.sync.warning(
                    "StatusPoller git probe failed for tab \(tabID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            // GitHub side — read the last-known row from github_status.
            let github = readGitHubAggregate(tabID: tabID, taskID: tab.taskID)
            // Claude side — TODO (Phase 6.5): JSONL tail.
            let claude = ClaudeState.unknown

            let status = TabStatus.aggregate(claude: claude, git: gitState, github: github)
            await MainActor.run {
                model.set(status, forTabID: tabID)
            }
        }
    }

    private func readGitHubAggregate(tabID _: Int64, taskID: Int64?) -> GitHubAggregate {
        guard let taskID else {
            return GitHubAggregate(ciState: nil, unread: 0)
        }
        do {
            return try database.queue.read { db in
                guard let row = try GitHubStatus.fetchOne(db, key: taskID) else {
                    return GitHubAggregate(ciState: nil, unread: 0)
                }
                return GitHubAggregate(
                    ciState: row.ciState,
                    unread: row.unreadCommentsCount
                )
            }
        } catch {
            YggdrasilLog.sync.warning(
                "StatusPoller GitHub read failed: \(String(describing: error), privacy: .public)"
            )
            return GitHubAggregate(ciState: nil, unread: 0)
        }
    }
}
