# Phase 0 — Foundation — Report

Branch: `phase-0/foundation`
Worktree: `.worktrees/phase-0-foundation/`
Date: 2026-05-26
Spec reference: `loom-spec.md` §Phase 0 (lines 226–251)

---

## 1. What was built

### Repository structure (§3.3)
- Created the full `Loom/`, `Core/<sub>`, `Features/<sub>`, `UI/`, `Resources/`, and `Tests/<sub>` tree per the spec. Empty directories carry a `.gitkeep` so the structure survives commit.

### Project authoring
- `project.yml` (XcodeGen spec) is the source of truth.
- `make project` regenerates `Loom.xcodeproj`. The generated project is also committed so `xcodebuild` works without XcodeGen installed.
- Single app target `Loom` (macOS 14, Swift 5.10, hardened runtime, ad-hoc signing for local dev).
- `Loom.entitlements`: network client + user-selected file access; **no App Sandbox** (rationale in `decisions.md`).

### Code
- `Loom/App/LoomApp.swift` — `@main` SwiftUI App vending a single `WindowGroup` titled "Loom" containing a `RootView` placeholder.
- `Loom/App/AppDelegate.swift` — `NSApplicationDelegate` with launch/terminate logging; quits after last window closes.
- `Loom/Core/Logging/LoomLogger.swift` — `LoomLog` namespace exposing `os.Logger` for the six subsystem categories required by the spec: `sync`, `pty`, `git`, `ui`, `db`, `auth`. Subsystem string `com.bsvassociation.loom` matches the app bundle identifier.
- `Loom/Core/DependencySmokeImports.swift` — imports all four dependencies and calls a libgit2 symbol to prove dynamic linkage (not just import-resolution).

### Dependencies (resolved by SwiftPM)
| Package | Version | Source |
|---|---|---|
| SwiftTerm | 1.13.0 | `github.com/migueldeicaza/SwiftTerm` |
| GRDB.swift | 6.29.3 | `github.com/groue/GRDB.swift` |
| KeychainAccess | 4.2.2 | `github.com/kishikawakatsumi/KeychainAccess` |
| Clibgit2 | (local) | `Vendor/Clibgit2/` — `.systemLibrary` over Homebrew `libgit2 1.9.4` |

### Tests
- `Tests/Unit/SmokeTests.swift` — 5 tests in the `LoomTests` bundle:
  1. `testAppVendsAWindowTitledLoom` — verifies a window titled "Loom" exists (runs in-process, host = `Loom.app`).
  2. `testBundleIdentifierMatchesSpec` — verifies bundle ID = logger subsystem.
  3. `testDependencySmokeImportsAllFourPackages` — checks the resolved-package list.
  4. `testLibgit2LinksAndReportsAVersion` — calls `git_libgit2_version` and verifies the format.
  5. `testLoggerSubsystemHasExpectedCategories` — verifies all six categories are registered.
- No UI test target in Phase 0. The spec mandates UI tests "for sidebar interactions (Phase 4+)", and adding one for the empty placeholder window required `XCUITest` automation permission to be granted via System Settings, which is interactive and brittle in CI. An in-process unit test against `NSApplication.shared.windows` covers the AC equally well and runs reliably under `xcodebuild test`.

### Build tooling
- `Makefile` with `build`, `test`, `lint`, `format`, `project`, `install-tools`, `clean` targets.
- `.swiftformat` — Swift 5.10, 4-space indent, max width 120, sorted imports, trailing-comma-strip. SwiftFormat reports 0/5 files need formatting.
- `.swiftlint.yml` — opt-in rules: empty_count, empty_string, explicit_init, first/last_where, sorted_first_last, toggle_bool. Analyzer rules: unused_import, unused_declaration. line_length / trailing_comma disabled (SwiftFormat owns them). `swiftlint --strict` reports 0 violations.

### CI
- `.github/workflows/ci.yml` on `macos-latest`, runs on push/PR to `main`:
  1. Install xcodegen / swiftlint / swiftformat / libgit2 via Homebrew
  2. `xcodebuild -runFirstLaunch` + Metal toolchain download
  3. Cache SwiftPM
  4. `make project` → `swiftformat --lint` → `make lint` → `make build` → `make test`

