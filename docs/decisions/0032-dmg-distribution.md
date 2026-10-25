# 0032. A notarized DMG for installing on other Macs

Status: Accepted
Date: 2026-10-25

## Context
The app was only ever run from `make run` on the development Mac. The user wants to install it on another Mac. A build signed with "Apple Development" is blocked by Gatekeeper elsewhere. A copied build only runs after its quarantine flag is stripped by hand. Notarization needs a Developer ID signature, the hardened runtime and a secure timestamp. The keychain already holds a "Developer ID Application" certificate for team RLUV35UZ26.

## Decision
- **`make dmg`:** builds the Release configuration as a universal binary (arm64 and x86_64) and packs the app with an `/Applications` link into `build/QuickLaunch-<version>.dmg`. It then signs the DMG, notarizes it with `notarytool` and staples the ticket.
- **Release signing in `project.yml`:** the Release config uses "Developer ID Application", the hardened runtime, `--timestamp` and `Sources/QuickLaunch/QuickLaunch.entitlements`. Debug is unchanged, so dev builds keep their Apple Development signature and the privacy grants tied to it.
- **Signing details found on the first run:**
  - Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. A plain `xcodebuild build` otherwise adds `get-task-allow`, and notarization rejects it.
  - `codesign` gets `--keychain` pointing at the login keychain, which holds the Developer ID identity. A locked keychain earlier in the search list can still trigger a password prompt. Clarity's CI keychain did this until the search list was reset to `login` only.
- **Entitlements:** only what the hardened runtime would otherwise block: Apple Events (System Events, Arc, terminals) and Calendars (decision 0024). The sandbox stays off.
- **Credentials:** `notarytool` reads a keychain profile, `quicklaunch-notary` by default (`NOTARY_PROFILE=` overrides it). It's created once with `xcrun notarytool store-credentials`. No secret lives in the repo.

## Consequences
- An installed copy has a different signature from the dev build. macOS treats them as different apps for Accessibility and Input Monitoring, so on the same Mac each needs its own grants.
- A new hardened-runtime restriction (camera, microphone, JIT, unsigned libraries) must be added to the entitlements file, or the Release build fails at runtime only. Check new OS-facing features with a `make dmg` build.
- There's still no auto-update; a new version is a new DMG.
