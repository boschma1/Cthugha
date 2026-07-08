#!/bin/bash
# Build Cthugha.app — a Cthugha-style audio visualizer for macOS 26.
set -euo pipefail
cd "$(dirname "$0")"

APP="Cthugha.app"
BIN="$APP/Contents/MacOS/Cthugha"
RES="$APP/Contents/Resources"

echo "Compiling Swift…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

swiftc -O -o "$BIN" Sources/*.swift \
    -framework Cocoa \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreAudio

cp Info.plist "$APP/Contents/Info.plist"

# App icon.
if [ -f Assets/AppIcon.icns ]; then
    cp Assets/AppIcon.icns "$RES/AppIcon.icns"
else
    echo "No Assets/AppIcon.icns — run ./tools/makeicon.sh to generate it."
fi

# Precompile the Metal shaders into default.metallib, if the Metal toolchain is
# available. The shader source is the single source of truth in Shaders.swift;
# extract it so the two never drift. Runtime compilation is used as a fallback.
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "Compiling Metal shaders → default.metallib…"
    TMP="$(mktemp -d)"
    awk '/^let metalShaderSource = """$/{flag=1;next} /^"""$/{flag=0} flag' \
        Sources/Shaders.swift > "$TMP/Shaders.metal"
    xcrun -sdk macosx metal -O -c "$TMP/Shaders.metal" -o "$TMP/Shaders.air"
    xcrun -sdk macosx metallib "$TMP/Shaders.air" -o "$RES/default.metallib"
    rm -rf "$TMP"
else
    echo "Metal toolchain not found — app will compile shaders at runtime."
    echo "  (install with: xcodebuild -downloadComponent MetalToolchain)"
fi

SIGN_ID="${CODESIGN_IDENTITY:-Developer ID Application: qualified.ink GmbH (5R57LQA4MP)}"
ENTITLEMENTS="Cthugha.entitlements"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "Signing with '$SIGN_ID' (hardened runtime — required for notarization)…"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" --identifier ink.qualified.cthugha "$APP"
else
    echo "Identity '$SIGN_ID' not found — signing ad-hoc (permissions won't persist across rebuilds)."
    codesign --force --sign - --identifier ink.qualified.cthugha "$APP"
fi

echo "Built $APP"
