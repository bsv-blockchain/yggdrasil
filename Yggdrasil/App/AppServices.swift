import Foundation

/// Lazily-built production dependency graph. Created once at app launch in
/// `AppDelegate.applicationDidFinishLaunching` and passed everywhere via singletons
/// on the AppDelegate.
///
/// Tests never construct this — they wire their own mock components.
@MainActor
final class AppServices {
    let database: YggdrasilDatabase
    let settingsStore: SettingsStore
    let authService: AuthService
    let httpClient: URLSessionHTTPClient
    let restClient: RESTClient
    let graphqlClient: GraphQLClient
    let syncService: TaskSyncService
    /// Replaceable from `applyIntervals(_:)` — Settings → General rebuilds
    /// the scheduler when the user changes the sync interval. Readers see
    /// the latest instance because lookups always go through `services`.
    private(set) var scheduler: SyncScheduler
    let agentStore: CodingAgentStore
    let sessionStore: SessionStateStore
    let tabStore: TabStore
    let hostStore: HostStore
    let hostRepoStore: HostRepoStore
    let remoteControl = RemoteSessionControl()
    let worktreeManager = WorktreeManager()
    let sessions = SessionsModel()
    let tabs: TabsModel
    let webViewPool: WebViewPool
    let tabStatus = TabStatusModel()
    let statusPoller: StatusPoller
    /// Builds worktrees off the click, one at a time per repo.
    let worktreePreparer: WorktreePreparer
    let diffEngine = DiffEngine()
    /// Snapshot of the live intervals. Mutated by `applyIntervals(_:)`.
    private(set) var intervals: IntervalSettings

    convenience init() throws {
        try self.init(database: YggdrasilDatabase.openDefault())
    }

    /// Builds the graph on `database`. Nothing is started here; tests and
    /// snapshot tooling use it with an in-memory database.
    init(database: YggdrasilDatabase) {
        self.database = database
        let settingsStore = SettingsStore(database: database)
        self.settingsStore = settingsStore
        let intervals = (try? IntervalSettings.load(from: settingsStore)) ?? .defaults
        self.intervals = intervals

        // Token sourced from `gh auth token` on first request + in-memory
        // cached. The Keychain detour is gone — ad-hoc-signed local builds
        // change signature on every rebuild, which made the OS prompt for
        // the user's password on every relaunch.
        let authService = AuthService(gh: GHCLIAuth())
        self.authService = authService

        let etags = ETagStore(database: database)
        let httpClient = URLSessionHTTPClient(session: .shared, auth: authService, etags: etags)
        self.httpClient = httpClient
        self.restClient = RESTClient(http: httpClient)
        self.graphqlClient = GraphQLClient(http: httpClient)

        let syncService = TaskSyncService(database: database, rest: self.restClient, graphql: self.graphqlClient)
        self.syncService = syncService
        self.agentStore = CodingAgentStore(database: database)
        self.sessionStore = SessionStateStore(database: database)
        self.hostStore = HostStore(database: database)
        self.hostRepoStore = HostRepoStore(database: database)
        let tabStore = TabStore(database: database)
        self.tabStore = tabStore
        let tabsModel = TabsModel(store: tabStore, database: database)
        tabsModel.reload()
        self.tabs = tabsModel
        self.webViewPool = WebViewPool(settingsStore: settingsStore)
        self.statusPoller = StatusPoller(
            database: database, tabsModel: tabsModel, model: tabStatus
        )

        // Built last: it captures the store and models above. Progress is
        // written straight to the tab row, so a preparation that finishes (or
        // fails) while you're looking elsewhere still lands.
        let manager = worktreeManager
        let hostRepos = hostRepoStore
        worktreePreparer = WorktreePreparer(
            prepare: { repo, host, branch, baseRef in
                var target = manager
                if let host {
                    target = try await Self.remoteWorktreeManager(on: host, repo: repo, hostRepos: hostRepos)
                }
                return try await target.ensure(repo: repo, branch: branch, baseRef: baseRef).path
            },
            record: { event in
                switch event {
                case let .state(tabID, state, error):
                    try? tabStore.setPreparation(id: tabID, state: state, error: error)
                    // Only the terminal states redraw. `reload()` is a blocking
                    // MainActor read — tab list, repo resolution, lazy task
                    // links, counts, agent identities — so firing it on every
                    // event meant three full reloads per tab opened.
                    if state == .ready || state == .failed {
                        Task { @MainActor in tabsModel.reload() }
                    }
                case let .path(tabID, path):
                    try? tabStore.setWorktreePath(id: tabID, path: path)
                }
            }
        )

        // Anything left mid-preparation by the last quit can never finish, and
        // Retry is only offered for failures — so mark them failed at launch
        // rather than leaving a permanently "preparing" row with no way out.
        try? tabStore.reconcileInterruptedPreparations()
        tabsModel.reload()

        // Hold a local reference so the closure can capture without going through `self`.
        // Each scheduler tick retries the sync with exponential backoff on failure
        // (1s, 2s, 4s, 8s, 16s, then give up for this tick) per spec §Phase 1.
        // After every successful sync, refresh `tabsModel` so the chrome pill's
        // pending-review count and the lazy task-link map (tasksByTabID) pick up
        // anything new — review-requests added or dismissed since the last tick.
        self.scheduler = Self.makeScheduler(
            intervalSeconds: intervals.syncSeconds,
            syncService: syncService,
            tabsModel: tabsModel
        )
    }

