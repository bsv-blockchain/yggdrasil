# Phase 3 — Embedded Coding-Agent Runner — Report

Date: 2026-05-27
Branch: `main`
Spec reference: `yggdrasil-spec.md` §Phase 3 (post-update commit `45d5b6a`)

---

## 1. What was built

The full Phase 3 stack:

### Storage (`Yggdrasil/Core/Storage`, `Yggdrasil/Core/Models`)
- **Migration v2** appends three tables: `coding_agent`, `tab`, `session_state`.
- Seeds the default Claude profile on v2 apply: `{ name: "Claude", command: "claude", args: ["--dangerously-skip-permissions"], is_default: 1, position: 0 }`.
- `CodingAgent`, `Tab`, `SessionState` GRDB models with `args`/`agentArgs` stored as JSON-string columns (custom Codable impls so callers see `[String]`).
- `CodingAgentStore` — list (ordered by position) / get / getDefault / add / remove / setDefault (atomic clear-all-then-set) / update (in-place rename / command / args, bumps `updated_at`).
- `SessionStateStore` — get / start (upsert: resets pty_started_at, clears exit code) / end (records exit code + pty_ended_at).

### Terminal core (`Yggdrasil/Core/Terminal`)
- **`OutputRingBuffer`** — fixed-capacity byte ring. `makeAgentOutputRing()` returns the spec's 4KB default.
- **`CodingAgentRunner`** — headless lifecycle owner. Wraps `SwiftTerm.LocalProcess`. Spawns via `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args>'` (non-interactive shell purely to provide cwd, since bare `LocalProcess` doesn't accept it). Records `session_state.start` on spawn and `session_state.end` on processTerminated. `terminate(graceful:)` sends SIGTERM (with a SIGKILL fallback after `killAfter`) or SIGKILL outright. Async `waitUntilExited(timeout:)` for tests.

### UI (`Yggdrasil/Features/MainPane`, `Yggdrasil/App`)
- **`AgentTerminalSurface`** — `NSViewRepresentable` over `SwiftTerm.LocalProcessTerminalView`. Spawns via the view's native `startProcess(executable:, args:, currentDirectory:)` — cleaner than the headless runner's shell wrap because the view's startProcess accepts cwd directly. Coordinator implements `LocalProcessTerminalViewDelegate`: writes `session_state` transitions, captures 4KB of output, registers/unregisters its PID with `SessionsModel`, and sends SIGTERM + delayed-SIGKILL on dismantle.
- **`SessionsModel`** (@Observable) — `[OpenSession]` (tab id, display name, cwd, command, args) + `selectedID` + a `tabID → pid_t` registry of live agents for the ⌘Q sweep.
- **`SessionsView`** in `YggdrasilApp.swift` — a horizontal tabs strip across the top and a `ZStack` body that hosts EVERY open session's `AgentTerminalSurface` simultaneously (opacity-toggled per selection) so PTYs survive tab-switching. Empty state when no sessions exist.
- **`DebugMenu`** grew four new items: **Add Agent…** (name+command+args prompt), **Remove Agent…**, **Set Default Agent…**, and **+ New Session…** (⇧⌘N — prompts for worktree path + agent profile, inserts a Tab row, appends an `OpenSession`).

### App wiring
- `AppServices` exposes `agentStore`, `sessionStore`, and the shared `sessions: SessionsModel`.
- `AppDelegate.applicationWillTerminate` iterates `sessions.snapshotLivePIDs()` and SIGTERMs each — defence in depth on top of SwiftUI's dismantle-on-close path.

---

## 2. Test summary

```
Executed 130 tests, with 1 test skipped and 0 failures (0 unexpected)
```

129 unit + 1 conditional integration skip. All 19 test suites green. `swiftlint --strict` 0 violations. `swiftformat --lint` clean. `make build` ✅.

New test suites in Phase 3:
- `MigrationV2Tests` (6 tests)
- `CodingAgentStoreTests` (9 tests)
- `SessionStateStoreTests` (5 tests)
- `OutputRingBufferTests` (8 tests)
- `CodingAgentRunnerTests` (3 tests — echo, SIGKILL, SIGTERM-with-fallback)

---

## 3. Deviations from the spec

### 3.1 Headless runner uses a shell wrap; UI surface uses native `currentDirectory`
Spec §2.1: *"spawn `<profile.command> <profile.args>` directly inside a PTY at the worktree path. No interactive shell wrapper."*

- The UI path (`AgentTerminalSurface`) uses `LocalProcessTerminalView.startProcess(currentDirectory:)`, which sets cwd via `chdir` in the child after `fork`. **Zero shell wrap.** Matches the spec's letter and spirit.
- The headless test path (`CodingAgentRunner`) uses `SwiftTerm.LocalProcess` directly, which does NOT expose a `currentDirectory` parameter. The minimal wrap to set cwd is `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args>'` — non-interactive (no `-i`, no rc files loaded), uses `exec` so signals go straight to the agent. The spec forbids INTERACTIVE shell wrappers; this is non-interactive. Logged in `decisions.md`.

If desired we can patch SwiftTerm's `LocalProcess` to accept cwd and ship the patched fork, then drop the wrap. Tracked as a Phase 8 cleanup.

### 3.2 SwiftUI view persistence via `ZStack` + opacity, not native NSTabView
`SwiftUI.TabView` on macOS uses lazy tab loading — switching destroys the off-screen view, which would tear down its PTY. To keep 5 concurrent sessions alive (spec AC #4), I host all surfaces in a `ZStack` with stable `.id(session.id)` per child and toggle visibility via `opacity`. Off-screen PTYs continue receiving output into their ring. Trade-off: hit-testing has to be explicitly disabled for non-selected children (done) and there's a small memory cost (one NSView per session even when invisible).

### 3.3 RSS budget (AC #8) is `[BLOCKED]` pending Instruments
Spec calls for "10 open/close cycles, RSS growth < 50MB net". Automating this needs an Instruments-driven CI step we don't have. The architecture supports the budget (one PTY + one 4KB ring per session, surfaces dismantled by SwiftUI on close), but the formal measurement is deferred — either a manual Instruments pass against the shipping build, or a Phase 8 polish item. See coverage ledger #8.

### 3.4 "Crash recovery" surfaces data, not yet a UI
Spec AC #7 says the previous session's exit code + agent command must be visible in `session_state` after restart. The DATA is there: `SessionStateStore.get(tabID:)` returns the durable row with `lastKnownExitCode` and `agentCommand`. A "resume previous session?" prompt or sidebar indicator is Phase 4+ work.

---

## 4. How to verify (manual smoke)

1. `make build` then launch the resulting `Yggdrasil.app` (`open ~/Library/Developer/Xcode/DerivedData/Yggdrasil-*/Build/Products/Debug/Yggdrasil.app`).
2. Yggdrasil window opens with the empty-state placeholder ("No sessions yet").
3. Open Console.app filtered to subsystem `com.bsvassociation.yggdrasil` to see the live logs.
4. **Debug → + New Session…** Enter a worktree path (any directory you have) and pick "Claude" from the dropdown. Click Start. The terminal surface appears and runs `claude --dangerously-skip-permissions` in that cwd. The Claude prompt should be visible within ~2s. _AC #3._
5. Open four more sessions in four different worktree paths. Tab strip shows all five; clicking switches. _ACs #4, #9 (try ⌘C/⌘V/scrollback in any tab)._ Each tab's first agent output should reflect its own cwd. _AC #5._
6. **Debug → Add Agent…** Enter Codex / `codex` / (args optional). Then **Debug → Set Default Agent…** Pick Codex. Open a new session — the default selection in the prompt should now be Codex. _AC #2._
7. Quit Yggdrasil (⌘Q). Within 5s, `ps -ef | grep claude` (or whichever agent) should show no leftover agent processes. _AC #6._
8. Relaunch Yggdrasil. `sqlite3 ~/Library/Application\ Support/Yggdrasil/yggdrasil.sqlite "SELECT tab_id, agent_command, last_known_exit_code FROM session_state;"` should show exit codes for the previous run. _AC #7._

---

## 5. Open questions

1. **Headless runner vs view surface duplication** — they share session_state recording but maintain separate spawn implementations. Worth unifying in Phase 8 (one path, patched-SwiftTerm), or leave the two-track approach for the visible cost it imposes?
2. **Memory budget** — happy to mark AC #8 done after a manual Instruments pass on your machine, or you'd rather wait for a CI step?
3. **Crash-resume UI** — the data's there. Want a "resume Claude in /path/x?" prompt in Phase 4, or skip it?

---

## 6. What's next

Phase 4 — Sidebar UI. The temporary tabs strip in `SessionsView` is the placeholder it'll replace. Awaiting explicit approval before any Phase 4 code.

---

**STOP.** Phase 3 complete. Review and approve to proceed to Phase 4?
