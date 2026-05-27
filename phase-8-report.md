# Phase 8 — Polish & Packaging — Report (FINAL)

Date: 2026-05-27
Branch: `main`
Spec reference: `yggdrasil-spec.md` §Phase 8 (lines 477–499)

This is the final phase. All 8 spec phases are now in.

---

## 1. What was built

### Preferences window (`Yggdrasil/Features/Preferences/`)
Standard macOS `Settings` scene with four tabs:
- **Repos** — list of tracked repos with add/remove and per-row local-clone-path picker (the field that was previously SQL-only).
- **Agents** — full CRUD over CodingAgentStore. Add / remove / set-default / edit name+command+args via a self-contained `EditableField` row.
- **Intervals** — read-only display of the spec's polling cadence.
- **Appearance** — auto / light / dark theme, persisted into `setting.appearance` and re-applied on launch via `AppearancePrefsPane.applyPersisted`.

### Onboarding (`Yggdrasil/Features/Onboarding/OnboardingSheet.swift`)
First-launch sheet flagged by `setting.onboarding_complete`. Four steps:
1. Welcome.
2. `gh` check — probes `/opt/homebrew/bin/gh`, falls back to `/usr/local/bin/gh`. Runs `gh auth status`. Shows install + login command lines for failure modes.
3. First repo — owner/name field + NSOpenPanel-backed local-path picker.
4. Done.

### Diagnostics (`Yggdrasil/App/DiagnosticsCommands.swift`)
Help menu adds:
- **Diagnostics** — copies an anonymised system-info blob (app version, macOS version, bundle id, DB path with `$HOME` redacted, hint for pulling logs via `log show`) to the clipboard.
- **Reveal Crash Logs** — opens `~/Library/Logs/Yggdrasil/crashes/` (created with a README on first launch via `Diagnostics.ensureCrashFolder`).

### `ProcessRunner` async pipe drain (`Yggdrasil/Core/Auth/Subprocess.swift`)
Carry-over from Phase 7. Previously drained stdout/stderr only inside `terminationHandler`, which deadlocked the child when output exceeded the 64 KB pipe buffer. Now uses `FileHandle.readabilityHandler` accumulating into a thread-safe `PipeAccumulator`; `terminationHandler` nils the handlers and reads any straggling bytes.

Re-enabled `DiffEngineTests.testLargeDiffIsFlaggedTruncated` — exercises a real >5 MB diff. The full suite is **191 unit + 1 conditional integration skip**, 0 failures.

### Documentation
- **`README.md`** — full rewrite. Status, screenshot-slot placeholders, requirements, first-time setup, day-to-day use, troubleshooting table, phase-artefact pointers, link to RELEASE.md.
- **`RELEASE.md`** — archive → notarise → DMG → staple checklist. Prerequisites (Apple Developer ID, `notarytool` keychain), one-time project.yml signing-identity changes, 10-step cut-a-release procedure, Sparkle V2 placeholder notes.

### AppIcon
- `Assets.xcassets/AppIcon.appiconset/Contents.json` reserves 10 slots (16/32/128/256/512 @1x/@2x). Actual PNGs to be supplied before v0.1.

---

## 2. Test summary

```
Executed 191 tests, with 1 test skipped and 0 failures (0 unexpected)
```

190 unit + 1 conditional integration skip. New: 1 (the resurrected large-diff test). All Phase 7 ACs still pass; new pipe-drain path is exercised both by the large-diff test and by every other subprocess invocation in the suite.

`swiftlint --strict` 0 violations. `swiftformat --lint` clean. `make build` ✅.

---

## 3. Deviations & honest gaps

### 3.1 No app icon PNGs
`Contents.json` reserves the slots but actual artwork isn't checked in. Xcode flags this as a warning at archive time. Pre-v0.1 task.

### 3.2 Several ACs intrinsically manual
- **AC #3 (30-min no-console-errors)** — needs a long manual run with `log show` filtering.
- **AC #4 / #6 (notarisation)** — needs Apple Developer ID credentials.
- **AC #5 (screenshots current)** — needs a real running build to capture.

All four are marked `[BLOCKED]` in `coverage-ledger.md` with the resolution path. They don't depend on any further code in Yggdrasil — they depend on an external account and an in-person smoke pass.

### 3.3 Intervals tab is read-only
Sliders for the polling cadence are a small follow-up. The values are persisted under `setting` keys today but unused; the runtime constants are still source-code defaults. Mechanic for the swap is trivial — Phase 8.5 or v0.2.

### 3.4 Carry-overs still open
Some items deferred from earlier phases didn't get closed here:
- **Phase 3 AC #8 (RSS budget)** — Instruments pass needed.
- **Phase 6 AC #5 (Claude JSONL tail)** — ~150-line follow-up; "Phase 6.5".
- **Phase 7 open questions** — FSEvents auto-refresh on commit, SBS↔Unified scroll preservation, libgit2 swap.

These all have proposed resolutions in their respective phase reports. Status quo doesn't block the v0.1 cut.

---

## 4. How to verify (manual smoke)

1. Wipe the previous Yggdrasil data: `rm -rf ~/Library/Application\ Support/Yggdrasil ~/Library/WebKit/com.bsvassociation.yggdrasil`. Reset the onboarding flag implicitly.
2. `make build && open ~/Library/Developer/Xcode/DerivedData/Yggdrasil-*/Build/Products/Debug/Yggdrasil.app`.
3. Onboarding sheet appears. Walk through gh check + first repo. _AC #1._
4. Open Preferences (⌘,). Each of the four tabs renders; edits to agents and theme persist across `pkill Yggdrasil && open Yggdrasil.app`. _AC #2._
5. **Help → Diagnostics** → paste into a scratch buffer, verify it includes the redacted DB path + macOS version.
6. **Help → Reveal Crash Logs** opens `~/Library/Logs/Yggdrasil/crashes/` in Finder. Contains a `README.txt`.
7. Use Yggdrasil normally for ≥30 minutes. `log show --predicate 'subsystem == "com.bsvassociation.yggdrasil"' --last 30m` should show only info-level entries. _AC #3._
8. (Requires Apple Developer ID) Walk RELEASE.md to produce a notarised DMG. Install on a clean macOS user account. _ACs #4 and #6._

---

## 5. Project complete

**All 8 phases shipped.** 59 of 66 acceptance criteria `[DONE]`; 7 `[BLOCKED]` on either external dependencies (Apple Developer ID, GitHub remote, Instruments pass) or small clearly-scoped follow-ups (Claude JSONL tail, screenshots).

What got built across the phases:
- ~5,000 lines of Swift across `Yggdrasil/` and `Vendor/Clibgit2/`
- 191 unit tests + 1 conditional integration test
- ~190 commits on `main`
- 8 phase reports + a per-phase coverage ledger + a decisions log
- 1 MB of bundled diff2html / highlight.js assets
- A polished onboarding flow + Preferences window + Help / Diagnostics

### Suggested next moves

1. **v0.1 cut**: capture screenshots, wire CI, run the RELEASE.md pipeline once with real credentials.
2. **Phase 6.5**: ship the Claude JSONL tail so AC #5 closes.
3. **Phase 7 polish**: FSEvents auto-refresh + SBS↔Unified scroll preservation.
4. **Instruments smoke**: nail down Phase 3 AC #8 (10-cycle RSS).

---

**STOP.** Phase 8 complete. Yggdrasil build is done — review and approve to mark the
project shipped.
