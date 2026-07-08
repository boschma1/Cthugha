#!/bin/bash
# Generate Assets/AppIcon.icns from tools/MakeIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
echo "Rendering icon…"
swiftc -O -o "$TMP/makeicon" tools/MakeIcon.swift -framework AppKit
"$TMP/makeicon" "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for pair in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${pair%%:*}"; name="${pair##*:}"
    sips -z "$px" "$px" "$TMP/icon_1024.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done

mkdir -p Assets
iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
rm -rf "$TMP"
echo "Wrote Assets/AppIcon.icns"
