#!/bin/bash
# Package Music Librarian.app into a clean, drag-to-Applications DMG.
# Usage:  ./make_dmg.sh "/path/to/Music Librarian.app"
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "Usage: $0 /path/to/Music Librarian.app"
  echo "  (export the notarized .app from Xcode first — see DISTRIBUTION.md)"
  exit 1
fi

# Safety guard: never package a build that carries API keys in its Info.plist —
# they would be published inside the shipped app. The Release configuration
# blanks them automatically; this catches any build that slipped through.
for k in ACOUSTID_API_KEY DISCOGS_TOKEN; do
  v="$(/usr/libexec/PlistBuddy -c "Print :$k" "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ -n "$v" ]; then
    echo "REFUSING to package: $APP has a non-empty $k in its Info.plist."
    echo "That key would ship inside the app. Archive the Release configuration"
    echo "(which blanks API keys), then run this against that build."
    exit 1
  fi
done

NAME="Music Librarian"
DMG="$NAME.dmg"
STAGE="$(mktemp -d)"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # drag-to-install target
rm -f "$DMG"

hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo
echo "Created: $DMG"
echo "Next: notarize + staple the DMG (see DISTRIBUTION.md), then it's ready to share."
