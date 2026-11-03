#!/bin/bash
# Local dev install: builds Buddy, replaces /Applications/Buddy.app, and opens it.
# The old app goes to the Trash, never deleted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Buddy.app"
DEST="/Applications/Buddy.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say() { echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

say "Building"
"$ROOT/scripts/build-app.sh"
[ -d "$SRC" ] || fail "build did not produce $SRC"

say "Quitting Buddy if it runs"
if pgrep -x Buddy >/dev/null; then
  osascript -e 'tell application "Buddy" to quit' || true
  for _ in $(seq 1 20); do pgrep -x Buddy >/dev/null || break; sleep 0.5; done
  pgrep -x Buddy >/dev/null && fail "Buddy is still running. Quit it and run again."
fi

if [ -e "$DEST" ]; then
  TRASHED="$HOME/.Trash/Buddy-$(date +%Y%m%d-%H%M%S).app"
  say "Moving the old app to $TRASHED"
  mv "$DEST" "$TRASHED"
fi

say "Copying to $DEST"
ditto "$SRC" "$DEST"

say "Verifying the signature"
codesign --verify --deep --strict "$DEST" || fail "signature check failed for $DEST"

say "Updating LaunchServices"
"$LSREGISTER" -u "$SRC" || true
"$LSREGISTER" -f "$DEST"

say "Opening Buddy"
open "$DEST"
say "Done"
