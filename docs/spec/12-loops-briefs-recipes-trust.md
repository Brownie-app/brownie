# 12 · Loops, briefs, the Sunday letter, recipes, and what left

Added after the first working build. Each reuses the pipeline; none adds a server.

## Loops
A **loop** is a promise in either direction found in the summaries: `mine` (the user said they'd do something) or `theirs` (someone said they'd do something for the user). The judge returns new loops alongside the action items and, given the open loops it already tracks, reports closures by id (`loop_updates`). `LoopLedger.merge` is pure: closures by id prefix, duplicates dropped when person and promise match (≥50 % word overlap), closed loops fall off after 30 days. Loops live in the key/value store as JSON (`proactive.loops`).

**Came back.** When a card is fired, its `loopID` is remembered on the loop (`firedCardIDs`). If the loop is still open at the next read, the judge is told the user already sent one message and may return the item again with `cameBack: true`; the preparer writes a gentler nudge, never a repeat. The card shows a "Came back" chip and a banner.

**Nudge on demand.** The Loops screen's Nudge asks the brain for one card from the loop plus the person's note (`nudge.md`), through the same card parser. Mark done / Not a promise edit the ledger directly.

## What left your Mac
`SendLogger` wraps whichever brain is configured. Every `complete` and every agent `run` (including tool results, which are sent on the next turn) is recorded: purpose (set by the pipeline stage), model, bytes, a one-line detail, what came back, and the exact text sent, capped at 200 KB. Kept 30 days in `send_log`. The sidebar and the numbers row show last night's bytes; the screen shows every row with its payload. "This Mac only" bypasses the wrapper — nothing to log.

## Pre-meeting briefs
Every minute the app looks 8–12 minutes ahead in the calendar. An event with attendees (or capitalised names in its title) gets one brief: People notes for each attendee, open loops with them, recent cards about them → `brief.md` → Markdown. A notification with the first line opens the brief. Stored as `proactive.briefs`, kept 3 days.

## The Sunday letter
On the first run on or after Sunday, once per ISO week: this week's run numbers, cards, loops, the README and the calendar → `weekly.md`. Stored under `proactive.weekly.<yyyy-Www>`; a teaser card on For You until opened; "Write my week now" forces one.

## Recipes (Teach Hands)
**Record.** Global mouse-up and key-down monitors (Accessibility, already granted). A click resolves to the element under the pointer via `AXUIElementCopyElementAtPosition`: role and title only. Typing is buffered per focused field; secure fields are skipped. A press on Send/Pay/Submit/Delete/… or Return with text in the buffer stops the recording with a note. Steps: `launch`, `click`, `type`, `key`.

**Generalise.** A clicked row/cell title becomes the `person` parameter; the last typed text becomes `message`. Each parameter is `fixed`, `ask` (a sheet before running), or `fromNotes` (the brain rewrites it from the knowledge base). Schedule: on demand, or weekly (weekday, hour, minute), checked every minute.

**Replay — the ladder.** 1) An app link where one exists (WhatsApp `send?phone=&text=`, phone from Contacts). 2) The accessibility tree: launch by name, find by role + title, `AXPress` or a click at the frame's centre, `AXValue` for text. 3) The screen agent (Hands), only for apps not on the forbidden list. Replay always ends paused before the last step.

**From anywhere.** `brownie://run?recipe=<name>` and `brownie://ask?text=…` (Shortcuts → "Open URLs" → Siri), the ⌘⇧Space bar (a recipe's name runs it), the menu bar.

## This Mac only
`LocalBrain` implements `Brain` over the reader (Gemma 4 via LiteRT-LM). Input is cut to 36 KB; no tools, so the preparer and knowledge builder use their no-tools paths. Hands is unavailable in this mode. Cards are plainer; the send log reads zero.

## Panic wipe
Settings → Privacy and the menu bar. Hold 1.5 s to confirm. Deletes the store's runs/cursors/summaries/drop log/send log and every `proactive.*`/`knowledge.*`/recipe key, the knowledge base folder and its index, the Telegram session, Google tokens, every Keychain item, the wake helper daemon and the login item. The reader model stays unless the user also uninstalls.

## Daytime reads
`overnight.daytime` = h1 | h3 | off. A loop in the scheduler checks once a minute: between 7 AM and midnight, last run older than the interval, on AC, idle ≥ 10 minutes → a run with trigger `daytime`. Cards: new ready cards replace the ready ones; fired/snoozed/dismissed history is kept. Notifications only when a card appeared.

## The vault
The knowledge base is an Obsidian vault as-is. Prompts write `[[wikilinks]]` on first mention; the note view renders them as links (grey when the target doesn't exist). "Open in Obsidian" uses `obsidian://open?path=`. The iCloud mirror copies changed `.md` files to iCloud Drive/Brownie after each run and removes deleted ones — one way, Mac → iCloud.

## Brownie as an MCP server
`Brownie mcp --client <name>` speaks MCP (JSON-RPC over stdin/stdout, protocol 2025-06-18) — the AI app starts it on demand; nothing listens on a port. Tools: `search_notes`, `read_note`, `who_is`, `open_loops`, `recent_cards`. Every call checks `knowledge.mcp` in the store (off ⇒ a polite refusal) and appends to the "What they asked" log (`knowledge.mcpLog`, 500 entries). Set-up buttons merge Brownie into Claude Desktop's and Cursor's MCP config files without touching other servers; ChatGPT is not possible (its connectors need a public URL). Sensitive notes were never written, so they cannot answer.

## Ask
One question → the brain with `search_notes`/`read_note` and the open loops and waiting cards in the prompt → JSON: an answer with `[n]` markers, citations `{n, kind, label, ref}` and optional actions. Chips open the original: a note, the loops screen, a card, the WhatsApp chat (phone from Contacts), Messages or Mail. Last 30 exchanges are kept.
