# Twenty nights

Twenty invented but ordinary stretches of days, replayed through the real pieces in the real order —
the ask scan and detection, the verdicts, the ledger merge, the loops the asks settle, loop admission
and merge, the due nudges, dedupe, the quiet check, the status block, the note's shape. The only
stand-in is the cloud judge, which needs a network: each scenario scripts what a real judge would
plausibly have handed back that night, and everything downstream of it is the app's own code.

`Tests/ScenarioTests/` holds them. Run with:

```
swift test --skip EvalTests --filter ScenarioTests
```

A scenario whose expectation is not met stays failing and is marked `@Test(.disabled("fails: …"))`, so
the suite is green for everyone else and the gap is written down rather than argued away. One of the twenty
is disabled today: scenario 3, which is half fixed and now waits on the on-device reader this harness does not run.

Two things the harness does not do, both narrower than the app: the status block is rendered per person
by name rather than routed through `PersonRegistry` (the app's routing is stricter, so this can keep a
line the app would file elsewhere — never drop one it would keep), and the on-device reader is never
consulted, so every verdict below is one the rules reached on their own.

## The twenty

| # | Scenario | What should happen | What happens | |
|---|---|---|---|---|
| 1 | Asked today, answered tomorrow | Day 1: open, one card. Day 2: answered, no card, a ✅ line on her note | Exactly that. (An ask with nothing said after it carries no verdict at all rather than `open` — the block, the judge lines and the card are all right, so this is a shape of the data, not a fault) | PASS |
| 2 | Nothing today, asked tomorrow | Day 1: nothing at all, not even a block. Day 2: one open ask, one card | Exactly that | PASS |
| 3 | Answered three days later, unrelated chat in between| The ask waits through the noise and closes on day 4; no second ask is invented| On day 2 the user's sympathetic “oh no” about her cancelled train no longer reads as a refusal — “oh” is no longer stripped in front of a bare “no”, and a reply with no content word in it at all now reads as *open* rather than as too little to tell. Day 3's “good, get some sleep” still needs the reader, which this harness does not run, and an unjudged reply still closes an ask by benefit of the doubt | **HALF** |
| 4 | "Checking now" then the real answer | Day 1 reads as a promise and stays open; day 2 answers it | Exactly that: "give me" is a later, and the day-2 answer replaces the promise. The known weak point holds here | PASS |
| 5 | They confirm it themselves | Closed, credited to them, no card | Exactly that — `confirmedByThem`, "they said it's done" on the note | PASS |
| 6 | The user declines| Closed as declined, no card, no nagging| Read as **declined**. A refusal is now tested before a later, so “can't” wins over “this week” — unless the same line commits to doing it anyway (“can't today, will send tomorrow”), which is still a promise | PASS |
| 7 | A card dismissed, proposed again next night| It does not come back| It does not come back. `QuietCheck` now recognises the card itself, not just its loop: the same person and four words in five shared with a card you dismissed inside a fortnight, dropped with “you turned this down” | PASS |
| 8 | A card marked done, proposed again| It does not come back| It does not come back, loop id or no loop id — a card you fired is quiet for the card's own lifetime | PASS |
| 9 | Two cards for one commitment, routed two ways | One card, or a rule a user could state | One card when a loop id ties them, whatever channel; one card when the same person is told the same thing twice in other words; two cards for two different people, because two people each need telling. That is the rule | PASS |
| 10 | A group question that is not for the user | No ask, no card | Nothing is kept — though only because groups are skipped wholesale, which is the same reason 11 fails | PASS |
| 11 | A group question addressed to the user by name| An ask| An ask, on Sneha's own note rather than the group's. `scanAsks` now hands groups to the detector, and `AskDetector` keeps a group line only when it names the user (`SelfNames.addressed`) — so Deepak's “same question about the pricing sheet”, addressed to the room, is still nothing | PASS |
| 12 | A promise that is a sentiment | No loop | "Build something big together" and "Focus on her network" are turned away with a reason; the deliverable said in the same breath is admitted | PASS |
| 13 | A promise with a due date in words | The right date, and a card the morning before | "by Friday" said on Tuesday is that Friday at 9; "next week" and a named September day both parse; the nudge lands on Thursday morning and is not sent twice | PASS |
| 14 | The same promise from both sides | One loop | The mirror is turned away with a reason; the user's own side stays | PASS |
| 15 | Mail: asked in a thread, answered two days later| The ask closes on the reply, from mail| **Nothing happens.** This passed while mail was read over Gmail's API, which hands back a thread id with every message. The OAuth source was removed in favour of IMAP, which has no thread id, so `MailSource` is a `Source` and nothing more — no `ChatReader`, no `AskScanning` — and the ask ledger never asks it for anything. Threading a mailbox means walking `References`/`In-Reply-To`. The same thread replayed as messages still gives the right ask and verdict, so the gap is the wiring, not the reading | GAP |
| 16 | Telegram: a channel, forty messages, no questions | Nothing kept, no cards | Nothing kept. Not only because channels come back as groups: read line by line, none of the forty trips `AskDetector.isAsk` either | PASS |
| 17 | Slack: a DM asking for a review, answered in a thread| Closed| Closed. `historyPaged` now follows each thread with replies into `conversations.replies` once and merges them in time order, so an answer written in a thread is a line like any other. The chase card is dropped too, by a new rule that will not chase a person who has answered that question in the last week | PASS |
| 18 | Cross-channel: asked on WhatsApp, answered on Slack | `ask_updates` can close it; say what happens without | Without the judge, the WhatsApp ask stays open and the note says "no reply yet" — nothing on the Mac ties one chat's answer to another chat's question. With `ask_updates` by id the ask closes, the card stops, and the note reads "answered on Slack … (the judge)" | PASS |
| 19 | An ask never answered for fifty days| Lapses at 45 with a ⌛ line; the card stops firing long before| The lapse is exact and the ⌛ line is right, and the nudge now stops after the first morning it is turned down instead of arriving on all fifty | PASS |
| 20 | One person, two spellings, two apps| Two records, nothing crossing, the merge question raised| Two records, one question raised, and the ledgers now agree: `LoopLedger.same` and `CardDedupe.same` both compare with `PersonKey.sameKey`, so “Lokesh” and “Lokesh Kadri” keep their own loop and their own card until the user merges them | PASS |

## Companions

Three more tests sit beside the twenty, each pinning down where a line actually falls.

| Test | What it shows | |
|---|---|---|
| `aPlainRefusalIsRead` | "sorry, can't" without a week in it is read as declined — which is what makes 6 a rule-order bug and not a missing rule | PASS |
| `aNamedDayThatHasJustGoneBy` | "September 6" said on the 9th is read as three days ago, not next year, so the nudge fires overdue on the spot | PASS |
| `aPromiseInReplyClosesTheLoopItPromised` | Scenario 13's promise, said as a reply to the question that prompted it, now survives the night. `AskLedger.answering` no longer counts “send” and “share” as replying — a loop about sending a thing is not a loop about answering — and it matches whole words, where “let” used to match “wallet”. “By Friday” is read as a promise now, like “tomorrow” | PASS |
| `whichSourcesCarryAsks` | States once which sources the ask ledger can reach at all, so a new source is not quietly left out. Mail joined the roster; nothing is left off it now | PASS |
