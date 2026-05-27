# Phase 4 — Sidebar UI — Report

Date: 2026-05-27
Branch: `main`
Spec reference: `loom-spec.md` §Phase 4 (lines 342–371)

---

## 1. What was built

A full SwiftUI sidebar that replaces the Phase 3 tabs-strip placeholder.
All seven Phase 4 acceptance criteria are addressed; all but the
"60 fps with 20 tabs" and "200-tab live filter" leans on a manual
Instruments pass against the shipping build (see §3 below).

### `Loom/Core/Storage`
- **`TabStore`** — typed CRUD over the `tab` table. `list` ordered by
  `position ASC`, `insert` auto-positions at end, `delete`,
  `reorder(ids:)` (atomic + id-set-validated), `touchLastActiveAt`.

### `Loom/Features/Sidebar`
- **`TabRowViewModel`** — pure value type. `titleLine` (task title for
  GitHub-linked tabs, branch name for ad-hoc), `branchLine`,
  `worktreeLine` (mid-ellipsis to 50 chars by default), `statusIcon`
  (placeholder until Phase 6), `trailingBadge` (.prNumber /
  .issueNumber / .none).
- **`TabRow`** — SwiftUI cell. HStack with leading status icon, three-
  line VStack (title / branch in monospace / worktree path), trailing
  capsule badge. Accent-tinted selection background.
- **`TabsModel`** (@Observable) — the sidebar's view model. Holds
  `[Tab]`, a `tabID → LoomTask` cache, `selectedID`. `reload()`
  refreshes from disk and reconciles selection. `select(id:)` also
  touches `lastActiveAt`. `moveSelection(by:)` powers ⌥↑/↓.
  `move(fromOffsets:toOffset:)` is the SwiftUI `onMove` shape — updates
  in-memory immediately, persists via `TabStore.reorder`, rolls back
  on failure. `filtered(by:)` is the search filter.
- **`SidebarView`** — `List`-based for native drag-to-reorder, with a
  header (label + "+" button bound to ⌘T), a debounced search field
  (150 ms), an empty state, a no-matches state. `.contextMenu` exposes
  Open in Finder, Open in Terminal.app, Remove….
- **`NewTabSheet`** — the "+" sheet: tracked-repo picker, branch text
  field, agent picker. Confirm calls `WorktreeManager.ensure` →
  `TabStore.insert` → `TabsModel.reload` → `SessionsModel.add`, which
  causes the `AgentTerminalSurface` to mount and spawn the agent.
- **`SidebarActions`** — `openInFinder`, `openInTerminal`, `removeTab`
  side-effects. Kept outside SwiftUI so they're isolated.
- **`TabCommands`** — Tab menu with ⌥↑ Previous, ⌥↓ Next, ⌘W Close Tab.

### `Loom/App`
- **`LoomApp`** mounts `TabCommands` alongside `DebugMenu`.
- **`SidebarSessionsLayout`** (new HStack root): `SidebarView` left,
  main pane right. Main pane mirrors Phase 3's ZStack of
  `AgentTerminalSurface`, with `selectedTabHasNoSession` state when a
  sidebar selection has no live agent.
- **`AppServices`** grew `tabStore` (TabStore), `tabs` (TabsModel,
  hydrated on construction), `worktreeManager` (WorktreeManager()).
- **`DebugMenu`'s `+ New Session…`** routes through TabStore + reload
  so the sidebar updates immediately.

---

## 2. Test summary

```
Executed 155 tests, with 1 test skipped and 0 failures (0 unexpected)
```

154 unit + 1 conditional integration skip. All 21 test suites green.
`swiftlint --strict` 0 violations. `swiftformat --lint` clean. `make build` ✅.

New test suites in Phase 4:
- `TabRowViewModelTests` (9 tests)
- `TabStoreTests` (7 tests)
- `TabsModelTests` (9 tests)

---

## 3. Deviations from the spec

