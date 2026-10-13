#!/usr/bin/env bash
# Builds build/Sonder.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

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
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
