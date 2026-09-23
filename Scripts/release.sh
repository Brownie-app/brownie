#!/bin/zsh
# Release build: Developer ID signing, hardened runtime, notarisation, DMG, Sparkle appcast entry.
# Needs, in .secrets/brownie.env: APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_TEAM_ID,
# APPLE_APP_SPECIFIC_PASSWORD, SPARKLE_PUBLIC_KEY, APPCAST_URL. See docs/launch-setup.md.
set -e
cd "$(dirname "$0")/.."
set -a; source .secrets/brownie.env; set +a
VERSION=${1:-0.1}
export BROWNIE_VERSION=$VERSION
[ -n "$APPLE_SIGNING_IDENTITY" ] || { echo "APPLE_SIGNING_IDENTITY missing"; exit 1; }
./Scripts/bundle.sh release
APP=dist/Brownie.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[ -n "$SPARKLE_PUBLIC_KEY" ] && /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
[ -n "$APPCAST_URL" ] && /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $APPCAST_URL" "$APP/Contents/Info.plist"
cat > dist/entitlements.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
codesign --force --deep --options runtime --timestamp --entitlements dist/entitlements.plist --sign "$APPLE_SIGNING_IDENTITY" "$APP"
DMG=dist/Brownie-$VERSION.dmg; rm -f "$DMG"
hdiutil create -volname Brownie -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$DMG"
SIGN=$(find .build -name sign_update -type f | head -1)
[ -n "$SIGN" ] && "$SIGN" "$DMG" | tee dist/sparkle-signature.txt
echo "shipped $DMG — upload it and add the signature line to your appcast.xml"
