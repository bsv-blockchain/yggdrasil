# Loom

Native macOS app that replaces a heavy `Chrome + Warp` developer workflow with one fast, native window: assigned-task sidebar, embedded Claude Code terminal in a fresh git worktree per task, GitHub WebView, and a libgit2-powered diff.

Status: **early development.** See [`loom-spec.md`](loom-spec.md) for the full build plan. Phase 0 (foundation) is the only phase merged so far.

---

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15.0+ (project builds against macOS 14 SDK on Swift 5.10+; tested with Xcode 26 / Swift 6 toolchain)
- Homebrew

## First-time setup

```bash
make install-tools     # brew installs xcodegen, swiftlint, swiftformat, libgit2,
                       # runs xcodebuild -runFirstLaunch and downloads MetalToolchain
make project           # generate Loom.xcodeproj from project.yml
make build             # xcodebuild build
make test              # xcodebuild test (LoomTests bundle)
```

## Project layout

See [`loom-spec.md`](loom-spec.md) §3.3. Source lives under `Loom/`, tests under `Tests/`, the libgit2 system-library wrapper under `Vendor/Clibgit2/`.

## Phase progress

`.loom-build-state.json` is the machine-readable build state.
`coverage-ledger.md` is the human-readable per-phase acceptance-criterion log.
`decisions.md` records spec deviations.
`phase-N-report.md` files accumulate at the end of every phase.

## Contributing

Phase work happens on branches named `phase-N/<short-description>` inside `.worktrees/`. Each phase ends with a checkpoint per spec §0.2; do not start Phase N+1 until Phase N is approved.
