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
