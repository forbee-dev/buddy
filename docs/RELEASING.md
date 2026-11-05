# Releasing Buddy

1. Bump `VERSION` (for example `0.2.1`).
2. Run `./scripts/build-app.sh`. It builds `build/Buddy.app`.
   - `CFBundleShortVersionString` comes from `VERSION`.
   - `CFBundleVersion` is the build time (`YYYYMMDDhhmm`).
3. Run `./scripts/make-dmg.sh`. It builds `build/Buddy-<version>.dmg`: Buddy.app plus an Applications link, UDZO compressed, signed with the same identity. The DMG layout is bare on purpose: no background image, no icon positions.
4. Check the DMG: `hdiutil attach -nobrowse build/Buddy-<version>.dmg`, look at the contents, then `hdiutil detach`.
5. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new `[<version>]` heading with the date.
6. Commit, then tag: `git tag v<version> && git push origin main v<version>`.
7. Hash the DMG: `shasum -a 256 build/Buddy-<version>.dmg`. Put the hash in the release body, so users can verify the download.
8. Make the GitHub release and attach the DMG: `gh release create v<version> build/Buddy-<version>.dmg --notes "sha256: <hash>"` (or `--notes-file` with the changelog entry and the hash).
9. Update the Homebrew cask: `TAP_DIR=<path to homebrew-tap> ./scripts/update-cask.sh <version>`, then commit and push the tap. Details: [HOMEBREW.md](HOMEBREW.md).
10. Run `brew audit --cask forbee-dev/tap/buddy`. It must pass.
11. Share the DMG. Users follow [INSTALL.md](INSTALL.md) ("Team install").

CI has a `package` job that runs the build and DMG scripts with an ad hoc signature. It only validates the scripts. The released DMG is built and signed locally.

## Extension on Open VSX

The companion extension is published to [Open VSX](https://open-vsx.org) as `tiagosantos-local.buddy-companion`. Cursor and VS Code users can then install and update it from the Extensions view. The app keeps bundling the `.vsix` as the fallback, so **Install in VS Code / Cursor** works without the registry.

One-time, done by the maintainer (never by an agent):

1. Create an Eclipse account and sign in to open-vsx.org with it. Sign the publisher agreement.
2. Create an access token in the Open VSX user settings. Keep it out of the repo. Put it in `OVSX_PAT` in your shell only when you publish.
3. Create the namespace: `cd vscode-ext && npx ovsx create-namespace tiagosantos-local -p "$OVSX_PAT"`.

Per release:

1. Bump `version` in `vscode-ext/package.json`. Open VSX rejects a version that is already published.
2. `cd vscode-ext && npm ci && npm test && npm run package`.
3. `OVSX_PAT=<token> npm run publish:ovsx`. It uploads `buddy-companion-<version>.vsix`.
4. Check the listing at `https://open-vsx.org/extension/tiagosantos-local/buddy-companion`.
5. Build the app after the bump, so it bundles the same `.vsix`.

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
