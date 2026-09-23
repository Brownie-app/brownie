# Release checklist

Run by hand before every tagged release. These are the things no test can prove.

## Automated (must be green first)
- [ ] CI green on `main` (`swift build`, `swift test --skip EvalTests`)
- [ ] `swift test --filter EvalTests` locally — score not below the last release (currently 92 % on 14 cases)

## A real night
- [ ] Settings → Overnight → Test wake in 2 minutes: the Mac wakes, runs, re-arms
- [ ] One real 3 AM run on the release build: cards present at 7:30, numbers honest, send log shows each stage with a purpose
- [ ] A daytime read happened while idle and on power; no notification unless a card appeared

## Sources
- [ ] Files, Notes, iMessage, WhatsApp read without errors; skipped sources say why
- [ ] Gmail sign-in from a clean state; Telegram sign-in with phone + code
- [ ] Calendar: a brief arrives ten minutes before a meeting with people in it

## Hands
- [ ] Fire a WhatsApp card: the right chat opens, the draft is in the box, Send is untouched
- [ ] Teach a recipe in WhatsApp (search → chat → message), run it: header verified, message typed, stops before Send; run it with the wrong chat open — it refuses to type
- [ ] Stop a running recipe from the floating panel, the tile and the menu bar
- [ ] `brownie://run?recipe=<name>` from Shortcuts runs it

## Trust
- [ ] What left your Mac lists every request of the run; payloads contain summaries only
- [ ] Panic wipe: notes, cards, loops, recipes, keys, helper, login item all gone; model stays
- [ ] "This Mac only": a run completes with 0 bytes in the send log

## Other AIs
- [ ] Claude Desktop set-up button writes the config; after restart, `who_is` answers and the ask is logged; toggle off → refusal

## Packaging
- [ ] `Scripts/release.sh <version>`: signed, notarised, stapled DMG; Gatekeeper opens it on a fresh Mac
- [ ] `gh release create v<version> dist/Brownie.dmg` and the site's Download button resolves
- [ ] Sparkle: the appcast entry validates and the previous build updates to this one
