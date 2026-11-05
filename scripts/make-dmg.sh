#!/bin/bash
# Makes build/Buddy-<version>.dmg: Buddy.app plus an Applications link. Run build-app.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Buddy.app"
[ -d "$APP" ] || { echo "error: $APP is missing. Run scripts/build-app.sh first." >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < VERSION)"
DMG="$ROOT/build/Buddy-$VERSION.dmg"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
STAGE="$TMPD/Buddy"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Buddy.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Buddy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

source "$ROOT/scripts/sign-identity.sh"
codesign --force ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} --identifier com.tiagosantos.buddy.dmg --sign "$SIGN_ID" "$DMG"
codesign --verify "$DMG"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1), signed: $SIGN_KIND)"
