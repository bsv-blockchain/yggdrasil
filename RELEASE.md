# Yggdrasil — Release Checklist

End-to-end "I want a notarised, signed `.dmg` of Yggdrasil" steps. Designed to be
re-runnable; everything that's automated lives in the `Makefile`.

## Prerequisites

- Apple Developer Program account with a "Developer ID Application" certificate
  installed in your login keychain.
- A `notarytool` keychain item: `xcrun notarytool store-credentials AC_PASSWORD
  --apple-id you@example.com --team-id <TEAMID> --password <app-specific-pwd>`.
- [`create-dmg`](https://github.com/create-dmg/create-dmg) installed
  (`brew install create-dmg`).

## One-time project changes

The Phase 0 + 8 builds use ad-hoc signing for local dev. Before the first real
release, edit `project.yml` so the `Yggdrasil` target's build settings carry your
team / signing identity:

```yaml
targets:
  Yggdrasil:
    settings:
      base:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application: Your Name (TEAMID)"
        DEVELOPMENT_TEAM: TEAMID
        ENABLE_HARDENED_RUNTIME: "YES"
```

Re-run `make project` so the regenerated `Yggdrasil.xcodeproj` picks these up.

## Cut-a-release steps

1. Bump `CFBundleShortVersionString` in `project.yml`, regenerate, commit.
2. `make test` — must be all green.
3. `make lint` — must be 0 violations.
4. Tag the release commit: `git tag v0.X.Y && git push --tags`.
5. Archive:
   ```bash
   xcodebuild archive \
     -project Yggdrasil.xcodeproj \
     -scheme Yggdrasil \
     -configuration Release \
     -archivePath build/Yggdrasil.xcarchive
   ```
6. Export an `.app`:
   ```bash
   xcodebuild -exportArchive \
     -archivePath build/Yggdrasil.xcarchive \
     -exportPath build/export \
     -exportOptionsPlist ExportOptions.plist
   ```
   (ExportOptions.plist must specify `method = developer-id`.)
7. Bundle as a DMG:
   ```bash
   create-dmg \
     --volname "Yggdrasil" \
     --window-size 600 400 \
     --icon "Yggdrasil.app" 175 200 \
     --app-drop-link 425 200 \
     build/Yggdrasil-$(git describe --tags).dmg \
     build/export/
   ```
8. Submit for notarisation:
   ```bash
   xcrun notarytool submit \
     build/Yggdrasil-$(git describe --tags).dmg \
     --keychain-profile AC_PASSWORD \
     --wait
   ```
9. Staple the ticket:
   ```bash
   xcrun stapler staple build/Yggdrasil-$(git describe --tags).dmg
   ```
10. Smoke-test the stapled DMG on a different macOS user account: download,
    open, drag into Applications, launch. No quarantine warning. Onboarding
    flows.

## GitHub OAuth login (passkey sign-in)

In-app GitHub sign-in uses an OAuth-App authorization-code flow over
`ASWebAuthenticationSession`. The system presents a Safari-backed sheet where
passkeys, security keys, and passwords all work natively — no special browser
entitlement required (see `decisions.md`, 2026-05-28). The resulting access
token is preferred over `gh auth token`.

### One-time: register the OAuth App

1. GitHub → Settings → Developer settings → **OAuth Apps** → New OAuth App.
2. Set **Authorization callback URL** to exactly:

       yggdrasil://oauth-callback

   (matches `GitHubOAuthConfig.defaultRedirectURI` and the `CFBundleURLTypes`
   scheme `yggdrasil` declared in `project.yml`.)
3. Note the **Client ID** and generate a **Client secret**.

Requested scopes: `repo`, `read:org` (`GitHubOAuthConfig.defaultScopes`).

### Supplying the credentials

Resolution order is env vars → Info.plist keys → empty (sign-in disabled).

- **Local dev** — export before launching:

      export YGGDRASIL_GH_OAUTH_CLIENT_ID=Iv1_xxx
      export YGGDRASIL_GH_OAUTH_CLIENT_SECRET=xxxxxxxx

- **Release build** — set the `GitHubOAuthClientID` / `GitHubOAuthClientSecret`
  Info.plist values (currently empty placeholders in `project.yml` →
  `targets.Yggdrasil.info.properties`). Inject them at build time rather than
  committing the secret. Re-run `make project` after editing `project.yml`.

When neither is set, `GitHubOAuthConfig.isConfigured` is false and the Account
preferences pane shows the Sign-in button disabled with an explanatory note.

### Using it

Preferences → **Account** → *Sign in to GitHub*. Authenticate with a passkey in
the system sheet; the token is stored and used for REST/GraphQL sync. *Sign Out*
clears it and falls back to the `gh` CLI token.

## Sparkle (auto-update) — V2

Sparkle isn't shipped in v0.1. Reserved `Info.plist` keys:

- `SUFeedURL` — placeholder for the appcast URL.
- `SUPublicEDKey` — placeholder for the public update key.

When wiring Sparkle, also add the `EdDSA` signing step before stapling.

## Post-release

- Bump the version in `yggdrasil-spec.md`'s "Status" line (or whatever the project
  tracker becomes).
- Update `docs/screenshots/*.png` if the UI changed.
- Drop the DMG into the GitHub release page (manual until a CI release
  workflow exists).
