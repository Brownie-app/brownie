# 05 · Proactive (judge → verify & prepare → fire)

Three parts, lined up exactly on the permission boundary: parts 1–2 are read-only and have no side
effects; part 3 is the single write-capable step and runs only on a user tap.

## Part 1 — Judge (brain, hermetic, no tools)
Input: the last 7 days of summaries from every source (each line: `#n · [source] bucket · date ·
Title — summary`), plus, when Calendar is connected, a plain-text block of the live calendar (last 7
days + next 24 h) fetched beforehand, plus the clock ("Right now it is <date> at <time> (<tz>)" —
without it "prep for the 4 PM meeting" reads the same at 9 AM and 6 PM), plus the user's **standing
instructions** from Settings (free text, high-priority, can exclude/prioritise but never override the
accuracy rules).

Output (structured): up to **8** ranked `ActionItem {title ≤8 words, action, importance (why, naming
the dots connected), dueDate? (real, never invented), sources (evidence by name), urgency
high|medium|low}`. Fewer — even zero — when there genuinely aren't that many.

Requirements for our prompt: cross-source context *grounds* items but is not a filter (a deep
single-source item is valid); no forced spread across sources; judge from summaries alone and say so;
never invent a date or fact; "a confident wrong item is worse than a miss".

## Part 2 — Verify & prepare (brain, read-only tools)
For each candidate, in one pass:
1. **Verify** against live data — the KB, the mail/calendar/ticket APIs (read-only), the web — that
   it is still real, still the user's, still needed. Receipts only: a live fact may be stated only if a
   tool returned it this run. Identity must match (right Priya, right thread). "Couldn't confirm" is a
   valid outcome (`unverified`), shown with lower confidence, never dropped silently.
2. **Prepare** survivors ready to fire: `preparedContent` (the draft, in the user's voice, learned
   from their own messages in the KB) and an `executionRecipe` (routing only).
Prune to **≤5** `PreparedAction`s. Part 2 may correct, enrich or drop; it never adds an item.

Enforced in the invocation, not just the prompt: read-only sandbox, connector write tools stripped
from the tool surface, no computer use.

## Part 3 — Fire (executor, one user tap)
`PreparedAction` → `Recipe`:

```
Recipe.channel ∈ { imessage(to, body, attachments), whatsapp(chat, body), mail(to, subject, body,
                   attachments), calendar(event), note(path, body), browser(url), computerUse(goal) }
```
- Channel recipes use the cheapest reliable route (URL scheme, AppleScript, API) and **stop before
  the irreversible step**: the message is in the field, the email is composed, the event is in the
  dialog — the user presses Send/Save.
- `computerUse` falls back to Hands with the same confirmation policy.
- Live step list in the UI; **Stop** cancels the underlying process; outcome recorded per card
  (`done | stopped | couldNot(reason)`), which feeds the executor scoreboard in diagnostics.

## Cards
- **≤5 per morning** (user-adjustable 3/5/8). Ranked by urgency, then due date.
- Each card shows: title, source chip, why (importance), action label, due/waiting line, evidence
  list, "verified this morning" line, the draft, and the recipe steps in plain words.
- Card states: `ready | fired | dismissed | snoozed(until)`. "Never show cards like this" adds a
  standing instruction.
- Dismissed and fired cards are gone the next morning; unfired ready cards persist for one more day,
  then expire.

## Empty and error states
- No ready cards: "Nothing needs you this morning" + the run's numbers.
- KB-only mode (brain absent or limited): parts 1–2 are skipped, an empty ready list is saved so no
  stale cards linger, the Home explains what a brain would add.
- Cloud usage limit mid-way: typed error, resume token, morning banner "we got half-way; will retry".

## Welcome letter
See `04-knowledge.md`. Rendered as the sealed envelope card above the deck until opened.
