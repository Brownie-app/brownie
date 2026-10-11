#!/bin/zsh
# Release build: Developer ID signing, hardened runtime, notarisation, DMG, Sparkle appcast entry.
# Needs, in .secrets/brownie.env: APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_TEAM_ID,
# APPLE_APP_SPECIFIC_PASSWORD, SPARKLE_PUBLIC_KEY, APPCAST_URL. See docs/launch-setup.md.
set -e
cd "$(dirname "$0")/.."
set -a; source .secrets/brownie.env; set +a
VERSION=${1:-0.1}
# Not a secret: this is the public half of the update-signing key, and it is in the repo on purpose so
# that what signs an update is a matter of record. The private half lives only in the maintainer's
# login Keychain and is never printed, committed or sent anywhere.
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-hhb3CF73da4iuI4tk3tBgHh4KV8PcdTxygelG4CxYwU=}
APPCAST_URL=${APPCAST_URL:-https://www.usebrownie.com/appcast.xml}
export BROWNIE_VERSION=$VERSION
# A UTC minute stamp: always larger than the last release's, and larger than the commit counts used
# before this existed, so an older copy always sees a newer one as newer.
export BROWNIE_BUILD=${BROWNIE_BUILD:-$(date -u +%Y%m%d%H%M)}
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
# The appcast entry, signed and written into the website repo. Until this runs a release exists but
# nothing running tells anyone about it, which is the whole point of shipping one.
./Scripts/appcast.sh "$VERSION" "$DMG" "${RELEASE_NOTES_HTML:-}"
echo
echo "shipped $DMG"
echo "  1. gh release create v$VERSION $DMG --title \"Brownie $VERSION\" --notes-file <notes>"
echo "  2. deploy the website so ${APPCAST_URL:-the appcast} carries the new entry"
echo "  (order matters: Sparkle follows the appcast to the GitHub download, so publish the release first)"
