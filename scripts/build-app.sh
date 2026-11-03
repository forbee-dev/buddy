#!/bin/bash
# Builds build/Buddy.app from SwiftPM. Needs only the Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Icon: regenerate when the sprites changed.
ICNS="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/design/sprites.json" -nt "$ICNS" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/design/sprites.json" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi

APP="$ROOT/build/Buddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BuddyApp" "$APP/Contents/MacOS/Buddy"
cp "$BIN/buddy-hook" "$APP/Contents/MacOS/buddy-hook"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/design/sprites.json" "$APP/Contents/Resources/sprites.json"
cp "$ROOT/Resources/prices.json" "$APP/Contents/Resources/prices.json"
mkdir -p "$APP/Contents/Resources/skins"
cp "$ROOT/design/skins/crate.json" "$APP/Contents/Resources/skins/crate.json"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# SSH sessions: Settings → SSH copies an install command that reads remote/install.sh.
mkdir -p "$APP/Contents/Resources/remote"
cp "$ROOT"/scripts/remote/{buddy-hook-remote,install.sh,uninstall.sh} "$APP/Contents/Resources/remote/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Companion extension (built by vscode-ext/, read only here).
VSIX="$(ls -t "$ROOT"/vscode-ext/buddy-companion-*.vsix 2>/dev/null | head -1 || true)"
if [ -n "$VSIX" ]; then cp "$VSIX" "$APP/Contents/Resources/"; echo "Bundled: $(basename "$VSIX")"; fi

source "$ROOT/scripts/sign-identity.sh"
# Hardened runtime on both. Only the app gets the Apple Events entitlement (Jump for iTerm2/Terminal).
codesign --force --options runtime ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} --sign "$SIGN_ID" "$APP/Contents/MacOS/buddy-hook"
codesign --force --options runtime ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} --entitlements "$ROOT/Resources/Buddy.entitlements" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
case "$SIGN_KIND" in
  adhoc)
    echo "WARNING: ad-hoc signature. macOS resets the Accessibility permission on every rebuild."
    echo "WARNING: create a 'Buddy Dev' code-signing certificate once (see docs/INSTALL.md); the script then uses it." ;;
  *) echo "Signed with: $SIGN_ID ($SIGN_KIND)" ;;
esac
echo "Built: $APP (version $VERSION, build $BUILD_NUMBER)"
