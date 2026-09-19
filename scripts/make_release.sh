#!/bin/bash
# Wraps build/Chirp.app (built by make_app.sh) into a distributable .dmg.
#
# This is a self-signed build, not a notarized one — Gatekeeper will still
# tell anyone who downloads it that it's from an unidentified developer.
# That's expected for now: right-click the app -> Open (or System Settings
# -> Privacy & Security -> Open Anyway) gets past it, once, per Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/make_app.sh

VERSION=$(defaults read "$(pwd)/build/Chirp.app/Contents/Info" CFBundleShortVersionString)
DMG="build/Chirp-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R build/Chirp.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname Chirp -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "Built $DMG"
