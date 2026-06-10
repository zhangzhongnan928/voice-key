#!/bin/bash
# Release pipeline: archive -> Developer ID sign -> notarize -> staple -> zip.
# Produces dist/VoiceKey-<version>.zip for installation on both Macs.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials stored once:
#        xcrun notarytool store-credentials voicekey-notary \
#          --apple-id you@example.com --team-id XXXXXXXXXX
#
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-voicekey-notary}"
VERSION=$(awk '/CFBundleShortVersionString/{print $2}' project.yml | tr -d '"')
VERSION="${VERSION:-1.0.0}"

ARCHIVE="build/VoiceKey.xcarchive"
EXPORT_DIR="build/export"
DIST_DIR="dist"
ZIP="$DIST_DIR/VoiceKey-${VERSION}.zip"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$DIST_DIR"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
fi

echo "==> Archiving (arm64, Release, hardened runtime)"
xcodebuild archive \
    -project VoiceKey.xcodeproj \
    -scheme VoiceKey \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'platform=macOS,arch=arm64' \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting with Developer ID signing"
EXPORT_PLIST=$(mktemp /tmp/voicekey-export-XXXX.plist)
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR"
rm -f "$EXPORT_PLIST"

APP="$EXPORT_DIR/VoiceKey.app"
[ -d "$APP" ] || { echo "error: export did not produce VoiceKey.app" >&2; exit 1; }

echo "==> Notarizing"
NOTARIZE_ZIP=$(mktemp /tmp/voicekey-notarize-XXXX.zip)
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARIZE_ZIP"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done: $ZIP"
echo "Install: unzip into /Applications on each Mac, launch once, grant"
echo "Microphone and Accessibility when prompted (see README)."