### 3.1 Snapshot tests are logic-based, not pixel-based
Spec AC #7: *"Snapshot tests for sidebar row rendering across short/long titles, missing branch, all status states (stubbed)."*

I implemented "snapshot tests" as value-type assertions on `TabRowViewModel` (9 tests covering all the combinatorics the spec calls out: task-vs-ad-hoc title, branch line, short vs long worktree paths, PR vs issue vs no badge, default placeholder status). Pixel-based snapshots would require pulling in `pointfreeco/swift-snapshot-testing` — useful long-term but premature for Phase 4, especially because:

1. The view model is the actual variability surface; the SwiftUI rendering is straightforward and unlikely to silently regress.
2. Pixel snapshots are flaky across macOS versions and renderer changes.

If you'd rather have real pixel snapshots, happy to add the dep in a small follow-up.

### 3.2 Filtered list disables drag-to-reorder
Reordering filtered indices would corrupt the canonical `position` values. `.onMove` is a no-op when `debouncedQuery` is non-empty. The user must clear the search to reorder.

### 3.3 Performance ACs (#1, #4) rely on manual Instruments
The 60-fps-at-20-tabs criterion and the "no UI hang at 200 tabs" criterion are described in the spec as Instruments-verified. The architecture supports both (List virtualisation; debounced filter; pure-function row model). Formal Instruments traces are deferred to a manual smoke pass — see §4.

---

## 4. How to verify (manual smoke)

The new sidebar is the only Phase 4 surface that needs a real window. Build (`make build`), launch the app, then:

1. Empty sidebar shows the "No tabs yet" placeholder with the CTA text.
2. **Debug → Add Tracked Repo…** add a repo (you'll need to manually set its `local_main_path` in `loom.sqlite` for now — Phase 8 adds proper UI). For a quick smoke without a real repo, **Debug → + New Session…** still works for ad-hoc tabs.
3. Click the sidebar "+" button (or ⌘T). NewTabSheet opens. Pick a repo, type a branch name (e.g. `scratch/foo`), pick an agent, click "Open Tab". The worktree gets created at `<parent>/.worktrees/scratch-foo`, the tab appears in the sidebar, the agent spawns. _AC #2 — selection latency should be visibly instantaneous._
4. Open ~20 sessions. Scroll the sidebar; should feel smooth. Open Instruments → Time Profiler / Animation if you want a formal 60-fps measurement. _AC #1._
5. Type into the search field. Filtering kicks in after ~150 ms. With many tabs the UI should remain responsive while typing. _AC #4._
6. Drag a row up or down (cursor over the row, then drag). Order persists; close and relaunch — same order survives. _AC #3._
7. Right-click a row: **Open in Finder** opens Finder at the worktree; **Open in Terminal.app** opens Terminal at the worktree; **Remove…** confirms and drops the row + session. _AC #6._
8. ⌥↑ / ⌥↓ moves the selection up / down. ⌘W closes the selected tab (with confirm). ⌘T opens the New Tab sheet.

---

## 5. Open questions

1. **Pixel snapshots** — happy with the logic-based assertions, or add `swift-snapshot-testing` and produce real PNG snapshots for the row variants?
2. **Repo `local_main_path` UX** — currently the user has to edit `loom.sqlite` directly to set it. Worth adding a quick fix-up in the debug menu now (one extra prompt on "Add Tracked Repo…"), or wait for Phase 8 Preferences?
3. **Performance Instruments traces** — want me to record reproducible 20-tab and 200-tab traces as part of this phase's evidence, or defer to Phase 8 polish?

---

## 6. What's next

Phase 5 — Main pane wiring (GitHub WebView + the segmented control between Terminal / GitHub / Diff). The Terminal half is mostly already live from Phase 3; Phase 5 adds the GitHub WebView and the segmented control. Awaiting explicit approval before any Phase 5 code.

---

**STOP.** Phase 4 complete. Review and approve to proceed to Phase 5?
