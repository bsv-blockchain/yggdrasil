import Foundation

/// Lazily-built production dependency graph. Created once at app launch in
/// `AppDelegate.applicationDidFinishLaunching` and passed everywhere via singletons
/// on the AppDelegate.
///
/// Tests never construct this — they wire their own mock components.
@MainActor
final class AppServices {
    let database: YggdrasilDatabase
    let authService: AuthService
    let httpClient: URLSessionHTTPClient
    let restClient: RESTClient
    let graphqlClient: GraphQLClient
    let syncService: TaskSyncService
    let scheduler: SyncScheduler
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

    init() throws {
        let database = try YggdrasilDatabase.openDefault()
        self.database = database

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
        let tabStore = TabStore(database: database)
        self.tabStore = tabStore
        let tabsModel = TabsModel(store: tabStore, database: database)
        tabsModel.reload()
        self.tabs = tabsModel
        self.webViewPool = WebViewPool(settingsStore: SettingsStore(database: database))
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
        self.scheduler = SyncScheduler(interval: .seconds(60)) { [syncService, tabsModel] in
            try await BackoffRetry.attempt(maxAttempts: 5) {
                try await syncService.fullSync()
            }
            await MainActor.run { tabsModel.reload() }
        }
    }
}
