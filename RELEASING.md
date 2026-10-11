# Releasing

A release is built on the maintainer's Mac, never in CI: the signing certificate and the app credentials live there and nowhere else. CI proves the code is sound; the Mac produces the thing people download.

## Before you start

You need, once: an Apple Developer account, a **Developer ID Application** certificate in the login Keychain, an app-specific password from appleid.apple.com, and `.secrets/brownie.env` holding `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and the app credentials for Google, Telegram, Slack and Microsoft. See `docs/launch-setup.md`.

You also need the **update-signing key**, made once with `./Scripts/sparkle-keys.sh`. Its private half lives in the login Keychain and nowhere else — not in the repo, not in CI, not in a password manager export. Its public half is in `Scripts/release.sh` on purpose, so what signs an update is a matter of record. **If that Keychain is lost, the key is lost**, and every installed copy stops accepting updates: a new key means a new public key, which only reaches people in a build they install by hand. Keep a Keychain backup.

## The steps

1. **Main is green.** Every change is in through a pull request with a passing build. Nothing goes straight to main.
2. **Write the changelog.** A new section at the top of `CHANGELOG.md`, dated, in the same voice as the rest: what a person will notice, not what the diff says.
3. **Open a pull request for it**, let CI pass, squash it into main, and pull main down.
4. **Build, sign, notarise** from the repository root:
   ```
   ./Scripts/release.sh 0.2
   ```
   It builds the app in release configuration with the app credentials inside, signs it with the hardened runtime, wraps it in a disk image, sends it to Apple, waits for the verdict, staples the ticket, signs the disk image with the update key, and writes the appcast entry into the website repo beside this one.

   It also stamps `CFBundleVersion` with a UTC minute stamp rather than the commit count, because this repo starts from a single commit: two releases cut from the same commit would otherwise look identical to an updater, and nobody would be offered the second.
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
8. **Deploy the website**, so the appcast entry step 4 wrote actually reaches anyone:
   ```
   cd ../Brownie-website && git add -A && git commit -m "Brownie 0.2"
   ```
   then deploy as `DEPLOY.md` there describes. **Order matters**: publish the GitHub release first (step 7), because the appcast points at the release's download URL — a feed that goes live first sends every Mac to a 404.
9. **Download what you published** and verify it, because the file on GitHub is the one that matters:
   ```
   curl -sL -o /tmp/check.dmg <the release asset URL>
   shasum -a 256 /tmp/check.dmg
   spctl -a -vv -t install /tmp/check.dmg
   ```

## Checking that the update itself works

A release that installs is not the same as a release that updates. Once step 8 is deployed:

```
curl -s https://www.usebrownie.com/appcast.xml | head -20        # the new <item> is there, newest first
```

Then, on a Mac running the *previous* version, **Brownie → Check for Updates…**. It should offer the new one, download it, and relaunch. If it says there is nothing new, compare `<sparkle:version>` in the feed against `CFBundleVersion` in the installed app — Sparkle compares those two numbers, not the version you and I call it.

Note that **0.1 cannot be updated**. It shipped before the key existed, with no `SUFeedURL` and no `SUPublicEDKey` in its `Info.plist`, so it never asks. Anyone on 0.1 has to download 0.2 by hand; nothing published afterwards can change that. 0.2 is the first build that can update itself.

## If notarisation is refused

`xcrun notarytool log <submission id> --apple-id … --team-id … --password …` says which binary failed. It is almost always a nested library signed without the hardened runtime or without a secure timestamp. Fix the signing of that binary in `Scripts/release.sh` and submit again; nothing else needs to change.

## Withdrawing a release

A build that crashes on the first screen is worse than no build. Delete it — `gh release delete v0.1 --cleanup-tag` — and say why in the notes of the one that replaces it.
