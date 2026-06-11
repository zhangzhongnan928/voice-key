# Releasing VoiceKey

Two distribution channels, one per platform. Team: OPENPASSKEY PTY LTD
(`3272Q6WG52`). Auth for headless steps: an App Store Connect API key
(key id `5TL227RKCW`, `.p8` kept outside the repo) — plus the Mac's
signed-in Xcode account for the steps Apple gates behind a real session
(see Caveats).

## macOS — notarized Developer ID zip (not TestFlight)

TestFlight on macOS requires App Sandbox, and sandboxed apps cannot post
CGEvents into other apps — it would break VoiceKey's core insertion
feature. So the Mac app ships as a notarized direct download.

```bash
xcodegen generate
xcodebuild archive \
    -project VoiceKey.xcodeproj -scheme VoiceKey -configuration Release \
    -archivePath build/VoiceKey.xcarchive \
    -destination 'platform=macOS,arch=arm64' \
    DEVELOPMENT_TEAM=3272Q6WG52 ENABLE_HARDENED_RUNTIME=YES \
    -allowProvisioningUpdates

# Developer ID export uses Xcode's cloud-managed Developer ID certificate;
# the signed-in Xcode account authorizes it (no cert in the local keychain).
xcodebuild -exportArchive \
    -archivePath build/VoiceKey.xcarchive \
    -exportOptionsPlist build/ExportOptionsDevID.plist \
    -exportPath build/export -allowProvisioningUpdates

ditto -c -k --keepParent build/export/VoiceKey.app /tmp/VoiceKey-notarize.zip
xcrun notarytool submit /tmp/VoiceKey-notarize.zip \
    --key <AuthKey.p8> --key-id 5TL227RKCW --issuer <ISSUER_ID> --wait
xcrun stapler staple build/export/VoiceKey.app
ditto -c -k --keepParent build/export/VoiceKey.app dist/VoiceKey-<version>.zip
```

Install: unzip into /Applications, launch once, grant Microphone and
Accessibility. (`scripts/release.sh` is the same pipeline using a
`notarytool` keychain profile instead of key flags.)

## iOS — TestFlight

```bash
cd ios
xcodegen generate
xcodebuild archive \
    -project VoiceKeyiOS.xcodeproj -scheme VoiceKeyiOS -configuration Release \
    -archivePath build/VoiceKeyiOS.xcarchive \
    -destination 'generic/platform=iOS' \
    DEVELOPMENT_TEAM=3272Q6WG52 -allowProvisioningUpdates

# method=app-store-connect, destination=upload (see ios/build/ExportOptions.plist)
xcodebuild -exportArchive \
    -archivePath build/VoiceKeyiOS.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/upload -allowProvisioningUpdates
```

**Every upload needs a higher `CFBundleVersion`** (in `ios/project.yml`,
both targets) for the same marketing version. Export compliance is
pre-answered via `ITSAppUsesNonExemptEncryption: false`.

After Apple finishes processing (a few minutes), the build appears in
App Store Connect → TestFlight; add it to an internal tester group and
install via the TestFlight app on the phone. The keyboard extension
rides along inside the app — enable it under Settings → General →
Keyboard → Keyboards → Add New Keyboard → VoiceKey Board, then Allow
Full Access (required for App Group store reads; the keyboard makes no
network calls).

## One-time setup (already done; for reference)

- Bundle IDs `com.victor.voicekey-ios` and
  `com.victor.voicekey-ios.keyboard` — registered automatically by
  cloud signing on first archive.
- App Group `group.com.victor.voicekey` — registered and assigned to
  both bundle IDs **manually** in the developer portal (Identifiers →
  App Groups). No public API or cloud-signing path does this.
- App record — created **manually** in App Store Connect → Apps → +
  (the public API does not allow app creation).

## Caveats (learned the hard way)

- The ASC API key cannot: register bundle IDs directly (403), create
  Developer ID certificates (Account Holder only), assign app groups
  (no endpoint), create app records (read-only resource), or authorize
  cloud-managed *distribution* signing during export ("Cloud signing
  permission error"). For those export steps, drop the
  `-authenticationKey*` flags so xcodebuild uses the signed-in Xcode
  account session instead.
- `fastlane produce` requires interactive Apple ID auth; it cannot use
  the API key.
