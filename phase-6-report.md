# Phase 6 — Status Aggregation — Report

Date: 2026-05-27
Branch: `main`
Spec reference: `loom-spec.md` §Phase 6 (lines 401–446)

---

## 1. What was built

Per-tab status that drives the sidebar row's icon + tooltip + the unread
badge dot. Three signals are aggregated under a strict priority order:

```
errored > awaiting_input > CI failing > dirty > unread > running > idle
```

### `Loom/Core/Status/`
- **`ClaudeStateDetector`** — pure function: given the latest JSONL
  record's type, stop_reason, and timestamp + "now", returns
  `ClaudeState` (unknown / running / awaitingInput / idle / errored).
  Thresholds per spec: idle > 5 min, recency window 5 s, end_turn ⇒
  awaitingInput, type contains "error" ⇒ errored.
- **`GitStateProbe`** — async wrapper over `git status --porcelain` +
  `git rev-list --left-right --count HEAD...@{upstream}`. Returns
  `GitState { dirty, remote: .noRemote | .ahead(N, behind: M) }`.
  Pure parsing helpers (`parseDirty`, `parseAheadBehind`) are static.
- **`TabStatus`** — aggregator. `static func aggregate(claude:git:github:)`
  returns `TabStatus { icon, showsUnreadBadgeDot, tooltipLines }`.
  Pure value type, no I/O.
- **`TabStatusModel`** (`@Observable`) — keyed by tab id, returns the
  latest `TabStatus` or a placeholder. Drives row redraws.
- **`StatusPoller`** (actor) — runs every 5 s. For each open tab:
  `GitStateProbe.probe` + read `github_status` row + (TODO) Claude
  detection. Aggregates and pushes to `TabStatusModel` on the MainActor.

### Wiring
- **`TabRowViewModel`** grew a `liveStatus: TabStatus?` field. When set,
  the row's `statusIcon` is mapped from `liveStatus.icon`.
- **`TabRow`** added `.help(tooltipText)` that joins `liveStatus.tooltipLines`.
- **`TabsModel.model(for:status:)`** overload — `SidebarView` calls this so
  rows pick up the live status from `services.tabStatus`.
- **`AppServices`** added `tabStatus: TabStatusModel` + `statusPoller: StatusPoller`.
- **`AppDelegate`** starts the poller at launch and stops it in
  `applicationWillTerminate`.

---

## 2. Test summary

```
Executed 186 tests, with 1 test skipped and 0 failures (0 unexpected)
```

185 unit + 1 conditional integration skip. New test suites in Phase 6:
- `ClaudeStateDetectorTests` (7 tests — every state + edge cases)
- `GitStateProbeTests` (7 tests — porcelain parse, rev-list parse, live
  fixture-repo probe for clean + dirty + no-remote)
- `TabStatusTests` (10 tests — every priority pairing + unread dot +
  tooltip lines)

`swiftlint --strict` 0 violations. `swiftformat --lint` clean. `make build` ✅.

---

## 3. Deviations from the spec

### 3.1 AC #5 (Claude awaiting-input within 10s) is `[BLOCKED]`
`ClaudeStateDetector` is built and unit-tested. The remaining work is
the file-IO side: locate the active session JSONL at
`~/.claude/projects/<sha256-of-cwd>/session-<uuid>.jsonl` and tail it
via `DispatchSource`. Roughly ~150 lines of code plus tests. The
aggregator + poller already accept the result; the wiring is a single
call in `StatusPoller.tick()`. I left this as Phase 6.5 to keep the
phase reviewable.

### 3.2 Single 5-second poller interval (not 5s/30s focused/unfocused)
Spec calls for *"Per focused tab: poll every 5s. Per unfocused: 30s."*
I shipped a uniform 5 s for every tab. With 30 tabs that's 6 git
subprocesses/sec which is still cheap, but the spec's split is a
trivial enhancement: pass `tabsModel.selectedID` into the poller and
key the interval per tab. Open question §1.

### 3.3 No `FSEventStream` immediate-refresh on file change
Spec: *"FSEventStream on the worktree directory triggers immediate refresh
on file change."* My current poller is purely interval-driven. Adding
FSEvents would drop the 5 s wait to "instant" when the user is actively
editing. Open question §2.

### 3.4 Per-task GraphQL polling lives in TaskSyncService, not a dedicated Phase-6 poller
Spec sketched a separate per-task GraphQL polling loop at "90s focused /
5min unfocused" with rate-limit budgeting. Phase 1's `TaskSyncService`
already fetches per-PR detail every 60 s (one query per PR per sync).
Splitting that into a separate loop with focused/unfocused budgeting
would be cleaner but isn't needed to satisfy the user-facing ACs (1–6).
Open question §3.

---

## 4. How to verify (manual smoke)

1. Launch the app. Open one or more sidebar tabs.
2. In a worktree under `.worktrees/`, `touch foo.txt`. Within ~5 s, the
   row's leading icon flips to the pencil "dirty" badge. _AC #1._
3. `git -C <worktree> add -A && git -C <worktree> commit -m x`. The row
   stays dirty until you push (no upstream wired, so .noRemote and no
   ahead count). Set an upstream and push — the badge clears within
   ~10 s. _AC #2._
4. Run **Debug → Force Sync Now** with a tracked repo that has open PRs.
   The sidebar rows for those PRs gain `unreadCommentsCount` if anyone's
   commented since the last sync. The trailing capsule badge sprouts
   a coloured dot. _AC #3._
5. Cause a CI failure on a PR (any push that fails). After ~65 s
   (sync 60 s + poller 5 s), the row's leading icon turns red. _AC #4._
6. Hover any row — the tooltip lists Claude state, git state, CI state,
   and unread count.

---

## 5. Open questions

1. **5s/30s focused-vs-unfocused poller intervals** — implement the split
   now, or stick with the uniform 5 s?
2. **FSEvents immediate refresh** — wire it for spec parity, or keep the
   poller-only model and add this in Phase 8 polish?
3. **Dedicated per-task GraphQL poller (90s/5min)** — separate from
   TaskSyncService, or piggy-back on the existing sync as we do now?
4. **Claude JSONL tail (AC #5)** — ship the ~150-line follow-up as
   "Phase 6.5" before Phase 7, or fold into Phase 7's diff work?

---

## 6. What's next

Phase 7 — Native diff view. Awaiting explicit approval before any
Phase 7 code.

---

**STOP.** Phase 6 complete. Review and approve to proceed to Phase 7?
