#!/usr/bin/env bash
# Builds build/Sonder.dmg for distribution: a universal (Apple silicon + Intel) app next to a
# shortcut to /Applications to drag it onto.
#
#   scripts/build-dmg.sh
#
# Without a Developer ID the app is signed ad hoc, and macOS on other Macs asks people to approve
# it once (System Settings → Privacy & Security → Open Anyway). To ship a DMG that just opens:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   signs the app and the DMG
#   NOTARY_PROFILE=name                                      notarizes and staples the DMG; create
#     the profile once with: xcrun notarytool store-credentials name --apple-id … --team-id …
# The file is always named Sonder.dmg, so .../releases/latest/download/Sonder.dmg stays valid.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Sonder.app/Contents/Info.plist)
DMG="build/Sonder.dmg"

STAGING=build/dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Sonder.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# The mounted disk shows the app icon: a writable image gets .VolumeIcon.icns and the volume's
# custom-icon flag, then is compressed into the final read-only DMG.
cp build/Sonder.app/Contents/Resources/AppIcon.icns "$STAGING/.VolumeIcon.icns"
RW="build/Sonder-rw.dmg"
rm -f "$RW"
hdiutil create -volname "Sonder $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\// { print $NF }')
xcrun SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" -ov >/dev/null
rm -rf "$STAGING" "$RW"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG ($VERSION, $(du -h "$DMG" | cut -f1))"
