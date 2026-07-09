#!/bin/bash
# Package MusicDeduper.app into a clean, drag-to-Applications DMG.
# Usage:  ./make_dmg.sh "/path/to/MusicDeduper.app"
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "Usage: $0 /path/to/MusicDeduper.app"
  echo "  (export the notarized .app from Xcode first — see DISTRIBUTION.md)"
  exit 1
fi

NAME="Music Deduper"
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
