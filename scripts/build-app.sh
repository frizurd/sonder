#!/usr/bin/env bash
# Builds build/Sonder.app.
#   scripts/build-app.sh [debug|release]   this Mac's architecture (release by default)
#   scripts/build-app.sh --universal       Apple silicon + Intel, for distribution
# Signing: DEVELOPER_ID="Developer ID Application: …" signs for distribution with the hardened
# runtime (needed for notarization); otherwise the app is signed ad hoc, for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
ARCHS=()
for arg in "$@"; do
    case "$arg" in
        --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
        *) CONFIG="$arg" ;;
    esac
done
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="build/Sonder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sonder" "$APP/Contents/MacOS/Sonder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/Welcome.md "$APP/Contents/Resources/Welcome.md"
# App icon: the Icon Composer bundle compiles to Assets.car (Liquid Glass on macOS 26) and AppIcon.icns.
PARTIAL="$(mktemp -d)/icon.plist"
# (actool runs through a helper daemon, so its paths must be absolute.)
xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$PARTIAL" "$PWD/Resources/AppIcon.icon" >/dev/null

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Sonder"), signed by ${DEVELOPER_ID:-ad hoc})"
