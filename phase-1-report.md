# Phase 1 — GitHub Sync Engine — Report

Date: 2026-05-26
Branch: `main` (per workflow exception, see `decisions.md`)
Spec reference: `yggdrasil-spec.md` §Phase 1 (lines 254–281)

---

## 1. What was built

Five layers, ~1500 lines of production Swift behind 67 unit tests + 1 conditional integration test.

### Storage (`Yggdrasil/Core/Storage`, `Yggdrasil/Core/Models`)
- `YggdrasilDatabase` — GRDB stack. `openDefault()` for production (`~/Library/Application Support/Yggdrasil/yggdrasil.sqlite`), `inMemory()` for tests.
- `Migrations` v1: full §3.2 schema — `repo`, `task`, `task_assignee`, `github_status`, `setting`.
- 5 Codable+Record models: `Repo`, `YggdrasilTask` (renamed from `Task` to avoid collision with `_Concurrency.Task` — table stays `task`), `TaskAssignee`, `GitHubStatus`, `Setting`.
- `SettingsStore` — typed string get/set. `ETagStore` — namespaced wrapper for URL→ETag.

### Auth (`Yggdrasil/Core/Auth`)
- `SubprocessRunner` protocol + `ProcessRunner` (real) — wraps `Foundation.Process` into async/await.
- `GHCLIAuth` — invokes `gh auth token`. Returns trimmed token, throws `.notAuthenticated` on non-zero exit.
- `KeychainStore` protocol + `KeychainAccessStore` (real, service = `com.bsvassociation.yggdrasil`, accessibility = `.afterFirstUnlock`).
- `AuthService` actor — hydrates from Keychain at init, falls through to `gh` on miss, caches in memory + Keychain. `invalidate()` drops both.

### HTTP (`Yggdrasil/Core/GitHub/{Backoff,BackoffRetry,GitHubError,HTTPClient}.swift`)
- `Backoff.delay(forAttempt:)` — pure: 1s, 2s, 4s, … capped at 300s.
- `BackoffRetry.attempt(maxAttempts:sleep:operation:)` — generic retry helper with injectable sleep for tests.
- `URLSessionHTTPClient`:
  - `Authorization: Bearer <token>` injected from `AuthService`.
  - `If-None-Match` outgoing + reads `Etag` response → ETagStore round-trip.
  - On 304: returns `HTTPResult(body: nil)`.
  - On 401: invalidates AuthService, retries once with fresh token; second 401 surfaces `.unauthorized`.
  - Parses `X-RateLimit-Remaining`, warns to `YggdrasilLog.sync` below the 100-call threshold per spec.
- `GitHubError` enum — typed errors: `.requestFailed(URLError.Code)`, `.httpStatus(Int)`, `.unauthorized`, `.decodingFailed(String)`, `.graphqlErrors([String])`.

### API clients (`Yggdrasil/Core/GitHub/{Endpoints,APIResponses,RESTClient,GraphQLClient}.swift`)
- `Endpoints` — URL builders for `/issues?filter=assigned&state=open&per_page=100` and `/repos/{owner}/{repo}/pulls?state=open&per_page=100` + the GraphQL URL.
- `RESTIssueDTO`, `RESTPRDTO` — decode-only Decodable types matching GitHub's REST schema.
- `RawTask` — REST-layer's post-decode, pre-DB representation. Classifies an issue with a non-nil `pull_request` side-channel as `.pullRequest`; a PR with `merged_at != nil` as `.merged`.
- `RESTClient.assignedIssues()` / `.openPRs(forOwner:name:)` — both return `[RawTask]` for the simple case, or `CacheableFetch<[RawTask]>` (`.modified` / `.notModified`) for ETag-aware callers.
- `GraphQLClient.prDetail(owner:repo:number:)` — POSTs the inline `mergeable + reviewDecision + statusCheckRollup + comments/reviews counts` query, decodes into `PRDetail`. Surfaces `.graphqlErrors` when the response has a non-empty `errors` array.

### Sync orchestration (`Yggdrasil/Core/GitHub/TaskSyncService.swift`, `SyncScheduler.swift`)
- `TaskSyncService` actor — `fullSync()`:
  1. Reads tracked repos from `repo` table; no-op if empty.
  2. One `assignedIssues()` REST call; filter to tracked repos.
  3. For each PR raw, one `prDetail()` GraphQL call.
  4. Single DB write transaction:
     - Upsert task rows by `(repo_id, type, number)` — server wins for every task column.
     - Replace `task_assignee` rows (DELETE + INSERT in-txn).
     - Upsert `github_status` for PRs from PRDetail.
     - Delete task rows in tracked repos that are no longer in the response (closed / unassigned / merged → removed).
- `SyncScheduler` actor — fires action immediately on `start()`, then every `interval`. Cancellable, idempotent start, action errors logged but don't kill the loop.

### App wiring (`Yggdrasil/App/{AppDelegate,AppServices,DebugMenu,YggdrasilApp}.swift`)
- `AppServices` builds the production dependency graph at launch.
- `AppDelegate.applicationDidFinishLaunching` constructs services and starts the scheduler at 60s interval per spec §2.1. **Skips wiring under XCTest** so test runs don't reach the production DB / Keychain.
- `SyncScheduler` action runs `BackoffRetry.attempt(maxAttempts: 5) { syncService.fullSync() }`.
- `DebugMenu` (SwiftUI `Commands`): top-level **Debug** menu with **Add Tracked Repo…** (⇧⌘R), **Remove Tracked Repo…**, **Force Sync Now** (⇧⌘S), **Dump Tasks to Log**.

