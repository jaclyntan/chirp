#!/bin/bash
# Cuts a GitHub release: builds the DMG, tags the commit, uploads both
# assets. Version comes from the VERSION file at the repo root.
#
#   ./scripts/publish_release.sh            # dry run — builds, shows the plan
#   ./scripts/publish_release.sh --publish  # actually tags and publishes
#
# Nothing is pushed or published without --publish. The dry run is the
# default on purpose: a GitHub release and its tag are public the instant
# they exist, and deleting one afterwards still leaves it in people's
# update checks and in any clone that fetched it.
set -euo pipefail

cd "$(dirname "$0")/.."

PUBLISH=false
[ "${1:-}" = "--publish" ] && PUBLISH=true

VERSION=$(tr -d ' \n' < VERSION)
TAG="v$VERSION"
DMG="build/Chirp-$VERSION.dmg"

# --- Preflight ------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || fail "GitHub CLI not installed (brew install gh)."
gh auth status >/dev/null 2>&1 || fail "Not logged in — run: gh auth login"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || fail "No GitHub remote. Create the repo and set 'origin' first."

# The in-app updater polls a hardcoded repo; if that doesn't match where
# the release actually lands, users are silently offered nothing (or worse,
# someone else's releases).
EXPECTED=$(grep -oE 'private static let repo = "[^"]+"' Sources/Chirp/AppUpdate.swift | cut -d'"' -f2)
[ "$REPO" = "$EXPECTED" ] \
    || fail "Updater points at '$EXPECTED' but this repo is '$REPO'. Fix AppUpdate.swift:repo."

[ -z "$(git status --porcelain)" ] \
    || fail "Working tree is dirty. Commit or stash first — the tag should point at exactly what shipped."

git rev-parse "$TAG" >/dev/null 2>&1 \
    && fail "Tag $TAG already exists. Bump VERSION."

if gh release view "$TAG" >/dev/null 2>&1; then
    fail "Release $TAG already published."
fi

# --- Build ----------------------------------------------------------------
echo "Building $TAG…"
./scripts/make_release.sh >/dev/null

BUILT=$(defaults read "$(pwd)/build/Chirp.app/Contents/Info" CFBundleShortVersionString)
[ "$BUILT" = "$VERSION" ] \
    || fail "Built app reports $BUILT but VERSION says $VERSION."

[ -f "$DMG" ] || fail "Expected $DMG, not found."

# Verify the thing we're about to ship is actually signed — an ad-hoc or
# unsigned build would make macOS re-prompt every user for Accessibility
# on every update.
codesign --verify --deep --strict "build/Chirp.app" 2>/dev/null \
    || fail "build/Chirp.app fails signature verification."

echo
echo "  repo     $REPO"
echo "  tag      $TAG"
echo "  dmg      $DMG ($(du -h "$DMG" | cut -f1))"
echo "  notes    from CHANGELOG.md"
echo

if [ "$PUBLISH" != true ]; then
    echo "Dry run. Re-run with --publish to tag and publish."
    exit 0
fi

# --- Publish --------------------------------------------------------------
# Release notes come from this version's CHANGELOG section, so the notes
# and the changelog can't drift apart.
# Headings are written "## v2.1.0 — 2026-09-10", so match an optional
# leading "v" and allow anything (a date) after the version.
NOTES=$(awk -v v="$VERSION" '
    $0 ~ "^## \\[?v?" v "([^0-9.]|$)" { found=1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)
[ -n "${NOTES// /}" ] || fail "No CHANGELOG.md section found for $VERSION."

git tag -a "$TAG" -m "Chirp $VERSION"
git push origin "$TAG"

gh release create "$TAG" \
    "$DMG" \
    "build/Chirp.dmg" \
    --title "Chirp $VERSION" \
    --notes "$NOTES"

echo "Published: https://github.com/$REPO/releases/tag/$TAG"
