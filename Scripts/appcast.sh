#!/bin/zsh
# Add one release to the Sparkle appcast — the file every running copy of Brownie checks to learn that a
# newer one exists. Called by release.sh once the DMG is notarised and stapled; run it by hand only to
# repair a feed.
#
#   ./Scripts/appcast.sh <version> [dmg] [notes.html]
#
# The DMG defaults to dist/Brownie-<version>.dmg, and the notes to a line pointing at the GitHub release.
# The entry is signed with the EdDSA key in your login Keychain (Scripts/sparkle-keys.sh made it); the
# private half never leaves the Keychain and is never printed.
#
# Where the feed lives: APPCAST_PATH in .secrets/brownie.env, or ../Brownie-website/appcast.xml beside
# this repo. Writing it does not publish it — deploy the website afterwards (see DEPLOY.md there).
set -e
cd "$(dirname "$0")/.."
[ -f .secrets/brownie.env ] && { set -a; source .secrets/brownie.env; set +a; }

VERSION=${1:?usage: appcast.sh <version> [dmg] [notes.html]}
DMG=${2:-dist/Brownie-$VERSION.dmg}
NOTES_FILE=${3:-}
APPCAST_PATH=${APPCAST_PATH:-../Brownie-website/appcast.xml}
APPCAST_URL=${APPCAST_URL:-https://www.usebrownie.com/appcast.xml}
REPO=${GITHUB_REPO:-Brownie-app/brownie}
MIN_OS=${MIN_OS:-14.0}

[ -f "$DMG" ] || { echo "no such disk image: $DMG — build it with Scripts/release.sh $VERSION"; exit 1; }

# The build number the app compares against. Never recomputed: it is read from the bundle that was just
# built, because an entry claiming a different number than the app carries is an update nobody is offered.
BUILD=${BROWNIE_BUILD:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" dist/Brownie.app/Contents/Info.plist 2>/dev/null || git rev-list --count HEAD)}
PUBDATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"

SIGN=$(find .build -path "*sparkle*" -name sign_update -type f | head -1)
[ -n "$SIGN" ] || { echo "sign_update is missing — run 'swift build' once so Sparkle's tools are fetched"; exit 1; }
ATTRS=$("$SIGN" "$DMG")   # sparkle:edSignature="…" length="…"
[ -n "$ATTRS" ] || { echo "signing produced nothing — is the key in your Keychain? (Scripts/sparkle-keys.sh)"; exit 1; }

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then NOTES=$(cat "$NOTES_FILE")
else NOTES="<p>Brownie $VERSION. The full notes are on the <a href=\"https://github.com/$REPO/releases/tag/v$VERSION\">release page</a>.</p>"
fi

VERSION="$VERSION" BUILD="$BUILD" PUBDATE="$PUBDATE" URL="$URL" ATTRS="$ATTRS" NOTES="$NOTES" \
APPCAST_PATH="$APPCAST_PATH" APPCAST_URL="$APPCAST_URL" REPO="$REPO" MIN_OS="$MIN_OS" python3 <<'PY'
import os, pathlib, re

v, build, path = os.environ["VERSION"], os.environ["BUILD"], pathlib.Path(os.environ["APPCAST_PATH"])
item = f'''    <item>
      <title>{v}</title>
      <pubDate>{os.environ["PUBDATE"]}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{os.environ["MIN_OS"]}</sparkle:minimumSystemVersion>
      <link>https://github.com/{os.environ["REPO"]}/releases/tag/v{v}</link>
      <description><![CDATA[{os.environ["NOTES"]}]]></description>
      <enclosure url="{os.environ["URL"]}" {os.environ["ATTRS"]} type="application/octet-stream"/>
    </item>
'''

if not path.exists():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<!-- What every running copy of Brownie reads to learn a newer one exists. Written by Scripts/appcast.sh
     in the app repo; each entry is signed with a key that lives only in the maintainer's Keychain, so a
     copy of this file served by somebody else cannot make Brownie install anything. Newest first. -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Brownie</title>
    <link>{os.environ["APPCAST_URL"]}</link>
    <description>Updates for Brownie, a house spirit that lives in your Mac.</description>
    <language>en</language>
{item}  </channel>
</rss>
''', encoding="utf-8")
    print(f"created {path} with {v}")
    raise SystemExit

s = path.read_text(encoding="utf-8")
# re-releasing a version replaces its entry rather than listing it twice
existing = re.search(r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>"
                     + re.escape(v) + r"</sparkle:shortVersionString>.*?</item>\n", s, re.S)
if existing:
    s = s[:existing.start()] + s[existing.end():]
    print(f"replaced the existing {v} entry")
at = s.index("</channel>")
# newest first: straight after the channel's own header lines
anchor = s.index("<language>")
at = s.index("\n", s.index("</language>", anchor)) + 1
path.write_text(s[:at] + item + s[at:], encoding="utf-8")
print(f"added {v} (build {build}) to {path}")
PY

echo "appcast updated — deploy the website for it to reach anyone"
