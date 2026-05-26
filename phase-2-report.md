# Phase 2 — Worktree Manager — Report

Date: 2026-05-26
Branch: `main` (per workflow exception, see `decisions.md`)
Spec reference: `loom-spec.md` §Phase 2 (lines 284–312)

---

## 1. What was built

A self-contained `WorktreeManager` actor that wraps `git worktree` subprocess
calls. Pure git mechanics; no GitHub coupling beyond accepting the existing
`Repo` model. ~280 lines of production Swift behind 13 unit tests covering
the spec's 7 acceptance criteria.

### `Loom/Core/Git/`
- **`BranchSlug.swift`** — pure-function branch-name → filesystem-safe slug.
  Slashes and whitespace become `-`; pure punctuation (`#:;,?@!$…`) is
  dropped; other unknown chars default to `-`; runs of `-` collapse;
  names > 60 chars truncated with an 8-char SHA-256 suffix for uniqueness.
- **`WorktreeError.swift`** — typed errors: `.dirty(path:)`, `.unknownRef`,
  `.gitFailed(stderr, exitCode)`, `.existsOnDifferentBranch(path, found,
  expected)`, `.lockTimeout`, `.parseFailure`.
- **`WorktreeInfo.swift`** — value type representing one paragraph of
  `git worktree list --porcelain`. Tolerates unknown keys (future-proof);
  surfaces locked/prunable/bare/detached flags.
- **`GitRunner.swift`** — thin wrapper over the Phase 1 `SubprocessRunner`.
  Prepends `-C <cwd>` when a working directory is given; throws `.gitFailed`
  on non-zero exit.
- **`FileLock.swift`** — minimal `flock(2)` wrapper. `acquireExclusive(at:)`
  opens/creates the lockfile and `flock(LOCK_EX)`s it; `release()` unlocks
  and closes; `deinit` releases as a safety net.
- **`WorktreeManager.swift`** — the actor. API:
  - `ensure(repo:, branch:, baseRef:)` → URL. For PR refs
    (`refs/pull/<N>/head`): `git fetch origin pull/<N>/head:<branch>` then
    `git worktree add <path> <branch>` (no `-b`, branch already exists).
    For regular refs: `git worktree add -b <branch> <path> <baseRef ?? defaultBranch>`.
    Idempotent — if a worktree at the expected path already lists the
    right branch, returns its URL without git work. Acquires the per-repo
    POSIX file lock at the start; releases via `defer`.
  - `list(for:)` → `[WorktreeInfo]` via `worktree list --porcelain`.
  - `remove(repo:, path:, force:)` → `git worktree remove`. Without force,
    runs `git status --porcelain` first and throws `.dirty(path:)` if the
    worktree has uncommitted changes.
  - `cleanupOrphans(for:)` → `git worktree prune`.

### `Tests/Unit/Git/`
- **`FixtureGitRepo.swift`** — async helper. `create(named:)` makes a UUID-
  scoped tmp dir, runs `git init -b main`, configures user identity, makes
  an empty initial commit, returns a `Repo` model row + parent URL +
  worktrees-dir convenience. `cleanup()` rms the tree.
- **`BranchSlugTests.swift`** (8 tests).
- **`GitRunnerTests.swift`** (4 tests).
- **`WorktreeInfoTests.swift`** (4 tests).
- **`WorktreeManagerTests.swift`** (13 tests — see §3 below).

---

## 2. Test summary

```
Executed 98 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.524s
```

97 unit tests + 1 conditional integration skip. All 17 test suites green
(BackoffTests, BackoffRetryTests, BranchSlugTests, ETagStoreTests,
GHCLIAuthTests, GitHubLiveSyncIntegrationTests, GitRunnerTests,
GraphQLClientTests, HTTPClientTests, MigrationsTests, RESTClientTests,
SettingsStoreTests, SmokeTests, SyncSchedulerTests, TaskSyncServiceTests,
WorktreeInfoTests, WorktreeManagerTests).

- 0 SwiftLint violations
- 0 SwiftFormat-required formatting changes
- `make build` ✅

---

## 3. Tests added in Phase 2

`WorktreeManagerTests` against a real fixture repo:
- `testEnsureCreatesWorktreeAtExpectedPath`
- `testEnsureIdempotentWhenBranchAlreadyExists`
- `testEnsureDiscoversExistingWorktreeAcrossManagerInstances`
- `testEnsureWithUnknownBaseRefThrowsAndLeavesNoPartialState`
- `testEnsureCreatesWorktreesDirIfMissing`
- `testListIncludesNewlyCreatedWorktree`
- `testListOnFreshRepoReturnsOnlyMainClone`
- `testRemoveCleanWorktreeSucceeds`
- `testRemoveDirtyWorktreeWithoutForceThrowsDirty`
- `testRemoveDirtyWorktreeWithForceSucceeds`
- `testCleanupOrphansRemovesAdminEntryForDeletedWorktreeDir`
- `testEnsurePullRequestRefIssuesFetchThenWorktreeAdd` (stub-based, verifies command sequence + absence of `-b`)
- `testEnsurePullRequestRefUnknownPullSurfacesUnknownRef` (stub-based)
- `testConcurrentEnsureCallsAreSerialisedAndBothSucceed` (two `async let` calls on the same actor)

