import Foundation

/// Lazily-built production dependency graph. Created once at app launch in
/// `AppDelegate.applicationDidFinishLaunching` and passed everywhere via singletons
/// on the AppDelegate.
///
/// Tests never construct this — they wire their own mock components.
@MainActor
final class AppServices {
    let database: LoomDatabase
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

    init() throws {
        let database = try LoomDatabase.openDefault()
        self.database = database

        let keychain = KeychainAccessStore()
        let authService = AuthService(gh: GHCLIAuth(), keychain: keychain)
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

        // Hold a local reference so the closure can capture without going through `self`.
        // Each scheduler tick retries the sync with exponential backoff on failure
        // (1s, 2s, 4s, 8s, 16s, then give up for this tick) per spec §Phase 1.
        self.scheduler = SyncScheduler(interval: .seconds(60)) { [syncService] in
            try await BackoffRetry.attempt(maxAttempts: 5) {
                try await syncService.fullSync()
            }
        }
    }
}
