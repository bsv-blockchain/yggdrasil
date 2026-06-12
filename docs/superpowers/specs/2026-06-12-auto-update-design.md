# Auto-update for Yggdrasil (Sparkle)

**Date:** 2026-06-12
**Status:** Approved
**Branch:** `feat/auto-update`

## Goal

Yggdrasil checks `bsv-blockchain/yggdrasil` GitHub releases, and offers a
one-click "Install & Relaunch" update. The repo is **public** and release
assets (`Yggdrasil-X.Y.Z.dmg`) are anonymously reachable, and the app is
Developer ID-signed + notarized — the preconditions Sparkle needs.

## Decision

Use **Sparkle 2.9.3** (pinned). It owns the hard, risky parts: download →
EdDSA-verify → atomic swap of the running `.app` → relaunch, plus the update UI
and scheduled checks. Hand-rolling the running-bundle swap was rejected as more
code and more failure modes for no benefit.

## Architecture

### Framework
- Sparkle 2.9.3 added as an SPM dependency in `project.yml`, linked into the
  `Yggdrasil` target.

### App wiring (small surface)
- `UpdaterController` — a tiny `@MainActor` type wrapping
  `SPUStandardUpdaterController` (auto-starting). Held by `AppDelegate`.
- `UpdaterCommands` — a SwiftUI `Commands` group adding **"Check for Updates…"**
  to the app menu, wired to the controller, disabled while a check is in flight
  (`canCheckForUpdates`). Added to `YggdrasilApp.commands`.
- Automatic background checks enabled; Sparkle shows its own first-run
  "check automatically?" prompt.

### Info.plist keys (set via `project.yml` `info.properties`)
- `SUFeedURL` = `https://github.com/bsv-blockchain/yggdrasil/releases/latest/download/appcast.xml`
- `SUPublicEDKey` = committed EdDSA public key
- `SUEnableAutomaticChecks` = `true`
- `SUScheduledCheckInterval` = `86400` (daily)

`releases/latest/download/appcast.xml` always resolves to the newest
**published** (non-draft, non-prerelease) release's `appcast.xml` asset. Each
release ships an `appcast.xml` describing **itself** (one `<item>`) and pointing
at that release's own notarized DMG. Drafts never offer updates; publishing a
release flips the feed atomically.

### Signing keys
- One EdDSA keypair via Sparkle `generate_keys`.
- Public key → committed in Info.plist (`SUPublicEDKey`).
- Private key → GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`.

### CI (`release.yml`)
After the DMG is notarized + stapled, before creating the GitHub release:
1. Fetch pinned Sparkle CLI tools (`sign_update`).
2. `sign_update Yggdrasil-X.Y.Z.dmg` with the private key → EdDSA signature +
   byte length.
3. Render `appcast.xml` via `Scripts/generate-appcast.sh`, substituting:
   `sparkle:shortVersionString` (e.g. 0.5.0), `sparkle:version`
   (CFBundleVersion read from the **built** app's Info.plist),
   the release DMG URL, length, EdDSA signature, `sparkle:minimumSystemVersion`
   14.0, pubDate, and a release-notes link to the GitHub release page.
4. Upload `appcast.xml` alongside the DMG + `SHA256SUMS`.

### Deep-signing Sparkle's nested code
`Scripts/sign-and-notarize.sh` is extended to explicitly hardened-runtime-sign
Sparkle's nested helpers (XPCServices `*.xpc`, `Autoupdate`, `Updater.app`)
inside-out before signing the outer bundle — notary rejects improperly signed
nested executables.

### Makefile
`SPARKLE_VERSION := 2.9.3` as the single source of truth, shared by CI and any
local appcast tooling (mirrors the existing SwiftFormat/SwiftLint pinning).

## Testing (honest scope)

This feature is mostly config + a vendor framework; the unit-testable surface is
thin. Covered:
- **Appcast rendering** — XCTest integration test runs `generate-appcast.sh`
  with fixture inputs and asserts the output is well-formed XML (XMLParser) with
  the correct version/URL/signature/length fields.
- **Bundle config** — Swift unit test asserts the built bundle's Info.plist
  carries `SUFeedURL` (pointing at `bsv-blockchain/yggdrasil`) and a non-empty
  `SUPublicEDKey`.

Sparkle's download/verify/swap/relaunch is the framework's responsibility and is
verified end-to-end by an actual release + in-app update — not unit-tested.

## Known limitations

- **First update is the proof.** Auto-update is only verifiable end-to-end by
  cutting a release *after* this ships and updating into it. Users on 0.4.1 (no
  Sparkle) need one manual install to reach an updater-enabled build; updates
  are automatic thereafter.
- **Version ordering** uses `CFBundleVersion` (the build number). The existing
  bump discipline (project.yml + Info.plist in sync) keeps it monotonic; CI
  reads it from the built app so the appcast can't drift from the binary.
