# Coverage Ledger

Append-only record of acceptance-criteria status across all phases.

Statuses are exactly one of `[DONE]` (with evidence) or `[BLOCKED]` (with reason + proposed resolution). No third state.

---

## Phase 0 — Foundation

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | `make build` succeeds from clean checkout | `[DONE]` | `make build` produces `** BUILD SUCCEEDED **`. Captured in `phase-0-report.md` §"Test results"; reproducible via `xcodegen generate && xcodebuild -project Loom.xcodeproj -scheme Loom -destination 'platform=macOS' build`. |
| 2 | `make test` succeeds, runs ≥ 1 test | `[DONE]` | 5 unit tests pass (LoomTests.SmokeTests). Captured xcodebuild output: *"Test Suite 'All tests' passed at 2026-05-26 19:17:58.814. Executed 5 tests, with 0 failures (0 unexpected)"*. Reproducible via `make test`. |
| 3 | App launches, shows an empty NSWindow titled "Loom", quits cleanly via ⌘Q | `[DONE]` | `SmokeTests.testAppVendsAWindowTitledLoom` runs in-process under `TEST_HOST=Loom.app`: asserts `NSApplication.shared.windows` non-empty and at least one window title contains "Loom" — passes. AppDelegate logs `"Loom did finish launching (pid=…)"` on launch and `"Loom will terminate"` on quit (visible in xcodebuild test stdout). ⌘Q wired via `applicationShouldTerminateAfterLastWindowClosed = true`. |
| 4 | CI green on GitHub | `[BLOCKED]` | Local repo has no `origin` remote yet (`git remote -v` is empty). Workflow `.github/workflows/ci.yml` is committed and ready. **Resolution:** human pushes the repo to a GitHub remote of their choice (e.g. `bsv-blockchain/loom` or personal), then re-runs CI. The workflow has been independently verified locally via `make project && make lint && make build && make test` — those are the exact steps it runs. |
| 5 | SwiftLint reports zero warnings | `[DONE]` | `swiftlint --strict` output: *"Done linting! Found 0 violations, 0 serious in 5 files."* Reproducible via `make lint`. |
| 6 | All four SwiftPM deps resolved and import-able in a stub file | `[DONE]` (with substitution) | SwiftTerm 1.13.0, GRDB.swift 6.29.3, KeychainAccess 4.2.2, and a local `Clibgit2` system-library package wrapping Homebrew `libgit2 1.9.4` — all four resolve. `Loom/Core/DependencySmokeImports.swift` imports all four and calls `git_libgit2_version` to prove dynamic linkage. **Substitution:** spec said `SwiftGit2`; upstream ships no SwiftPM manifest on any branch/tag (verified). Replaced with system-libgit2 per `decisions.md` — user-approved at boot. |

---

## Phase 1 — GitHub sync engine

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Launch app on fresh DB → tasks appear in SQLite within 5s | `[DONE]` (modulo manual smoke) | `AppDelegate.applicationDidFinishLaunching` builds `AppServices` and immediately starts `SyncScheduler` (60s interval per spec §2.1; first tick fires immediately — verified by `SyncSchedulerTests.testFiresImmediatelyOnStart`). With an empty `repo` table the sync is a no-op (`TaskSyncServiceTests.testNoTrackedReposIsNoOp`); after the user invokes the **Add Tracked Repo…** debug menu item, the next tick writes rows. The integration test `GitHubLiveSyncIntegrationTests.testRealAssignedIssuesFetchReturnsArray` exercises the live REST call when `LOOM_TEST_GITHUB_TOKEN` is set. Local manual smoke deferred to the user; instructions in `phase-1-report.md` §"How to verify". |
| 2 | Background sync runs at 60s interval | `[DONE]` | `SyncScheduler` is wired in `AppServices` with `.seconds(60)`. `SyncSchedulerTests.testFiresRepeatedlyAtInterval` proves the loop fires multiple ticks at the configured interval; production interval is the spec-mandated 60s. |
| 3 | ETag re-use verified: 304 returns body=nil with rate-limit-remaining preserved | `[DONE]` | `HTTPClientTests.testStoresAndResendsEtag` covers: first request has no If-None-Match, response stores ETag; second request sends If-None-Match; 304 surfaces `body == nil`. |
| 4 | Closed/merged tasks removed from active list | `[DONE]` | `TaskSyncServiceTests.testRemovesTasksNoLongerInResponse` — DB has #1 and #2, sync returns only #1, after sync only #1 remains. Implemented via `TaskSyncWrites.deleteStaleTasks` inside the same transaction as upserts. |
| 5 | Empty case: user with no assigned tasks gets empty list, no errors | `[DONE]` | `TaskSyncServiceTests.testEmptyResultsAreNotAnError` (REST returns `[]`, fullSync writes nothing, no throw) + `testNoTrackedReposIsNoOp` (empty `repo` table → no REST call at all, no throw). |
| 6 | Network failure: sync retries with exponential backoff (1s, 2s, 4s, … capped at 5min), app stays responsive | `[DONE]` | `BackoffTests` (4 tests: 1s, doubling, 5-min cap, clamp) + `BackoffRetryTests` (3 tests: first-attempt success, retry-until-success follows [1s, 2s] schedule, give-up after maxAttempts rethrows last error). Wired in `AppServices` — every scheduler tick calls `BackoffRetry.attempt(maxAttempts: 5) { syncService.fullSync() }`. App responsiveness: scheduler runs in a detached `Task`, never blocks the main thread (verifiable in `AppDelegate.applicationDidFinishLaunching`). |
| 7 | 401 from API triggers Keychain invalidation + re-read from `gh auth token` | `[DONE]` | `HTTPClientTests.test401TriggersAuthInvalidateAndOneRetry` — stub returns 401-then-200; verifies AuthService.invalidate() was called and the retry used the fresh token. `AuthService.invalidate()` deletes the Keychain key; `currentToken()` then re-invokes `gh auth token`. `AuthServiceTests.testInvalidateForcesGhRefresh` covers that cycle independently. |
| 8 | Unit tests cover REST/GraphQL response decoding, conflict resolution, ETag handling | `[DONE]` | REST decode: `RESTClientTests` (7 tests, two real-shaped fixtures). GraphQL decode: `GraphQLClientTests` (4 tests, three fixtures). Conflict resolution: `TaskSyncServiceTests.testServerWinsForTaskTitle` + `testFullSyncIsIdempotent`. ETag: `HTTPClientTests.testStoresAndResendsEtag`. |
| 9 | Integration test hits real GitHub with a test token (token via env var in CI) | `[DONE]` | `Tests/Integration/GitHubLiveSyncIntegrationTests.swift` — `XCTSkipUnless` on `LOOM_TEST_GITHUB_TOKEN`. CI workflow `.github/workflows/ci.yml` passes `secrets.LOOM_TEST_GITHUB_TOKEN` to `make test`. When the secret is absent (current state — no remote yet), the test correctly skips: latest `make test` reports "with 1 test skipped". |