### State files
- `.loom-build-state.json` — `current_phase: 0`, started_at set, last_git_sha to be set at commit.
- `coverage-ledger.md` — populated with Phase 0 criteria + evidence.
- `decisions.md` — three entries: SwiftGit2 → system-libgit2 swap; XcodeGen choice; no App Sandbox.

---

## 2. Deviations from spec

### 2.1 SwiftGit2 → local `Clibgit2` system module (substantive)
Upstream `SwiftGit2/SwiftGit2` does not ship a `Package.swift` on any branch (`master`, `release-2.0`, `xcode-15`, `applesilicon-support`) or tag (`v0.1`–`v0.3`, `0.4.0`–`0.6.0`). Verified by HTTP probe. No maintained SwiftPM-compatible community fork was located. Replaced with a local SwiftPM package wrapping system libgit2 from Homebrew. Decision logged in `decisions.md` and approved by the human at boot.

### 2.2 XcodeGen as the project source of truth (mechanical)
Spec mandated a committed `Loom.xcodeproj` but didn't say how to maintain it. I chose XcodeGen with both `project.yml` and the generated `Loom.xcodeproj` committed. The pbxproj is reproducible. Logged in `decisions.md`.

### 2.3 No UI test target in Phase 0 (within-spec)
Spec says UI tests start Phase 4. I considered adding one for the placeholder window but the macOS `XCUITest` "automation permission" prompt is interactive and unreliable in headless CI. The in-process unit test against `NSApplication.shared.windows` covers the same AC. Will revisit when Phase 4 brings real UI to test.

---

## 3. Test results

### Local: `xcodebuild test` (5 tests)
```
Test Suite 'All tests' started at 2026-05-26 19:17:58.806
Test Suite 'LoomTests.xctest' started at 2026-05-26 19:17:58.807
Test Suite 'SmokeTests' started at 2026-05-26 19:17:58.807
Test Case '-[LoomTests.SmokeTests testAppVendsAWindowTitledLoom]' passed (0.001s)
Test Case '-[LoomTests.SmokeTests testBundleIdentifierMatchesSpec]' passed (0.000s)
Test Case '-[LoomTests.SmokeTests testDependencySmokeImportsAllFourPackages]' passed (0.001s)
Test Case '-[LoomTests.SmokeTests testLibgit2LinksAndReportsAVersion]' passed (0.001s)
Test Case '-[LoomTests.SmokeTests testLoggerSubsystemHasExpectedCategories]' passed (0.000s)
Test Suite 'SmokeTests' passed at 2026-05-26 19:17:58.811
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
** TEST SUCCEEDED **
```

Also confirmed via `Loom did finish launching (pid=…)` line in the log — proves AppDelegate fires and the SwiftUI scene comes up under TEST_HOST.

### Local: `swiftlint --strict`
```
Done linting! Found 0 violations, 0 serious in 5 files.
```

### Local: `swiftformat --lint`
```
0/5 files require formatting, 5 files skipped.
```

### CI on GitHub
`[BLOCKED]` until the repo has an `origin` remote. Workflow is committed and ready.

---

## 4. Open questions for the human

1. **Push to a GitHub remote** — `bsv-blockchain/loom`? Personal account? Loom is your own project so I default to recommending a personal account remote first; we can transfer later. CI's green-light AC #4 unblocks the moment the workflow runs there.
2. **Bundle ID** — locked to `com.bsvassociation.loom`. If you'd prefer a different reverse-DNS prefix, easiest to swap before signing arrives in Phase 8.
3. **Developer ID for signing** — not needed until Phase 8; flagging so it's on the radar.
4. **SwiftTerm Metal toolchain on CI** — I added `sudo xcodebuild -downloadComponent MetalToolchain` to CI. It adds ~2 min to the first cached CI run. If you'd rather drop the Metal renderer (SwiftTerm has CoreText fallback), Phase 3 can revisit; for now it stays.

---

## 5. What's next

Phase 1 — GitHub sync engine. Will not start until you explicitly approve this phase.

---

**STOP.** Phase 0 complete. Review and approve to proceed to Phase 1?
