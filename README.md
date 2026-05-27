# Loom

A native macOS app that replaces the `Chrome + Warp` workflow for a heavy Claude
Code + GitHub developer with a single fast window. Assigned-task sidebar on the
left; per-tab `Terminal · GitHub · Diff` segmented pane on the right; one git
worktree + one coding-agent (Claude / Codex / Grok / …) process per tab.

Status: **all 8 phases complete and approved (Phase 7 awaiting final review at
time of writing).** Built phase-by-phase against [`loom-spec.md`](loom-spec.md);
per-phase reports in `phase-N-report.md`.

---

## Screenshots

_Add real screenshots before tagging v0.1:_

- `docs/screenshots/sidebar.png` — sidebar with sync'd tasks
- `docs/screenshots/agent.png` — embedded coding-agent session
- `docs/screenshots/github.png` — GitHub WebView segment
- `docs/screenshots/diff.png` — native diff view

---

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15+ (the project builds against the macOS 14 SDK; tested with Xcode 26
  / Swift 6 toolchain)
- [Homebrew](https://brew.sh)
- The `gh` CLI authenticated against your GitHub account (Loom uses it as the
  source of truth for tokens, never reads `~/.gh/...` directly)

## First-time setup

```bash
make install-tools     # brew installs xcodegen, swiftlint, swiftformat, libgit2;
                       # runs xcodebuild -runFirstLaunch + downloads the Metal toolchain
make project           # generate Loom.xcodeproj from project.yml
make build             # xcodebuild build
make test              # full unit-test suite (~190 tests)
```

On first launch the onboarding sheet walks you through:

1. Detecting `gh` and (if needed) `gh auth login`.
2. Adding your first tracked repo + its local clone path.

You can also do these later in **Preferences → Repos** and **Preferences →
Agents**. The default coding agent is Claude (`claude --dangerously-skip-permissions`);
add more profiles in Preferences → Agents.

## Day-to-day use

- **Sidebar** lists every assigned issue + PR. ⌘T opens a new tab via a sheet
  (pick repo + branch + agent). ⌥↑/↓ moves selection. ⌘W closes a tab.
- **Main pane** shows the selected tab as Terminal · GitHub · Diff. Terminal
  spawns the chosen coding agent in the tab's worktree. GitHub renders the
  task's URL in a pooled `WKWebView` (login persists). Diff renders
  `git diff base...HEAD` via the bundled `diff2html`.
- **Sidebar status icons** reflect dirty-tree / awaiting-input / CI-failing /
  unread-comments / running. Hover for tooltip.
- **Right-click a tab** for `Open in Finder` / `Open in Terminal.app` /
  `Remove`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sidebar is empty after launch | Add tracked repos in Preferences → Repos (or wait for the next `Debug → Force Sync Now`). |
| A tab's terminal stays empty | Check Console.app filtered to subsystem `com.bsvassociation.loom` — the agent's stderr is in there. |
| "Repo has no local clone path" when opening a tab | Preferences → Repos → Choose…  Loom can't create a worktree without the local clone. |
| Loom appears to hang | `Help → Diagnostics` copies a quick report to your clipboard; paste it into a bug report. |
| Stale GitHub login | The persistent web data store lives at `~/Library/WebKit/com.bsvassociation.loom/WebsiteData/`. Delete it to log out. |

For deeper inspection:

```bash
log show --predicate 'subsystem == "com.bsvassociation.loom"' --last 5m
sqlite3 ~/Library/Application\ Support/Loom/loom.sqlite \
    'SELECT id, owner, name, local_main_path FROM repo'
```

## Project layout

See [`loom-spec.md`](loom-spec.md) §3.3. Source under `Loom/`, tests under
`Tests/`, libgit2 system-library wrapper at `Vendor/Clibgit2/`, bundled
diff2html at `Loom/Resources/diff2html/`.

## Phase progress

- `.loom-build-state.json` — machine-readable build state (current phase, SHAs).
- `coverage-ledger.md` — human-readable per-phase acceptance-criterion log.
- `decisions.md` — running log of spec deviations with rationale.
- `phase-N-report.md` — full report per phase.

## Contributing

Phase work happens directly on `main` for now (see `decisions.md` for the
why). Each phase ends with a checkpoint per spec §0.2; don't start Phase N+1
until Phase N is approved.

For changes outside the phase plan, open a PR on `main` and run `make build &&
make test && make lint` before requesting review.

## Release

See [`RELEASE.md`](RELEASE.md) for the archive → notarise → DMG checklist.

## License

TBD.
