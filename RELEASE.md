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

## Passkeys in the embedded panel (managed entitlement)

The right-hand GitHub panel is a `WKWebView`. By default WebKit **disables**
WebAuthn there, so github.com reports *"This browser or device is reporting
partial passkey support."* and passkey login/registration fails. Enabling it
requires the managed entitlement `com.apple.developer.web-browser.public-key-credential`,
which Apple grants only on request and which only activates when the app is
signed with a matching provisioning profile (ad-hoc signing is rejected at
build time — that's why it isn't in the default `Yggdrasil.entitlements`).

The passkey-enabled entitlements live in `Yggdrasil/Yggdrasil.passkeys.entitlements`
(base set + the capability). Switching the build over is the last step below.

**Requires a paid Apple Developer account with portal access** (team
`APPLE_TEAM_ID`). The repo side is done; the steps below need the project owner.

### Step 1 — Request the entitlement from Apple

1. The capability is **not** self-serve in Xcode's Signing & Capabilities list;
   it must be requested. Submit Apple's request form for the *Web Browser
   Public Key Credential* / *passkeys-in-WKWebView* entitlement:
   <https://developer.apple.com/contact/request/> (search "passkey" / "web
   browser public key credential"). Reference:
   - Entitlement: `com.apple.developer.web-browser.public-key-credential`
   - App ID / bundle id: `com.bsvassociation.yggdrasil`
   - Use case: third-party developer tool embedding a GitHub browser panel.
2. Wait for Apple approval (manual review). Until approved, nothing below works.

### Step 2 — Enable on the App ID + regenerate the profile

1. Apple → Certificates, Identifiers & Profiles → Identifiers →
   `com.bsvassociation.yggdrasil`: confirm the capability now appears and is on.
2. Regenerate the provisioning profile(s) you sign with (a **Development**
   profile for local testing on registered Macs; a **Developer ID** profile for
   distribution) so each includes the capability. Download them.

### Step 3 — Point the build at the passkey entitlements

In `project.yml`, under `targets.Yggdrasil.settings.base`, switch signing from
ad-hoc to the real team + the passkeys entitlements file:

```yaml
        CODE_SIGN_ENTITLEMENTS: Yggdrasil/Yggdrasil.passkeys.entitlements
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: <YOUR_TEAM_ID>
        CODE_SIGN_IDENTITY: "Apple Development"        # local test; Developer ID for dist
        PROVISIONING_PROFILE_SPECIFIER: "<profile name from Step 2>"
```

Then `make project` to regenerate `Yggdrasil.xcodeproj`. (For the notarised
release, the same `CODE_SIGN_ENTITLEMENTS` change applies to the `release.yml`
build step, which already sets `DEVELOPMENT_TEAM` + a Developer ID identity.)

### Step 4 — Build signed + verify

```bash
make build
```

Launch, open the GitHub panel, sign in to github.com. The "partial passkey
support" banner is gone and passkey login/registration works **inside the
panel**. This logs the panel's github.com web session in directly (cookies) —
separate from the OAuth API token below.

> Note: this is the in-panel path. The OAuth sign-in below (Account pane) is an
> independent way to get an API token via passkeys in a system sheet, and needs
> no entitlement. Keep whichever you want; they don't conflict.

## GitHub OAuth login (passkey sign-in)

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
