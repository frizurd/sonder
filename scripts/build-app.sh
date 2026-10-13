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
# Sparkle (updates) goes in Frameworks, where the binary's @executable_path/../Frameworks rpath finds it.
# The build adds rpaths into this machine's build folder and Xcode; they don't belong in the app.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
otool -l "$APP/Contents/MacOS/Sonder" | awk '/LC_RPATH/ { getline; getline; print $2 }' | grep -E '^/(Users|Applications)/' | sort -u \
    | while read -r path; do install_name_tool -delete_rpath "$path" "$APP/Contents/MacOS/Sonder"; done
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/Welcome.md "$APP/Contents/Resources/Welcome.md"
# App icon: the Icon Composer bundle compiles to Assets.car (Liquid Glass on macOS 26) and AppIcon.icns.
PARTIAL="$(mktemp -d)/icon.plist"
# (actool runs through a helper daemon, so its paths must be absolute.)
xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$PARTIAL" "$PWD/Resources/AppIcon.icon" >/dev/null

# Sparkle's helpers are signed first, inside out, then the framework and the app.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID")
else
    SIGN=(codesign --force --sign -)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Sonder"), signed by ${DEVELOPER_ID:-ad hoc})"
