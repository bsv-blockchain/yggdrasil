# Bracket tab-switch shortcuts (⌘⇧[ / ⌘⇧]) with wrap

**Date:** 2026-07-01
**Status:** Approved, ready for implementation plan

## Summary

Add the macOS-standard tab-switching keyboard shortcuts to Yggdrasil:

- `⌘⇧[` — previous tab
- `⌘⇧]` — next tab

These are the same keys used by Safari, Terminal, Warp, and GoLand. Selection
**wraps** at both ends (past the last tab → first tab; before the first → last).
The existing `⌥↑` / `⌥↓` tab-navigation shortcuts keep working alongside the new
ones.

### Key semantics (not a typo)

`⌘⇧[` is physically Cmd+Shift+`[`. Shift+`[` prints `{`, so "cmd+shift+[" and
"cmd+{" are the same physical key press. The binding is expressed as base key
`[` + an explicit `.shift` modifier, **not** the character `{` — AppKit matches
key equivalents on base-key + modifier flags, so this fires on the physical
Cmd+Shift+[ the user presses and the menu renders it as `⌘⇧[`.

Direction follows the universal convention: `⌘⇧[` = previous (left),
`⌘⇧]` = next (right).

## Current behavior

- `Yggdrasil/Features/Sidebar/TabCommands.swift` — a SwiftUI `Commands` group
  folded into the View menu after "Show Sidebar". Currently binds:
  - `⌥↑` → "Previous Tab" → `services.tabs.moveSelection(by: -1)` then syncs
    `services.sessions.selectedID = tabs.selectedID`.
  - `⌥↓` → "Next Tab" → `moveSelection(by: 1)` + same sync.
  - `⌘W` → "Close Tab…", `⌘T` → new tab (bound elsewhere). Unchanged by this work.
- `Yggdrasil/Features/Sidebar/TabsModel.swift:179` — `moveSelection(by:)`
  **clamps** the target index to `0 ... (tabs.count - 1)`; it does not wrap.
- `⌘⇧[` / `⌘⇧]` are currently unbound — no collision anywhere in the codebase.

## Design

Chosen approach (of three considered): **brackets become the visible menu
shortcuts; the arrow shortcuts are preserved as hidden shortcut buttons.**
Rationale: SwiftUI menu items allow only one `keyboardShortcut` each. Showing
the bracket shortcuts in the menu keeps them discoverable and matches the
platform norm and the user's muscle memory, while the arrows stay live via
zero-footprint hidden buttons — a clean 2-item menu with both bindings working.

Alternatives rejected:
- **Four menu items** (both shortcuts as separate visible commands) — simplest
  code but a redundant, amateurish menu.
- **NSEvent local monitor in AppDelegate** — brackets invisible (not
  discoverable) and requires hand-managing focus edge cases (text fields);
  more code, more foot-guns.

### 1. Wrap — `TabsModel.moveSelection(by:)` (`TabsModel.swift:179`)

Replace the clamp with a true modulo wrap:

```swift
func moveSelection(by delta: Int) {
    guard !tabs.isEmpty else { return }
    let count = tabs.count
    let currentIdx = tabs.firstIndex(where: { $0.id == selectedID }) ?? 0
    // True modulo: Swift `%` keeps the sign of the dividend, so add `count`
    // before the final `%` to handle negative deltas (wrap past the top).
    let newIdx = ((currentIdx + delta) % count + count) % count
    if let id = tabs[newIdx].id { select(id) }
}
```

This changes both the new bracket shortcuts and the existing `⌥↑`/`⌥↓` to wrap
— intended and desired.

### 2. Menu shortcuts — `TabCommands.swift`

Change the two visible buttons' shortcuts (action bodies unchanged):

- "Previous Tab" → `.keyboardShortcut("[", modifiers: [.command, .shift])`
- "Next Tab" → `.keyboardShortcut("]", modifiers: [.command, .shift])`

### 3. Preserve ⌥↑ / ⌥↓ — hidden shortcut buttons

Inject two zero-footprint, `.hidden()` buttons carrying the arrow shortcuts into
the window's root content so they are always in the responder chain. Location:
`Yggdrasil/App/YggdrasilApp.swift` window root (around line 117), via
`.background { … }`:

```swift
.background {
    Button("") { selectTab(by: -1) }
        .keyboardShortcut(.upArrow, modifiers: [.option]).hidden()
    Button("") { selectTab(by: 1) }
        .keyboardShortcut(.downArrow, modifiers: [.option]).hidden()
}
```

### 4. Shared selection-sync helper

The menu buttons and the hidden buttons perform the same two steps:
`tabs.moveSelection(by:)` then `sessions.selectedID = tabs.selectedID`. Factor
this into one small shared helper (e.g. a `selectTab(by:)` on the relevant
services/actions type, alongside the existing `SidebarActions`) so the menu
commands, the hidden buttons, and any future caller share a single
implementation and the selection-sync logic can't drift apart.

### 5. Terminal key interception

`Yggdrasil/Features/MainPane/YggdrasilTerminalView.swift:40` only swallows
events whose modifier set is *exactly* `.shift`. `⌘⇧[` carries `.command`, so it
is not intercepted there; menu-command key equivalents take priority over the
first responder regardless. **Runtime verification required:** with focus inside
a terminal/agent pane, confirm `⌘⇧[` / `⌘⇧]` still switch tabs (not swallowed by
the embedded terminal).

## Testing

Unit tests — `Tests/Unit/Sidebar/TabsModelTests.swift`:

- `testMoveSelectionUpClampsAtTop` (`:63`) asserts the old clamp behavior and is
  now wrong. Rename to `testMoveSelectionUpWrapsToBottom` and assert that moving
  up from the first tab selects the **last** tab.
- Add `testMoveSelectionDownWrapsToTop`: moving down from the last tab selects
  the **first** tab.
- Add a single-tab wrap case: `moveSelection(by:)` with one tab is a no-op
  (selection unchanged).
- Existing `testMoveSelectionDown` (`:54`) stays valid.

Manual/runtime verification:

- `⌘⇧[` / `⌘⇧]` switch tabs from the sidebar and from inside a focused terminal
  pane (see §5).
- Menu renders `Previous Tab ⌘⇧[` and `Next Tab ⌘⇧]`.
- `⌥↑` / `⌥↓` still switch tabs and now wrap.
- Wrap works at both ends; single-tab is a no-op.

## Edge cases

- Empty tab list — early `guard !tabs.isEmpty` return (already present).
- Single tab — wrap resolves to the same index; no-op.

## Out of scope

- Numbered jump shortcuts (`⌘1`–`⌘9`).
- Drag-to-reorder changes.
- Grouped-view ("group by repo") ordering: next/prev walks the flat persisted
  `tabs` order, identical to today's behavior — unchanged.

## Files touched

- `Yggdrasil/Features/Sidebar/TabsModel.swift` — clamp → wrap; shared helper (or
  helper added alongside `SidebarActions`).
- `Yggdrasil/Features/Sidebar/TabCommands.swift` — bracket shortcuts.
- `Yggdrasil/App/YggdrasilApp.swift` — hidden arrow-shortcut buttons.
- `Tests/Unit/Sidebar/TabsModelTests.swift` — wrap tests.

No schema, persistence, or `project.yml` changes.
