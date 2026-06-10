#!/bin/bash
# Dev build signed with the owner's Apple Development certificate.
# A stable signing identity keeps TCC grants (Microphone, Accessibility)
# across rebuilds — unsigned/ad-hoc builds lose them every time.
#
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/sign.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
else
    echo "warning: xcodegen not found; using existing VoiceKey.xcodeproj" >&2
fi

xcodebuild build \
    -project VoiceKey.xcodeproj \
    -scheme VoiceKey \
    -configuration Debug \
    -derivedDataPath build/DerivedData \
    -destination 'platform=macOS,arch=arm64' \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic

APP="build/DerivedData/Build/Products/Debug/VoiceKey.app"
echo
echo "Dev build ready: $APP"
echo "Run it with: open \"$APP\""
