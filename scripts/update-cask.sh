#!/bin/bash
# Writes packaging/homebrew/buddy.rb for <version> from build/Buddy-<version>.dmg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "usage: $0 <version> (for example 0.2.0)" >&2; exit 1; }
DMG="$ROOT/build/Buddy-$VERSION.dmg"
CASK="$ROOT/packaging/homebrew/buddy.rb"
[ -f "$DMG" ] || { echo "error: $DMG is missing. Run scripts/make-dmg.sh first." >&2; exit 1; }
[ -f "$CASK" ] || { echo "error: $CASK is missing." >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed -E -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK" > "$TMP"
grep -q "version \"$VERSION\"" "$TMP" && grep -q "sha256 \"$SHA\"" "$TMP" || { echo "error: could not update the cask." >&2; exit 1; }
cat "$TMP" > "$CASK"
echo "Cask: $CASK (version $VERSION, sha256 $SHA)"
