# Homebrew tap

Users install with `brew install --cask forbee-dev/tap/buddy`. The cask lives in a separate repo, `forbee-dev/homebrew-tap`. The template is `packaging/homebrew/buddy.rb`.

## Create the tap once

1. On GitHub, create a public repo named `homebrew-tap` under `forbee-dev`. The `homebrew-` prefix is required.
2. Clone it and add the cask:

   ```sh
   git clone https://github.com/forbee-dev/homebrew-tap.git
   mkdir -p homebrew-tap/Casks
   ```

3. Do the first release (see below). Then copy the cask, commit and push:

   ```sh
   cp buddy/packaging/homebrew/buddy.rb homebrew-tap/Casks/buddy.rb
   cd homebrew-tap && git add Casks/buddy.rb && git commit -m "buddy 0.2.0" && git push
   ```

## Update for each release

1. Bump `VERSION`, run `./scripts/build-app.sh` and `./scripts/make-dmg.sh`.
2. Create the GitHub release `v<version>` and upload `build/Buddy-<version>.dmg`. The DMG must be the same file that you hash.
3. Update the cask:

   ```sh
   ./scripts/update-cask.sh <version>
   ```

   It writes the `version` and `sha256` into `packaging/homebrew/buddy.rb`.
4. Copy the cask to the tap and push (step 3 above).
5. Test:

   ```sh
   brew update
   brew install --cask forbee-dev/tap/buddy   # or: brew upgrade --cask buddy
   brew audit --cask --strict forbee-dev/tap/buddy
   ```

## Notes

- Buddy is not notarized. The cask `caveats` tell users to remove the quarantine flag.
- `zap` removes `~/Library/Application Support/Buddy` and the preferences plist. It never touches `~/.claude`. Hooks in `~/.claude/settings.json` stay: tell users to click Uninstall hooks (or Menu → Uninstall Buddy…) in Buddy first.
