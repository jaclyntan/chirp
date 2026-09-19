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

# The versioned name is what ships as a GitHub release asset, so old
# versions stay individually downloadable. This unversioned copy is what
# a stable download link can point at, via GitHub's
# releases/latest/download/ permalink — that URL only ever resolves a
# fixed filename against whatever release is currently "latest", so it
# needs a name that doesn't change release to release. Without this, every
# release would need a matching manual update to the site's env var.
UNVERSIONED="build/Chirp.dmg"
cp -f "$DMG" "$UNVERSIONED"

echo "Built $DMG and $UNVERSIONED"
