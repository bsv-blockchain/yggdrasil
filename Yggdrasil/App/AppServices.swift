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
    /// Persistent OAuth-token store (settings-table backed). Exposed so the
    /// Account preferences pane can show signed-in state.
    let oauthStore: SettingsOAuthTokenStore
    /// Static OAuth App config (client id/secret, scopes, redirect).
    let oauthConfig: GitHubOAuthConfig
    /// Drives the ASWebAuthenticationSession login flow (passkeys work in the
    /// system sheet) and stores the resulting token in `authService`.
    let oauthLogin: GitHubOAuthLoginService
    let httpClient: URLSessionHTTPClient
    let restClient: RESTClient
    let graphqlClient: GraphQLClient
    let syncService: TaskSyncService
    /// Replaceable from `applyIntervals(_:)` — IntervalsPrefsPane rebuilds
    /// the scheduler when the user changes the sync interval. Readers see
    /// the latest instance because lookups always go through `services`.
    private(set) var scheduler: SyncScheduler
    let agentStore: CodingAgentStore
    let sessionStore: SessionStateStore
    let tabStore: TabStore
    let worktreeManager = WorktreeManager()
    let sessions = SessionsModel()
    let tabs: TabsModel
    let webViewPool: WebViewPool
    let tmux: TmuxManager
    let tabStatus = TabStatusModel()
    let statusPoller: StatusPoller
    let diffEngine = DiffEngine()
    /// Snapshot of the live intervals. Mutated by `applyIntervals(_:)`.
    private(set) var intervals: IntervalSettings

    init() throws {
        let database = try YggdrasilDatabase.openDefault()
        self.database = database
        let settingsStore = SettingsStore(database: database)
        self.settingsStore = settingsStore
        let intervals = (try? IntervalSettings.load(from: settingsStore)) ?? .defaults
        self.intervals = intervals

        // Token sourced from `gh auth token` on first request + in-memory
        // cached. The Keychain detour is gone — ad-hoc-signed local builds
        // change signature on every rebuild, which made the OS prompt for
        // the user's password on every relaunch.
        let oauthStore = SettingsOAuthTokenStore(settings: settingsStore)
        self.oauthStore = oauthStore
        // An OAuth token from the in-app passkey login (if present) takes
        // precedence over `gh auth token`; AuthService falls back to gh otherwise.
        let authService = AuthService(gh: GHCLIAuth(), oauthStore: oauthStore)
        self.authService = authService

        let oauthConfig = GitHubOAuthConfig.fromBundle()
        self.oauthConfig = oauthConfig
        self.oauthLogin = GitHubOAuthLoginService(
            config: oauthConfig,
            presenter: ASWebAuthPresenter(),
            exchanger: URLSessionTokenExchanger(session: .shared),
            authService: authService,
            makeState: { OAuthState.random() }
        )

        let etags = ETagStore(database: database)
        let httpClient = URLSessionHTTPClient(session: .shared, auth: authService, etags: etags)
        self.httpClient = httpClient
        self.restClient = RESTClient(http: httpClient)
        self.graphqlClient = GraphQLClient(http: httpClient)

        let syncService = TaskSyncService(database: database, rest: self.restClient, graphql: self.graphqlClient)
        self.syncService = syncService
        self.agentStore = CodingAgentStore(database: database)
        self.sessionStore = SessionStateStore(database: database)
        let tabStore = TabStore(database: database)
        self.tabStore = tabStore
        let tabsModel = TabsModel(store: tabStore, database: database)
        tabsModel.reload()
        self.tabs = tabsModel
        self.webViewPool = WebViewPool(settingsStore: settingsStore)
        // Probe once at launch — tmux availability is a property of the
        // user's PATH, not something that changes during a run.
        self.tmux = TmuxManager.detect()
        if self.tmux.tmuxPath == nil {
            YggdrasilLog.pty.warning(
                "tmux not found on PATH; agent sessions won't survive app close. Install via `brew install tmux`."
            )
        } else {
            YggdrasilLog.pty.info(
                "tmux available at \(self.tmux.tmuxPath ?? "?", privacy: .public); agent sessions will survive app close"
            )
        }
        self.statusPoller = StatusPoller(
            database: database, tabsModel: tabsModel, model: tabStatus
        )

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

    /// `applicationDidFinishLaunching` calls this in place of the bare
    /// `scheduler.start()` + `statusPoller.start()` so the poller actually
    /// gets the user's chosen probe interval (not the StatusPoller
    /// default of 5s).
    func startSchedulers() async {
        await scheduler.start()
        await statusPoller.start(interval: .seconds(intervals.statusProbeSeconds))
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