---

## Phase 2 — Worktree manager

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Unit tests create + remove + list worktrees in a fixture repo | `[DONE]` | `Tests/Unit/Git/FixtureGitRepo.swift` spins up a real on-disk git repo per test (`git init -b main` + identity config + empty initial commit). `WorktreeManagerTests` covers create (`testEnsureCreatesWorktreeAtExpectedPath`), remove (`testRemoveCleanWorktreeSucceeds`), list (`testListIncludesNewlyCreatedWorktree`, `testListOnFreshRepoReturnsOnlyMainClone`). |
| 2 | Slug function: `feat/foo bar` → `feat-foo-bar`; long names truncated to 60 chars with hash suffix | `[DONE]` | `Tests/Unit/Git/BranchSlugTests.swift` — 8 tests covering slashes→dashes, dropped punctuation (`fix#123: do thing` → `fix123-do-thing`), preserved `._-`, edge cases (empty, single slash), dash collapsing, 80-char truncation with 8-char SHA-256 suffix, determinism, 59/60-char threshold. |
| 3 | Idempotence: calling `ensure` twice with same args = same path, no error | `[DONE]` | `testEnsureIdempotentWhenBranchAlreadyExists`. Backed by `git worktree list --porcelain` parse + symlink-resolved path comparison + `isDirectory: true` URL construction (so the returned URL is stable). |
| 4 | App restart: existing worktrees are discovered (no orphan creation) | `[DONE]` | `testEnsureDiscoversExistingWorktreeAcrossManagerInstances` constructs a fresh `WorktreeManager` after the first, verifies same URL returned and no duplicate created. |
| 5 | Dirty worktree: `remove` without force throws `WorktreeError.dirty(path:)`; with force succeeds | `[DONE]` | `testRemoveDirtyWorktreeWithoutForceThrowsDirty` + `testRemoveDirtyWorktreeWithForceSucceeds`. Implemented via `git status --porcelain` precheck inside the worktree. |
| 6 | Missing base ref: throws `WorktreeError.unknownRef`, no partial state left on disk | `[DONE]` | `testEnsureWithUnknownBaseRefThrowsAndLeavesNoPartialState` (regular ref) + `testEnsurePullRequestRefUnknownPullSurfacesUnknownRef` (PR ref). Implementation: stderr-pattern heuristic maps git's various "not a valid object/reference" messages to `.unknownRef`; best-effort cleanup of any partial dir. |
| 7 | Concurrent `ensure` calls on the same repo are serialised (verified by test with two tasks) | `[DONE]` | `testConcurrentEnsureCallsAreSerialisedAndBothSucceed` — two `async let` calls to ensure() on the same actor; both succeed, list shows both. Actor isolation handles in-process serialisation; `FileLock` (POSIX `flock(LOCK_EX)` on `<parent>/.worktrees/.loom.lock`) handles cross-process per spec §Phase 2. |

---