### CI (`/.github/workflows/ci.yml`)
- Now sets `env: YGGDRASIL_TEST_GITHUB_TOKEN: ${{ secrets.YGGDRASIL_TEST_GITHUB_TOKEN }}` on the `make test` step so the integration test runs when the user adds the secret.

---

## 2. Test summary

```
Executed 68 tests, with 1 test skipped and 0 failures (0 unexpected)
```

- 5 SmokeTests (Phase 0)
- 4 SettingsStoreTests
- 6 MigrationsTests
- 4 GHCLIAuthTests
- 5 AuthServiceTests
- 4 BackoffTests
- 3 BackoffRetryTests
- 5 ETagStoreTests
- 7 HTTPClientTests
- 7 RESTClientTests
- 4 GraphQLClientTests
- 8 TaskSyncServiceTests
- 5 SyncSchedulerTests
- 1 GitHubLiveSyncIntegrationTests (XCTSkip until token wired)

`swiftlint --strict`: 0 violations. `swiftformat --lint`: 0/43 files require formatting.

---

## 3. Deviations from the spec

### 3.1 No hard-coded tracked repos (user choice at boot)
Spec §Phase 1: *"Tracked repos seeded from a hard-coded list in `setting` table for now ... Reasonable defaults: a few bsv-blockchain repos."* User opted at boot: *"No repos should be hard coded. User needs to add the repos."* Tracked repos live in the `repo` table; `DebugMenu` adds/removes via NSAlert.

### 3.2 GraphQL PR detail is fetched per-PR; no `/pulls` per-repo walk in Phase 1
Spec §Phase 1: *"REST client for `/issues?filter=assigned&state=open` and `/repos/{owner}/{repo}/pulls?state=open`"*. The first endpoint covers both assigned issues AND assigned PRs across all repos. The `/pulls` per-repo walk returns ALL open PRs (assigned or not) — not needed for the spec's stated goal of *"all open assigned tasks"*. `RESTClient` exposes `openPRs(forOwner:name:)` (with tests), but `TaskSyncService.fullSync()` currently uses only `assignedIssues()`. Easy to enable in Phase 2+ if you want unassigned-PR visibility.

### 3.3 `YggdrasilTask` instead of `Task`
The DB type uses `YggdrasilTask` to avoid colliding with Swift Concurrency's `_Concurrency.Task`. Database table name stays `task` per spec §3.2. Logged in commit message.

---

## 4. How to verify (manual smoke)

The unit + integration tests cover everything that can be checked headlessly. To exercise the live wiring end-to-end:

1. `make build` then run `open ~/Library/Developer/Xcode/DerivedData/Yggdrasil-*/Build/Products/Debug/Yggdrasil.app`. The window titled "Yggdrasil" should appear.
2. Open Console.app → filter by subsystem `com.bsvassociation.yggdrasil`. You'll see `[ui] Yggdrasil did finish launching (pid=…)` and `[sync] No tracked repos; sync is a no-op`.
3. Menu bar → **Debug → Add Tracked Repo…** → enter an owner/name you have assigned tasks in (e.g. `bsv-blockchain/teranode`).
4. **Debug → Force Sync Now**. Within ~2s the log shows `[sync] Starting full sync over 1 tracked repos` then `[sync] REST returned N assigned tasks, M within tracked repos` then `[sync] Full sync complete`.
5. **Debug → Dump Tasks to Log** prints the rows.
6. Inspect SQLite: `sqlite3 ~/Library/Application\ Support/Yggdrasil/yggdrasil.sqlite "SELECT * FROM task;"`

The 60s background sync ticks should also appear in Console (`[sync] Starting full sync…` lines at ~60s intervals).

To run the live integration test locally: `YGGDRASIL_TEST_GITHUB_TOKEN=$(gh auth token) make test`.

---

## 5. Open questions

1. **GitHub remote** — still no remote configured. AC #4 from Phase 0 (CI green on GitHub) and the integration test secret remain `[BLOCKED]` until you push the repo somewhere. When you do: add `YGGDRASIL_TEST_GITHUB_TOKEN` as a repo secret. Want me to draft the `git remote add` + first push when you give the URL?
2. **Unassigned PRs in tracked repos** — see §3.2. Worth surfacing in the sidebar? If yes, easy follow-up: extend `fullSync()` to walk `RESTClient.openPRs` per tracked repo.
3. **Sync interval still 60s** — kept per spec §2.1. The user can change `.seconds(60)` in `AppServices.swift` for now; Phase 8 turns it into a Preferences slider.
4. **Initial fullSync timing** — the scheduler fires *immediately* on start (verified in tests). With an empty `repo` table this is a no-op. After adding a repo via the debug menu, the user can either click Force Sync Now or wait up to 60s for the next tick. Acceptable in a debug build; Phase 8 polish may warrant an "added repo → trigger sync" hook.

---

## 6. What's next

Phase 2 — Worktree manager (`git worktree` subprocess wrapper). Standalone module; no UI yet. Awaiting explicit approval before any Phase 2 code.

---

**STOP.** Phase 1 complete. Review and approve to proceed to Phase 2?
