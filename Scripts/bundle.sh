#!/bin/zsh
# Assemble dist/Brownie.app from the SwiftPM build so macOS treats it as a real app
# (permissions, notifications, login item, menu bar). Ad-hoc signed unless APPLE_SIGNING_IDENTITY is set.
set -e
cd "$(dirname "$0")/.."
# Xcode missing or broken (e.g. after a macOS upgrade)? The Command Line Tools can build everything.
if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi
CONFIG=${1:-debug}
VERSION=${BROWNIE_VERSION:-0.2}
BUILD=$(git -C "$(dirname "$0")/.." rev-list --count HEAD 2>/dev/null || echo 1)
[ -f .secrets/brownie.env ] && { set -a; source .secrets/brownie.env; set +a; }
swift build -c $CONFIG --product Brownie
BIN=$(swift build -c $CONFIG --show-bin-path)
APP=dist/Brownie.app
chmod -R u+w "$APP" 2>/dev/null; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Brownie" "$APP/Contents/MacOS/Brownie"
# resource bundles (prompts) + any dylibs/frameworks SwiftPM produced
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp Assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for d in Vendor/tdlib/lib/*.dylib; do cp "$d" "$APP/Contents/Frameworks/"; chmod u+w "$APP/Contents/Frameworks/$(basename $d)"; done
setopt +o nomatch
for f in "$BIN"/*.framework(N) "$BIN"/*.dylib(N); do cp -R "$f" "$APP/Contents/Frameworks/"; done
# the LiteRT-LM binary lives inside the xcframework SwiftPM downloaded
for d in $(find .build/artifacts -name "libCLiteRTLM_mac.dylib" -path "*macos*" | head -1); do rm -f "$APP/Contents/Frameworks/$(basename $d)"; cp "$d" "$APP/Contents/Frameworks/" && chmod u+w "$APP/Contents/Frameworks/$(basename $d)"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Brownie</string>
  <key>CFBundleDisplayName</key><string>Brownie</string>
  <key>CFBundleIdentifier</key><string>app.brownie.mac</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Brownie</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>app.brownie.mac</string><key>CFBundleURLSchemes</key><array><string>brownie</string></array></dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Brownie drives Messages, Mail and Calendar for the cards you fire.</string>
  <key>NSContactsUsageDescription</key><string>To show names instead of phone numbers in your chats.</string>
  <key>NSMicrophoneUsageDescription</key><string>Hold-to-talk for Hands. Speech is recognised on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Hold-to-talk for Hands. Speech is recognised on this Mac.</string>
  <key>NSCalendarsUsageDescription</key><string>To time cards against your calendar.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>To read your events for the last week and the next day, on this Mac, so morning cards know what is coming up.</string>
</dict></plist>
PLIST
# Release builds carry the app's own credentials (Telegram api_id/hash, Google desktop client) in Info.plist.
# They identify the app, not a user; a user's own tokens live only in their Keychain. Debug builds read .secrets/brownie.env instead.
if [ "$CONFIG" = "release" ]; then
  /usr/libexec/PlistBuddy -c "Add :BrownieCredentials dict" "$APP/Contents/Info.plist"
  for k in GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET TELEGRAM_API_ID TELEGRAM_API_HASH; do
    v="${(P)k}"
    [ -n "$v" ] && /usr/libexec/PlistBuddy -c "Add :BrownieCredentials:$k string $v" "$APP/Contents/Info.plist"
  done
  echo "release: bundled $(/usr/libexec/PlistBuddy -c 'Print :BrownieCredentials' "$APP/Contents/Info.plist" | grep -c '=') app credentials"
fi
# rpath so the binary finds frameworks in Contents/Frameworks
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Brownie" 2>/dev/null || true
IDENTITY="${APPLE_SIGNING_IDENTITY:-Brownie Dev Signing}"
if ! codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then echo "warning: '$IDENTITY' not usable, signing ad-hoc (permissions will not survive rebuilds)"; codesign --force --deep --sign - "$APP"; fi
echo "built $APP"
