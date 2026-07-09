#!/bin/bash
# Cut a Cthugha release: build → notarize → staple → zip → GitHub release.
#
# Reads the version from Info.plist (CFBundleShortVersionString) and publishes
# tag v<version> with a notarized, stapled Cthugha-<version>.zip asset.
#
# Why this exists: build.sh/install.sh only *sign* the app. A signed-but-not-
# notarized Developer ID app trips Gatekeeper once downloaded ("Apple could not
# verify…"). This script performs the notarize + staple steps that every
# published build needs, so they can never be skipped by accident.
#
# Overridable via env:
#   QINK_NOTARY_PROFILE   keychain profile for notarytool (default: qualified-ink-notary)
#   CTHUGHA_REPO          GitHub repo for the release       (default: boschma1/Cthugha)
#   CODESIGN_IDENTITY     signing identity (passed through to build.sh)
#
# Usage:
#   ./release.sh                 # release the current Info.plist version
#   ./release.sh --notes "…"     # custom release notes (default is auto-generated)
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${QINK_NOTARY_PROFILE:-qualified-ink-notary}"
REPO="${CTHUGHA_REPO:-boschma1/Cthugha}"
APP="Cthugha.app"

NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- Preconditions -----------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "ERROR: notary profile '$NOTARY_PROFILE' not found." >&2
    echo "Create it with: xcrun notarytool store-credentials '$NOTARY_PROFILE' \\" >&2
    echo "  --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>" >&2
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
TAG="v$VERSION"
ASSET="Cthugha-$VERSION.zip"
echo "Releasing Cthugha $VERSION (build $BUILD) → $REPO tag $TAG"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Note: release $TAG already exists — its asset will be replaced (--clobber)."
fi

# --- Build (signs with hardened runtime) -------------------------------------
./build.sh

# --- Notarize ----------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Zipping for notarization…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"

echo "Submitting to Apple notary service (this can take a few minutes)…"
SUBMIT_OUT="$(xcrun notarytool submit "$WORK/notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$SUBMIT_OUT"
if ! grep -q "status: Accepted" <<<"$SUBMIT_OUT"; then
    echo "ERROR: notarization was not Accepted — aborting." >&2
    exit 1
fi

# --- Staple + verify ---------------------------------------------------------
echo "Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"

# --- Package the stapled app -------------------------------------------------
echo "Packaging $ASSET…"
rm -f "$ASSET"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ASSET"

# --- Publish -----------------------------------------------------------------
if [ -z "$NOTES" ]; then
    NOTES="Cthugha $VERSION (build $BUILD).

Notarized by Apple and stapled — launches with no Gatekeeper warning.

Download **$ASSET**, unzip, and move Cthugha.app to /Applications."
fi

export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Updating existing release $TAG…"
    gh release upload "$TAG" -R "$REPO" "$ASSET#$ASSET" --clobber
else
    echo "Creating release $TAG…"
    gh release create "$TAG" -R "$REPO" \
        --title "Cthugha $VERSION" \
        --notes "$NOTES" \
        "$ASSET#$ASSET"
fi

echo "Done: https://github.com/$REPO/releases/tag/$TAG"
