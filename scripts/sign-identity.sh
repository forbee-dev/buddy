#!/bin/bash
# Sourced by build-app.sh and make-dmg.sh. Sets SIGN_ID and SIGN_KIND (env | developer-id | buddy-dev | adhoc).
# Order: $BUDDY_SIGN_ID, a "Developer ID Application" identity, a "Buddy Dev" identity, then ad hoc.
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -n "${BUDDY_SIGN_ID:-}" ]; then
  SIGN_ID="$BUDDY_SIGN_ID"; SIGN_KIND="env"
  case "$SIGN_ID" in "Developer ID Application"*) SIGN_KIND="developer-id" ;; esac
elif dev_id="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)" && [ -n "$dev_id" ]; then
  SIGN_ID="$dev_id"; SIGN_KIND="developer-id"
elif printf '%s\n' "$identities" | grep -q '"Buddy Dev"'; then
  SIGN_ID="Buddy Dev"; SIGN_KIND="buddy-dev"
else
  SIGN_ID="-"; SIGN_KIND="adhoc"
fi
# A secure timestamp only makes sense (and only works) with a Developer ID.
TIMESTAMP_FLAG=()
if [ "$SIGN_KIND" = "developer-id" ]; then TIMESTAMP_FLAG=(--timestamp); fi
