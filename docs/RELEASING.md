# Releasing Buddy

1. Bump `VERSION` (for example `0.2.1`).
2. Run `./scripts/build-app.sh`. It builds `build/Buddy.app`.
   - `CFBundleShortVersionString` comes from `VERSION`.
   - `CFBundleVersion` is the build time (`YYYYMMDDhhmm`).
3. Run `./scripts/make-dmg.sh`. It builds `build/Buddy-<version>.dmg`: Buddy.app plus an Applications link, UDZO compressed, signed with the same identity.
4. Check the DMG: `hdiutil attach -nobrowse build/Buddy-<version>.dmg`, look at the contents, then `hdiutil detach`.
5. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new `[<version>]` heading with the date.
6. Commit, then tag: `git tag v<version> && git push origin main v<version>`.
7. Make the GitHub release for `v<version>` and attach the DMG: `gh release create v<version> build/Buddy-<version>.dmg`.
8. Update the Homebrew cask: follow "Update for each release" in [HOMEBREW.md](HOMEBREW.md).
9. Share the DMG. Users follow [INSTALL.md](INSTALL.md) ("Team install").

## Local dev install

`scripts/install-local.sh` builds and installs a local build into `/Applications` (see [INSTALL.md](INSTALL.md)). It moves the old app to the Trash. It does not make a DMG and does not notarize.

## Signing identity

`scripts/sign-identity.sh` picks the identity, in this order:

1. `$BUDDY_SIGN_ID`, if set.
2. The first "Developer ID Application" identity in the keychain.
3. A "Buddy Dev" identity (self-signed, see INSTALL.md).
4. Ad hoc, with a warning.

- The hardened runtime is always on.
- Only the app gets `Resources/Buddy.entitlements` (Apple Events for Jump). `buddy-hook` gets no entitlements.
- `--timestamp` is added only for a Developer ID identity.

## Later: notarization

A Developer ID certificate (Apple Developer Program) plus `notarytool` and `stapler` would remove the Gatekeeper "Open Anyway" step.
It would also keep one signing identity across releases, so macOS would keep the Accessibility permission after updates.
The scripts already pick a Developer ID and add `--timestamp`. Only a notarize step (submit, wait, staple) is missing.
