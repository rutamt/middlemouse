#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="FreeWheel.app"
DMG="FreeWheel.dmg"
STAGING="build/dmg"

./build.sh

echo "==> Creating $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "FreeWheel" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
rm -rf "$STAGING"

echo "==> Built $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
