# Contributing to Buddy

Small pull requests are best. For a big change, open an issue first.

## Setup

- macOS 14 or later.
- Swift 6 toolchain (Xcode 16 or later, or Command Line Tools with Swift 6).
- Node 20 or later (extension, sprites).
- `ffmpeg` only if you render the README images.

```sh
git clone https://github.com/forbee-dev/buddy.git
cd buddy
```

## Build

```sh
swift build                 # library, app and hook
./scripts/build-app.sh      # builds build/Buddy.app
./scripts/make-dmg.sh       # optional: build/Buddy-<version>.dmg
```

## Tests

With Xcode installed:

```sh
swift test
```

With Command Line Tools only (no Xcode), load the swift-testing macro plugin:

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Extension and sprites:

```sh
(cd vscode-ext && npm ci && npm test)
node design/check-sprites.js
node design/check-skin.js
node design/sounds/gen-sounds.js --check   # chiptune WAV headers
python3 scripts/remote/test_hook.py   # SSH hook script tests
```

## Install your build locally

```sh
./scripts/install-local.sh
```

It builds, quits the running Buddy, moves the old app to the Trash, copies the new one to `/Applications` and opens it.

### The "Buddy Dev" signing certificate

macOS drops the Accessibility grant when the app signature changes. An ad hoc build changes it on every rebuild. To keep the grant, make a self-signed certificate once:

1. Open Keychain Access, then Certificate Assistant, then Create a Certificate.
2. Name: `Buddy Dev`. Identity Type: Self Signed Root. Certificate Type: Code Signing.
3. Run `./scripts/build-app.sh` again. It finds `Buddy Dev` by itself.

You can also set `BUDDY_SIGN_ID`. See [docs/RELEASING.md](docs/RELEASING.md).

## Add an outfit

1. Open `design/gen-sprites.js`. Find the outfits section.
2. Add one `outfit(name, label, fn)` call. Draw it for the idle frame 0 head. Hats end at row 11 so the brows stay visible.
3. Run `node gen-sprites.js` in `design/`. Use `node gen-sprites.js --ascii idle 0 <name>` to check one frame.
4. Open `design/preview.html` in a browser. Check every state and palette.
5. Run `node design/check-sprites.js`. It must report 0 FAIL.
6. Optional: run `node docs/assets/make-hero.js` to refresh the README images.

Sprite format: [design/README.md](design/README.md).

## Pull request rules

- Keep it small. One change per PR.
- Add or update tests. Swift logic goes in `BuddyCore` so it can be tested.
- Run the tests before you push. CI runs them too.
- No secrets, tokens, personal paths or private data in code, tests, logs or screenshots.
- Do not log prompts, commands or tool input.
- Report security problems privately: [docs/SECURITY.md](docs/SECURITY.md).
