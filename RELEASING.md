# Releasing

A release is built on the maintainer's Mac, never in CI: the signing certificate and the app credentials live there and nowhere else. CI proves the code is sound; the Mac produces the thing people download.

## Before you start

You need, once: an Apple Developer account, a **Developer ID Application** certificate in the login Keychain, an app-specific password from appleid.apple.com, and `.secrets/brownie.env` holding `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, the app credentials for Google, Telegram, Slack and Microsoft, and — once updates are live — `SPARKLE_PUBLIC_KEY` and `APPCAST_URL`. See `docs/launch-setup.md`.

## The steps

1. **Main is green.** Every change is in through a pull request with a passing build. Nothing goes straight to main.
2. **Write the changelog.** A new section at the top of `CHANGELOG.md`, dated, in the same voice as the rest: what a person will notice, not what the diff says.
3. **Open a pull request for it**, let CI pass, squash it into main, and pull main down.
4. **Build, sign, notarise** from the repository root:
   ```
   ./Scripts/release.sh 0.2
   ```
   It builds the app in release configuration with the app credentials inside, signs it with the hardened runtime, wraps it in a disk image, sends it to Apple, waits for the verdict, staples the ticket, and — once a Sparkle key exists — prints the signature line for the appcast.
5. **Check it the way a stranger's Mac will:**
   ```
   spctl -a -vv -t install dist/Brownie-0.2.dmg     # accepted · Notarized Developer ID
   xcrun stapler validate dist/Brownie-0.2.dmg      # the validate action worked
   ```
6. **Write the checksum** beside it:
   ```
   shasum -a 256 dist/Brownie-0.2.dmg > dist/Brownie-0.2.dmg.sha256
   ```
7. **Publish**, with the notes written for someone who has never seen Brownie — what it is, what is in this version, how to install it, what it needs:
   ```
   gh release create v0.2 --target main --title "Brownie 0.2" \
     --notes-file notes.md dist/Brownie-0.2.dmg dist/Brownie-0.2.dmg.sha256
   ```
   Add `--prerelease` for a beta. A beta is not what `releases/latest` points at, so the website's button goes to the releases page.
8. **Update the appcast** (once updates are live): add an `<item>` to `appcast.xml` on the website with the version, the disk image's URL, its length and the Sparkle signature from step 4, then deploy the website.
9. **Download what you published** and verify it, because the file on GitHub is the one that matters:
   ```
   curl -sL -o /tmp/check.dmg <the release asset URL>
   shasum -a 256 /tmp/check.dmg
   spctl -a -vv -t install /tmp/check.dmg
   ```

## If notarisation is refused

`xcrun notarytool log <submission id> --apple-id … --team-id … --password …` says which binary failed. It is almost always a nested library signed without the hardened runtime or without a secure timestamp. Fix the signing of that binary in `Scripts/release.sh` and submit again; nothing else needs to change.

## Withdrawing a release

A build that crashes on the first screen is worse than no build. Delete it — `gh release delete v0.1 --cleanup-tag` — and say why in the notes of the one that replaces it.
