#!/bin/bash
# Build Cthugha and install it to /Applications (or ~/Applications if the
# system folder isn't writable without admin rights).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "Note: /Applications not writable; installing to $DEST instead."
fi

echo "Installing to $DEST/Cthugha.app…"
rm -rf "$DEST/Cthugha.app"
ditto Cthugha.app "$DEST/Cthugha.app"
SIGN_ID="${CODESIGN_IDENTITY:-Developer ID Application: qualified.ink GmbH (5R57LQA4MP)}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    codesign --force --timestamp --options runtime \
        --entitlements "Cthugha.entitlements" \
        --sign "$SIGN_ID" --identifier ink.qualified.cthugha "$DEST/Cthugha.app"
else
    codesign --force --sign - --identifier ink.qualified.cthugha "$DEST/Cthugha.app"
fi

echo "Installed. Launch with:  open \"$DEST/Cthugha.app\""
echo "Start full screen with:  open \"$DEST/Cthugha.app\" --args --fullscreen"