    /// Replace both intervals at runtime. Persists to SettingsStore, then
    /// stops + recreates the scheduler/poller with the new values. Safe to
    /// call before they were started — start() is idempotent.
    func applyIntervals(_ new: IntervalSettings) async {
        try? new.save(to: settingsStore)
        // Re-load to pick up the clamped values rather than trusting the
        // caller's potentially-out-of-range input.
        let resolved = (try? IntervalSettings.load(from: settingsStore)) ?? .defaults
        intervals = resolved

        await scheduler.stop()
        scheduler = Self.makeScheduler(
            intervalSeconds: resolved.syncSeconds,
            syncService: syncService,
            tabsModel: tabs
        )
        await scheduler.start()

        await statusPoller.stop()
        await statusPoller.start(interval: .seconds(resolved.statusProbeSeconds))
    }

    private static let defaultHostKey = "tabs.default_host_id"

    /// Where new tabs run unless the user picks otherwise: a host, or nil for
    /// this Mac. Settings → Hosts.
    var defaultHostID: Int64? {
        get { (try? settingsStore.get(forKey: Self.defaultHostKey)).flatMap { Int64($0) } }
        set { try? settingsStore.set(newValue.map(String.init) ?? "", forKey: Self.defaultHostKey) }
    }

    /// The `defaultHostID` host, when it still exists.
    var defaultHost: RemoteHost? {
        defaultHostID.flatMap { try? hostStore.get(id: $0) }
    }

    /// Worktree manager for `repo` on `host`, once the repo's single checkout
    /// there is pinned and cloned (if it was missing).
    private nonisolated static func remoteWorktreeManager(
        on host: RemoteHost, repo: Repo, hostRepos: HostRepoStore
    ) async throws -> WorktreeManager {
        let checkout = try hostRepos.pin(host: host, repo: repo)
        let site = RemoteWorktreeSite(host: host, checkoutPath: { _ in checkout })
        try await site.ensureCloned(repo)
        return remoteWorktreeManager(site: site)
    }

    /// Where a new tab's worktree will land, before any git runs: under the
    /// local clone, or under the repo's checkout on `host` (pinned here).
    func plannedWorktreePath(repo: Repo, branch: String, host: RemoteHost?) throws -> String? {
        guard let host else { return WorktreePreparer.predictedWorktreePath(repo: repo, branch: branch) }
        let checkout = try hostRepoStore.pin(host: host, repo: repo)
        return WorktreePreparer.predictedWorktreePath(checkout: checkout, branch: branch)
    }

    /// Manager for worktrees under an existing checkout on `host`; never clones.
    func existingWorktreeManager(on host: RemoteHost, repo: Repo) throws -> WorktreeManager {
        let checkout = try hostRepoStore.checkoutPath(host: host, repo: repo)
        return Self.remoteWorktreeManager(site: RemoteWorktreeSite(host: host, checkoutPath: { _ in checkout }))
    }

    private nonisolated static func remoteWorktreeManager(site: RemoteWorktreeSite) -> WorktreeManager {
        WorktreeManager(git: GitRunner(runner: site.runner, gitExecutable: "git"), site: site)
    }

    /// ssh host `tab` runs on, or nil for a local tab.
    func host(for tab: YggdrasilTab) -> RemoteHost? {
        guard let hostID = tab.hostID else { return nil }
        do {
            return try hostStore.get(id: hostID)
        } catch {
            YggdrasilLog.ui.error("Host lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `applicationDidFinishLaunching` calls this in place of the bare
    /// `scheduler.start()` + `statusPoller.start()` so the poller actually
    /// gets the user's chosen probe interval (not the StatusPoller
    /// default of 5s).
    func startSchedulers() async {
        await scheduler.start()
        await statusPoller.start(interval: .seconds(intervals.statusProbeSeconds))
    }

    /// Fire-and-forget GitHub sync + tabs reload — call after any user
    /// action that mutates tab state (open new session, close tab, open
    /// from picker, etc). Without this the pending-review pill / CI status
    /// / unread-comment counts lag by up to one scheduler tick (default
    /// 60s); with this they refresh in the round-trip time of one
    /// `fullSync()` (~1–3s typically).
    ///
    /// Errors are logged but not propagated — the visible side-effect is
    /// just "the pill takes a moment longer to settle". Safe to call
    /// repeatedly; concurrent syncs are bounded by the API and tolerated.
    func triggerSyncNow() {
        Task { [syncService, tabs] in
            do {
                try await syncService.fullSync()
            } catch {
                YggdrasilLog.sync.warning(
                    "triggerSyncNow fullSync failed: \(String(describing: error), privacy: .public)"
                )
            }
            await MainActor.run { tabs.reload() }
        }
    }

    private static func makeScheduler(
        intervalSeconds: Int,
        syncService: TaskSyncService,
        tabsModel: TabsModel
    ) -> SyncScheduler {
        SyncScheduler(interval: .seconds(intervalSeconds)) { [syncService, tabsModel] in
            // Each scheduler tick retries the sync with exponential backoff
            // on failure (1s, 2s, 4s, 8s, 16s, then give up for this tick)
            // per spec §Phase 1. After every successful sync, refresh
            // `tabsModel` so the chrome pill's pending-review count and the
            // lazy task-link map (tasksByTabID) pick up anything new —
            // review-requests added or dismissed since the last tick.
            try await BackoffRetry.attempt(maxAttempts: 5) {
                try await syncService.fullSync()
            }
            await MainActor.run { tabsModel.reload() }
        }
    }
}
