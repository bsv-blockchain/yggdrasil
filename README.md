# Yggdrasil

A native macOS app for developers who live in `Claude Code + GitHub + git
worktrees` all day. One window, one tab per task, embedded coding-agent
terminal that survives app restart, sidebar driven by your assigned GitHub
work.

Replaces a Chrome window + Warp + a stack of worktrees with something
faster, single-purpose, and keyboard-driven.

![status](https://img.shields.io/badge/platform-macOS%2014%2B-blue) ![swift](https://img.shields.io/badge/Swift-6-orange) ![ci](https://img.shields.io/badge/build-make%20build%20%2F%20make%20test-success)

---

## Why

If you spend the day moving between:

- A Chrome tab per assigned PR / issue
- A Warp tab per worktree
- A `claude` (or `codex` / `gemini` / `grok`) session per task
- `git diff` in three places

… Yggdrasil collapses all of that into one window. Each sidebar row is a
task; selecting it gives you Terminal · GitHub · Diff for that task's
worktree, with the right agent already running.

## Headline features

### Sidebar — task-driven workflow

- Sync'd with GitHub every 60 s. Rows for every open issue assigned to you,
  every PR you authored, every PR you've been asked to review.
- Filter pills (All / Active / PRs / Issues), live search, drag-and-drop
  reorder.
- Per-row status pip — running / awaiting input / dirty tree / CI failing /
  unread comments — driven by the live agent state + a 60 s GitHub poll.
- Right-click → Open in Finder / Open in Terminal.app / Remove (with an
  optional "delete worktree too" dialog).

### Embedded agent terminal — tmux-backed survival

- Every tab spawns the agent (default: `claude --dangerously-skip-permissions`)
  inside a tmux session named `yggdrasil-tab-<id>` on a private socket
  (`tmux -L yggdrasil`). The tmux daemon owns the agent process, so closing
  Yggdrasil — even ⌘Q — leaves agents running in the background.
- On next launch every existing tab re-attaches: same PID, same scrollback,
  same in-flight tool calls.
- Menu bar status item (Yggdrasil tree) lists every running agent and
  exposes a `Close and kill all` that explicitly tears them down.
- Mouse-wheel scroll forwards to tmux's copy-mode so you can walk the
  agent's real history. Text selection emits OSC 52 → macOS pasteboard.
- macOS Terminal.app / Warp-style theme: SF Mono 13pt, GitHub Dark-style
  ANSI palette.
- Per-agent worktree naming (`claude-pr-643`, `codex-pr-643`) lets the same
  PR host parallel agents in non-conflicting worktrees.

### GitHub & diff panes

- GitHub WebView is a persistent `WKWebView` with a `WKWebsiteDataStore` —
  log in once, stay logged in across launches.
- Native diff (`git diff base...HEAD` rendered through bundled `diff2html`)
  with syntax highlighting.
- Multi-pane split: any combination of Agent / GitHub / Diff side-by-side,
  draggable HSplitView. Layout persists in `UserDefaults`.

### Pickers — get to a tab in two clicks

- **Open Assigned** (`⌘O`) — sheet with every assigned issue + every PR you
  authored that isn't already a tab. Pick one → opens it with the default
  agent in a fresh worktree.
- **Review** pill (window chrome) — appears whenever PRs are waiting on
  your review. Click → same picker, filtered to review-requested.
- **My Issues** (`⌘⇧I`) — wide native `Table` view of every issue assigned
  to you across all of GitHub (not just tracked repos). Columns are
  resizable + sortable; shows Linked PR (heuristic), Milestone, Labels,
  Reviewer state.

### Menu bar + main menus

- Menu bar status item with a list of every live tmux session.
- `Coding` top menu (`NSMenu`, not SwiftUI) — Add/Remove Tracked Repo, Force
  Sync Now, Dump Tasks to Log, Add/Remove/Default Agent, + New Session.
  Items survive SwiftUI menu rebuilds via tag-based re-install on
  `applicationDidBecomeActive`.

### Performance

- All tabs are mounted at app launch, hidden via `opacity 0`. Tab switching
  is instant — no PTY respawn, no GitHub re-load, no diff re-parse.
- `WebViewPool` keeps every tab's `WKWebView` resident for the app's
  lifetime (no LRU eviction).
- Window position survives across launches; a one-shot rescue centers any
  window restored onto a now-detached monitor.

---

## Requirements

- **macOS 14 (Sonoma)** or newer
- **Xcode 16+** (project targets Swift 6 / macOS 14 SDK; tested with
  Xcode 26 toolchain)
- **Homebrew** — install with [brew.sh](https://brew.sh)
- **`tmux`** on `PATH` — agents survive app close via tmux's daemon. Without
  it the app still runs but agents die on quit. Install via
  `brew install tmux`.
- **`gh` CLI** authenticated as your GitHub user — Yggdrasil shells out to
  `gh auth token` on first request and caches in memory. Run `gh auth login`
  once if you haven't.
- **`libgit2`** (used by `Clibgit2` Swift system-library wrapper) — installed
  by `make install-tools`.

---

## First-time setup

```bash
git clone git@github.com:bsv-blockchain/yggdrasil.git
cd yggdrasil

make install-tools     # brew xcodegen swiftlint swiftformat libgit2 create-dmg
                       # xcodebuild -runFirstLaunch
                       # xcodebuild -downloadComponent MetalToolchain
make project           # generate Yggdrasil.xcodeproj from project.yml
make build             # xcodebuild build
make test              # full unit-test suite (209 tests + 1 conditional integration skip)
make lint              # swiftlint --strict

open ~/Library/Developer/Xcode/DerivedData/Yggdrasil-*/Build/Products/Debug/Yggdrasil.app
```

On first launch the onboarding sheet walks you through:

1. Detecting `gh` and (if needed) `gh auth login`.
2. Adding your first tracked repo and its local clone path.

Both can be done later in **Preferences → Repos** and **Preferences →
Agents**. The default coding agent is Claude
(`claude --dangerously-skip-permissions`); add more profiles in Preferences
→ Agents (Codex, Gemini, Copilot, Grok are recognised by command name and
get their proper brand icons automatically).

---

## Day-to-day use

### Keyboard

| Action | Shortcut |
|---|---|
| New session (Agent Picker sheet) | `⌘T` |
| Open assigned issue / PR | `⌘O` |
| My Issues (wide table view) | `⌘⇧I` |
| Force sync now | `⌘⇧S` |
| Previous / Next tab | `⌥↑` / `⌥↓` |
| Close tab | `⌘W` |
| Show sidebar / hide sidebar | `⌘⌃S` (system) |
| Preferences | `⌘,` |

### Mouse

- Sidebar row drag-and-drop reorder (when not filtered)
- Sidebar row right-click → context actions
- Terminal scroll wheel → tmux's copy-mode (scrolls agent history)
- Terminal drag-select → copy to system clipboard via OSC 52
- Menu bar status item → list running agents, kill individuals, kill all + quit

### Worktree convention

New worktrees live at `<repoPath>/.worktrees/<branch-slug>`, so multiple
tracked repos can hold the same PR number without colliding. Branch slugs
include the agent name (`claude-pr-643`, `codex-pr-643`) so the same PR can
host parallel agents in their own workspaces.

`.worktrees/` is added to each repo's `.git/info/exclude` automatically
(never `.gitignore` — that file isn't ours to mutate). Pre-rename worktrees
under the old `<repoParent>/.worktrees/` path continue to work; only newly
created ones use the in-repo layout.

### Resume

When the app re-attaches to an existing tmux session, you pick up where you
left off — same agent process, same scrollback. When a session is gone (you
killed it, or a `tmux kill-server` happened out of band) Yggdrasil spawns a
fresh agent. For Claude specifically, it auto-appends `--continue` when
there's a transcript at `~/.claude/projects/<encoded-cwd>/*.jsonl`, so
conversation history is restored.

---

## Architecture

Two-line summary: **SwiftUI app, GRDB SQLite for sync state, tmux for
agent process survival.** The detailed cut:

| Layer | What's there |
|---|---|
| `Yggdrasil/App` | `YggdrasilApp` (SwiftUI App), `AppDelegate`, `AppServices` dependency graph, AppKit `CodingMenuController`, `DebugMenuPrompts` |
| `Yggdrasil/Core/Auth` | `AuthService` (shells out to `gh auth token`), `Subprocess` runner |
| `Yggdrasil/Core/GitHub` | `RESTClient` + `GraphQLClient`, `Endpoints`, `TaskSyncService` (assigned issues + review-requested + authored PRs), `ETagStore`, `BackoffRetry` |
| `Yggdrasil/Core/Git` | `GitRunner`, `WorktreeManager`, `FileLock` for cross-process serialisation |
| `Yggdrasil/Core/Terminal` | `CodingAgentRunner` (headless, kept for tests), `TmuxManager`, `OutputRingBuffer` |
| `Yggdrasil/Core/Storage` | GRDB models: `YggdrasilTask`, `Repo`, `YggdrasilTab`, `CodingAgent`, `SessionState`, `GitHubStatus`, `PRReviewRequest`, `PRAuthored`, `PRAssigned`. Migrations v1–v5 in `Migrations.swift` |
| `Yggdrasil/Core/Status` | `StatusPoller` aggregates per-tab status (`ClaudeStateDetector`, `GitStateProbe`) |
| `Yggdrasil/Core/Diff` | `DiffEngine` runs `git diff` and pipes JSON to the bundled diff2html |
| `Yggdrasil/Features/Sidebar` | `SidebarView`, `TabRow`, `TabsModel`, `NewTabSheet`, `AssignedTaskPicker`, `IssueDetailsPicker`, `SidebarActions` |
| `Yggdrasil/Features/MainPane` | `MainPaneView` (split-pane layouts), `AgentTerminalSurface`, `GitHubSubPane`, `WebViewPool`, `DiffSubPane`, `WindowChromeBar`, `YggdrasilTerminalView` (scroll-event interceptor) |
| `Yggdrasil/Features/MenuBar` | `MenuBarStatusScene` — SwiftUI `MenuBarExtra` + popover |
| `Yggdrasil/Features/Preferences` | `PreferencesScene` + `RepoPrefsPane` / `AgentPrefsPane` / `IntervalsPrefsPane` / `AppearancePrefsPane` |
| `Yggdrasil/UI` | `YggdrasilTheme` design tokens, `AgentIdentity` (per-agent brand mark) |
| `Vendor/Clibgit2` | SwiftPM system-library wrapper for Homebrew's libgit2 |

Data on disk:

- `~/Library/Application Support/Yggdrasil/yggdrasil.sqlite` — tasks, tabs,
  agents, session_state, sync membership tables
- `~/Library/WebKit/com.bsvassociation.yggdrasil/WebsiteData/` — pooled
  WebKit data store (login state, cookies, local storage)
- `~/.claude/projects/<encoded-cwd>/*.jsonl` — Claude's own per-cwd
  transcripts; Yggdrasil reads them only to decide whether to pass
  `--continue` on spawn

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Sidebar is empty after launch | Add tracked repos in Preferences → Repos (or `Coding → Force Sync Now` ⌘⇧S). |
| Tab opens but terminal shows `command not found: claude` | `claude` isn't in your login shell PATH. Yggdrasil spawns `$SHELL -l -i -c …` so `.zshrc` runs; confirm `which claude` from a fresh login shell. |
| "Repo not tracked — add it in Preferences → Repos to open as a tab" | The issue's repo isn't tracked. My Issues fetches all your assigned issues from GitHub but only tracked repos have local clones for worktree creation. |
| Agents die when I close the app | `tmux` isn't installed or isn't on PATH. `brew install tmux`. Survival requires the tmux daemon to outlive Yggdrasil. |
| Menu bar icon is huge / disappears | The status icon needs an explicit `NSImage.size`; this is the `YggdrasilMenuBarMark` imageset (not `YggdrasilMark`). If the menu bar item disappears entirely SwiftUI rebuilt the menu — `applicationDidBecomeActive` should re-install. |
| Settings popover stuck on "Preferences load after first launch." | The `Settings` scene reads `AppDelegate.services` via `@ObservedObject`; if you see the stub repeatedly the service graph failed to build — check Console for "Failed to build AppServices". |
| Stale GitHub login | Delete `~/Library/WebKit/com.bsvassociation.yggdrasil/WebsiteData/`. |
| Want to inspect everything | `log show --predicate 'subsystem == "com.bsvassociation.yggdrasil"' --last 5m --info` |

Direct DB peek:

```bash
sqlite3 ~/Library/Application\ Support/Yggdrasil/yggdrasil.sqlite \
    'SELECT id, owner, name, local_main_path FROM repo'

# Active tmux sessions on the Yggdrasil socket
tmux -L yggdrasil ls
```

---

## Releases & signing

Tagged releases (`v*.*.*` push) trigger `.github/workflows/release.yml`,
which builds a signed + notarised universal-binary `.app`, wraps it in a
DMG, and uploads to GitHub Releases. Apple Developer ID signing uses the
secrets shared with bsv-desktop:

- `APPLE_DEVELOPER_ID_CERT` (base64 .p12)
- `APPLE_DEVELOPER_ID_CERT_PASS`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASS` (app-specific password)
- `APPLE_TEAM_ID`

Helper scripts under `Scripts/`:

- `bundle-libgit2.sh` — copies the linked libgit2 into
  `Yggdrasil.app/Contents/Frameworks` and rewrites the binary's load
  command to `@rpath`, so released apps don't depend on Homebrew.
- `sign-and-notarize.sh` — deep-signs nested binaries, then the main
  bundle with `--options=runtime + --timestamp + entitlements`; submits
  for notarization; staples.
- `make-dmg.sh` — stages with `/Applications` symlink, produces
  `UDZO`-compressed DMG.

---

## Contributing

Phase work happens directly on `main`. Each commit:

```bash
make build            # xcodebuild build, ad-hoc signed
make test             # full unit-test suite
make lint             # swiftlint --strict
```

PRs for non-phase work are welcome; the CI workflow
(`.github/workflows/ci.yml`) runs all three on every push.

Source-of-truth spec: [`yggdrasil-spec.md`](yggdrasil-spec.md). Per-phase
reports in `phase-N-report.md`. Running log of spec deviations:
[`decisions.md`](decisions.md).

---

## License

TBD.
