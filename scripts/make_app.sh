#!/bin/bash
# Builds Chirp.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --build-system native -Xswiftc -plugin-path \
    -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins

APP="build/Chirp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Chirp "$APP/Contents/MacOS/Chirp"

# Bundled fonts: copied straight into Contents/Resources rather than
# SwiftPM's generated Chirp_Chirp.bundle, which it expects at the .app's
# top level — codesign won't seal resources living outside Contents/, and
# fails to verify. FontLoader checks Bundle.main (this location) first.
if [ -d ".build/release/Chirp_Chirp.bundle/Fonts" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp .build/release/Chirp_Chirp.bundle/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
fi

# Pet sprite sheets/frames + manifest — same reasoning and same
# Bundle.main-first lookup as Fonts above (see PetSpriteStore.swift).
if [ -d ".build/release/Chirp_Chirp.bundle/Pet" ]; then
    mkdir -p "$APP/Contents/Resources/Pet"
    cp .build/release/Chirp_Chirp.bundle/Pet/*.png "$APP/Contents/Resources/Pet/"
    cp .build/release/Chirp_Chirp.bundle/Pet/*.json "$APP/Contents/Resources/Pet/"
fi

# App icon (source: Resources/Chirp.svg — rerun scripts/make_icon.sh to
# regenerate Resources/Chirp.icns after changing the SVG).
if [ -f "Resources/Chirp.icns" ]; then
    cp Resources/Chirp.icns "$APP/Contents/Resources/Chirp.icns"
fi

# Version lives in VERSION at the repo root — one file to bump per
# release, read by this script and by scripts/publish_release.sh, so the
# bundle, the git tag and the GitHub release can never disagree.
VERSION=$(tr -d ' \n' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.chirp</string>
    <key>CFBundleName</key>
    <string>Chirp</string>
    <key>CFBundleExecutable</key>
    <string>Chirp</string>
    <key>CFBundleIconFile</key>
    <string>Chirp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Chirp records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Notetaker checks for an in-progress calendar event only to give a captured meeting note a real title — it never reads or changes your calendar otherwise.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>If you turn on browser meeting detection, Notetaker reads your active browser tab's URL only to check whether it looks like a meeting link — never your browsing history, and never sent anywhere.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — no data leaves this Mac.</string>
</dict>
</plist>
PLIST

# The stable local identity is what keeps macOS permission grants valid
# across rebuilds: TCC stores a code requirement at the moment you grant
# Microphone/Accessibility, then re-validates every launch. A self-signed
# certificate pins that requirement to the certificate, which survives
# rebuilds. An ad-hoc signature (-) pins it to the binary's cdhash, which
# changes on EVERY build — so macOS stops recognising the app and asks for
# permission again each time.
#
# Ad-hoc is therefore a hard failure, not a silent fallback: one ad-hoc
# build is enough to invalidate a grant recorded against the certificate.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Chirp Dev"; then
    # Captured rather than streamed, so a failure can be explained instead
    # of leaving the bundle half-signed with a bare `errSecInternalComponent`
    # — which is codesign's way of saying "the keychain wouldn't let me use
    # that key", and says nothing about the one command that fixes it.
    if ! SIGN_OUTPUT=$(codesign --force --sign "Chirp Dev" "$APP" 2>&1); then
        echo "$SIGN_OUTPUT" >&2
        if echo "$SIGN_OUTPUT" | grep -q "errSecInternalComponent"; then
            cat >&2 <<'HELP'

ERROR: the keychain refused codesign access to the 'Chirp Dev' key.

The bundle is now UNSIGNED — do not ship or rely on it until this is
fixed and the build is re-run. Authorise the key, then build again:

  security set-key-partition-list -S apple-tool:,apple:,codesign:       -s -l "Chirp Dev" ~/Library/Keychains/login.keychain-db

It prompts for your login-keychain password (twice). This has to be a
real terminal — it cannot be answered from a script.
HELP
        fi
        exit 1
    fi
    echo "Signed with 'Chirp Dev'."
else
    echo "ERROR: signing identity 'Chirp Dev' not found." >&2
    echo "Run scripts/make_signing_cert.sh first — signing ad-hoc would make macOS" >&2
    echo "re-prompt for Microphone and Accessibility on every single rebuild." >&2
    exit 1
fi

echo "Built $APP"
