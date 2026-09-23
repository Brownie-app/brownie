# 10 · The app

Design source of truth: `design/*.dc.html` and the published canvas
(https://claude.ai/code/artifact/692f3098-ae5a-4001-bc0c-2a31401108f8). This file records
behaviour the pixels don't.

## Windows and process
- One menu-bar process (login item). One main window (sidebar: For You · Notes · Graph · Excluded ·
  Settings). Onboarding is a separate window shown until setup completes. Hands has an overlay
  panel (non-activating, floating, under the notch). Settings is a pane in the main window, not a
  separate window.
- Closing the main window keeps the process alive; Quit warns "no run tonight".
- macOS 14+, Apple silicon only.

## Screens → state
| Screen | Data | Actions |
|---|---|---|
| For You | last run outcome, ready cards, letter (until opened), overnight numbers | Analyze now, open card, dismiss card, open letter |
| Card detail | PreparedAction + evidence + verification line | Fire, Edit draft, Not now, Never cards like this |
| Firing | live executor events | Stop |
| Processing | live run progress | Stop |
| Knowledge | KB folders/notes, editor | edit/save/delete, search, open in Finder |
| Graph | derived from KB + 30-day counts | click node → note card |
| Excluded | drop log counts + rows (reason, source, time) | window: last night / 7 days |
| Settings · Sources | enabled sources, per-chat/channel pickers, roots | toggle, pick, add root, add MCP |
| Settings · Brain | engine picker, key entry (Keychain), status, effort, cost line, reader info | switch, validate, update model |
| Settings · Proactive & Hands | cards/morning, notify, count, standing instructions, hotkey, speed, always-ask | edit |
| Settings · Privacy & Cloud | invariants list, mirror toggle (v1.1), diagnostics switches, wipe | toggle |
| Settings · Overnight | schedule, time, login item, catch-up, health log, test wake | edit |
| Settings · About | version, updates, appearance (System/Light/Dark), menu-bar icon, walkthrough replay, reset, uninstall | — |

## Onboarding (7 steps, once)
Welcome → Download the reader (resumable, checksum) → Choose a brain (key entry, validate) →
Choose sources (personal + work; chats off) → Permissions (open the right pane; drag-to-Settings
guide window follows) → Overnight (time, login item, helper install) → First read (live, can be
backgrounded). Completion stored; never shown again.

## Walkthroughs (FTUE)
Keys: `foryou, card, knowledge, graph, excluded, sources, hands`. Each is a popover anchored to a
target (`.walkthroughTarget("id")`) with a spotlight; completes when the target action happens (or
Skip); stored in `walkthrough_done`; replay from About. Never more than one visible; never during a
processing takeover.

## Notifications
Cards ready (7:30 AM or on completion) · Done reading (after a manual run) · Last night didn't run ·
Hands paused at an irreversible step. No sounds by default. Actions deep-link into the app.

## Menu bar
Status line (last run numbers), top 3 cards, Open, Hands, Command bar, Analyze now, Pause tonight,
Settings, Quit (with the "no run tonight" note).

## Appearance
System / Light / Dark. Tokens only; dark swaps the token set (accent lifts to `#E2A54A`).

## Updates
Sparkle 2, EdDSA-signed appcast, silent background update that relaunches windowless with a
"just updated" notice on next open.
