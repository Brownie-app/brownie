# Brownie — behavioural spec

Brownie is a macOS app. Every night, while the Mac is plugged in and the user is asleep, it wakes the
machine, reads what is new in the user's life — files, messages, notes, mail, calendar, work apps —
using a small model that runs entirely on the Mac, distils what matters into a private knowledge base,
and prepares a handful of "morning cards": things worth the user's attention, each ready to do in one
tap. **Hands** is the part that acts: a computer-use agent that drives the user's own apps with its
own cursor and always stops one step short of anything irreversible.

This spec describes *behaviour and invariants*. It is written from a behaviour-level understanding of
the category (Sentient OS's public architecture was studied on 13 Sep 2026; its code, prompts and
docs were not retained and are not to be consulted during implementation — see `provenance.md`).

## Vocabulary (used verbatim in UI copy — never "AI")

| Word | Meaning |
|---|---|
| **the reader** | the on-device model (Gemma 4 E4B via LiteRT-LM). Reads and filters. Never online. |
| **the brain** | the frontier model the user already pays for (ChatGPT/OpenAI, Claude, OpenRouter, local). Decides, writes notes, drafts. Sees summaries only. |
| **Hands** | the computer-use agent. Acts in the user's apps. Stops before sending, paying, deleting. |
| **source** | one app or place Brownie reads (Files, WhatsApp, iMessage, Notes, Gmail, Calendar, Slack, …) |
| **item** | the unit the reader judges: one file, one note, one *window* of a chat, one mail thread |
| **summary** | the reader's short, third-person, PII-free description of a kept item |
| **knowledge base (KB)** | the brain's synthesis of all summaries: plain Markdown files on disk + an index |
| **card** | a prepared, verified, one-tap action shown on the For You screen |
| **recipe** | the structured steps Hands or a connector runs when a card is fired |
| **run** | one pass of the pipeline (overnight or "Analyze now") |

## The pipeline (one run)

```
1. READ (on-device)      for each enabled source → for each bucket → for each new item:
                           reader judges: keep / drop / sensitive → summary
                           commit (summary + cursor) atomically
2. SYNTHESISE (brain)    new summaries → KB build or update (staged, atomic swap)
3. JUDGE (brain)         last 7 days of summaries (+ calendar) → up to 8 candidate cards, ranked
4. VERIFY & PREPARE      each candidate checked against live data; survivors get a draft + recipe
   (brain, read-only)    → ≤5 ready cards
5. FINISH                wipe the run's summaries (they are disposable); notify (never before 7 AM)
```

Stage 1 is the only stage that sees raw data. Stages 2–4 see summaries and the KB. Stage 5 of a
*failed* run keeps the summaries so the next run retries synthesis.

## Invariants (must hold in every build; tests exist for each)

1. **Raw data never leaves the Mac.** Only summaries and KB text reach a brain. No exceptions, no
   flags.
2. **Sensitive items leave zero trace.** No summary, no title, no log line with content, no cursor
   note beyond "one item was dropped as sensitive at <time> from <source>".
3. **Fail closed.** If the reader's output can't be parsed, the item is dropped (not kept, not
   retried indefinitely).
4. **Nothing is sent, paid, submitted or deleted without a user tap on that specific step.** Hands
   and connector recipes stop before the irreversible action and hand the button to the user.
5. **Every card carries its evidence** (which summaries/sources) and a plain-words "why".
6. **Numbers are honest.** Every run reports read / kept / not-worth-keeping / sensitive-erased.
7. **No account.** Identity to any Brownie-run service (if any) is a random token in Keychain.
8. **The Mac's copy is the truth.** Any cloud copy is disposable and user-deletable in one action.
9. **Deletion is total.** Uninstall removes app, model, KB, cursors, helper, login item, cloud copy.
10. **Walkthroughs play once.** Keyed per screen; completion is stored; only Settings → About → Replay
    resets.

## Non-goals for v1

- No auto-sending of anything, ever, even opt-in.
- No Windows/iOS/Android.
- No Brownie-hosted server (the sealed cloud mirror is v1.1).
- No third-party plugin API beyond MCP.

## Spec files

- `01-sources.md` — the Source contract, buckets, keys, and each v1 source's facts
- `02-reader.md` — on-device inference: model, settings, resilience, the judgement contract
- `03-ingest.md` — the run: cursors, atomic commit, first run vs incremental, resume
- `04-knowledge.md` — the knowledge base: layout, build/update, editing, search
- `05-proactive.md` — judge, verify & prepare, cards, recipes, firing
- `06-brain.md` — frontier model abstraction, engines, capabilities, costs
- `07-hands.md` — computer use, confirmation policy, hold-to-talk, command bar
- `08-overnight.md` — scheduler, wake helper, power rules, health log
- `09-privacy.md` — sensitivity policy, PII backstop, retention, wipe, diagnostics
- `10-app.md` — screens, walkthroughs, settings, notifications, menu bar
- `11-measured.md` — numbers and physical facts the design rests on
- `provenance.md` — what was studied, when, what was deleted
