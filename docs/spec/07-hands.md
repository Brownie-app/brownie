# 07 · Hands (computer use)

Hands drives the user's own apps with its own cursor and keyboard, grounded in the KB, and stops one
step short of anything irreversible.

## Invocation
1. **Hold-to-talk** — hold right ⌘ (alternatives: right ⌥, off). On key-down: capture a screenshot
   of the frontmost window (if Screen Recording is granted), start on-device speech recognition
   (`SFSpeechRecognizer`, on-device only; never the server option). On key-up: stop, run.
   Esc cancels. The overlay lives under the notch (or top-centre on notch-less Macs).
2. **Command bar** — ⌘⇧Space: a text field with suggestions from recent cards; same run path.
3. **Card fire** — a `computerUse` recipe from `05-proactive.md`.
4. **Menu bar** item.

## The loop
```
goal + KB context (top-k notes by FTS/embedding) + screenshot + accessibility tree of the frontmost app
→ brain.act(goal, policy)
   each step: brain proposes {click(x,y) | type(text) | key(combo) | scroll | open(app) | wait | done | needConfirm(reason)}
   we perform it via CGEvent (own virtual cursor — never moves the user's pointer), re-capture, repeat
→ ActOutcome {done | stoppedByUser | needsUser(step) | couldNot(reason)}
```
- Step cap and wall-clock cap; every step is shown live in the overlay; **Stop** kills the loop.
- A sentinel in the brain's final message reports `DONE` / `COULD_NOT` so outcomes are machine-read.

## Confirmation policy (invariant 4)
`ConfirmationPolicy.alwaysAskBefore = [send, pay, submit, delete, purchase, post]` — on by default,
not user-disableable in v1. The brain is instructed to *stop before* such a step and describe it; the
overlay says "Paused at Send — press it when you're ready" and posts a notification if the app is in
the background. Hands never performs the step itself even if asked ("send it anyway" → "I'll leave
Send to you").

## Permissions
- Accessibility (required) — clicks and typing.
- Screen Recording (optional) — without it Hands works from the accessibility tree only and says so.
- Microphone + Speech (for hold-to-talk).
- Automation (per app, macOS prompts on first use) — for AppleScript-based recipes.

## Speed vs. care
Settings: Fast / Balanced / Careful → the brain's effort and whether the screen is re-read before
every click. Default Balanced.

## What Hands is not
Not a background agent: it runs only while the user is present and the screen is unlocked. It never
runs in the overnight pipeline.