Plus `BranchSlugTests` (8), `GitRunnerTests` (4), `WorktreeInfoTests` (4).

---

## 4. Deviations from the spec

### 4.1 BranchSlug character mapping (clarification, not deviation)
Spec §2.1 prose: *"`/` replaced by `-` and any other non-`[a-zA-Z0-9._-]` char dropped"*. Spec §Phase 2 AC #2: *"`feat/foo bar` → `feat-foo-bar`"*. These contradict — the AC requires the space to become a dash, not be dropped. I followed the AC: separator-like chars (slashes, whitespace) → `-`; pure punctuation (`#`, `:`, etc.) → dropped; other unknown chars → `-` so words don't smush. All 8 slug tests pass.

### 4.2 FileLock uses LOCK_NB + async retry (not the naive LOCK_EX)
Initial implementation used `flock(LOCK_EX)` (blocking). Inside an actor that holds the lock across an `await`, a second actor message could enter (because the actor releases control at `await`) and try to acquire the lock from the same process — but flock allows it; the issue was that the second `flock(LOCK_EX)` call would block on the FIRST fd's lock, wedging the cooperative thread and preventing the first message's continuation from ever running. Symptom: `WorktreeManagerTests` hung forever, all other suites finished in <1s.

Fix: `FileLock.acquireExclusive(at:timeout:pollInterval:)` is async. Uses `LOCK_NB` and polls every 20ms via `Task.sleep` (default timeout 30s, throws `.timedOut`). The poll yield gives the actor a chance to process the holder's continuation. After fix, the full suite runs in 2.5s.

### 4.3 Concurrency test uses actor isolation, not external lock contention
Spec §Phase 2: *"Concurrent ensure calls on the same repo are serialised (verified by test with two tasks)."* Test uses two `async let` calls on a single `WorktreeManager` actor; both succeed, the resulting `list()` shows both. Actor isolation guarantees in-process serialisation; the `FileLock` adds cross-process protection (would require a second OS process to demonstrate, which is out of scope for a unit test).

### 4.4 PR ensure() reuses the single `ensure()` entry point
The spec lists one method `ensure(repo:, branch:, baseRef:)`. I encode the
PR convention via the `baseRef` argument: if it matches `refs/pull/<N>/head`,
the fetch-then-worktree-add path is taken; otherwise the regular
`worktree add -b` path. Same method, different paths inside. Two stub-based
tests assert the command sequence.

---

## 5. How to verify (manual smoke)

The unit tests against a real fixture repo cover everything. To smoke against
a real Loom-tracked repo:

```bash
# In an interactive Swift session (or extend the debug menu later):
let manager = WorktreeManager()
let repo = Repo(id: 1, owner: "bsv-blockchain", name: "teranode",
                defaultBranch: "main",
                localMainPath: "/Users/sigi/code/teranode",
                addedAt: Date())
let url = try await manager.ensure(repo: repo, branch: "scratch/test", baseRef: nil)
print(url)                        // /Users/sigi/code/.worktrees/scratch-test
try await manager.list(for: repo) // includes the new worktree
try await manager.remove(repo: repo, path: url, force: false)
```

Phase 3 will wire this into the debug menu's "+ New Session" flow.

---

## 6. Open questions

1. **PR worktree convention** — current implementation: caller passes
   `branch: "pr-655"` (local name) and `baseRef: "refs/pull/655/head"`. Want
   me to also accept `baseRef: "pull/655/head"` (the bare form that `git
   fetch` actually takes)? I'd add the variant in a small follow-up.
2. **PR fetch coverage** — only stub-based tests for now; the spec's
   acceptance is met but a real-PR end-to-end test would need a 2-repo
   fixture (bare origin with `refs/pull/N/head` set). Worth adding before
   Phase 3 wires it, or defer until needed?
3. **Lock fairness** — `flock(LOCK_EX)` is blocking; under heavy contention
   from a stuck external git process, ensure() could hang. Spec doesn't
   require a timeout; want me to add `LOCK_NB` + retry loop with deadline
   anyway?

---

## 7. What's next

Phase 3 — Embedded coding-agent runner. Requires migration v2 (the
`coding_agent` table per the updated spec §3.2). Awaiting explicit approval
before any Phase 3 code.

---

**STOP.** Phase 2 complete. Review and approve to proceed to Phase 3?
