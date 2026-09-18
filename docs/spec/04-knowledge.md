# 04 · Knowledge base

The KB is the brain's synthesis of everything the reader kept. It is **plain Markdown on disk**, owned
by the user, plus a local index Brownie maintains.

## Layout
```
~/Brownie Knowledge Base/
  README.md                 ← the map: one line per folder and 3–5 recent updates, ≤ 350 words (the user prefers an index over a portrait)
  Today.md                  ← the day's cards as checkboxes for the phone; never knowledge (not indexed, counted, searched or served)
  People/<Name>.md          ← one file per person, forever; People/Archive/ for the quiet ones
  Groups/<Name>.md          ← one file per group chat; Groups/Archive/
  Work/<Project>.md
  Money/…  Health/…  Trips/…  Home/…  Admin/…  (≤ 10 root folders; People/ and Groups/ never count)
  .brownie/people.json      ← the person registry (below); not a note, not mirrored as one
```
- Target density **80–120 notes**; a topic folder holds 2–5 substantial notes (the file tools refuse a
  ninth); overflow is consolidated, never fragmented. Fewer, denser notes beat many thin ones.
- Amounts, account details, diagnoses and ID numbers are **never** in the KB (the reader already
  omitted them; the builder is told not to invent them).
- **Less knowledge is better than wrong knowledge.** The builder omits anything uncertain.

## The brain writes prose; code owns the file
Every note carries **code-owned front-matter** (`NoteMeta`): `brownie` (kind: person, group, topic,
portrait), `id`, `aliases`, `sources` (which sources and chats contributed), `created`, `updated`,
`user_edited`, `content_hash`, and any keys the user added, kept verbatim in order. `updated` is the day
the *substance* last changed — a hash over the body with the status block stripped — so aging, the
gardener and the status block never move it, and a body that no longer hashes to what Brownie last
wrote reads as **edited by the user** wherever it was edited (this app, Obsidian, the phone, the
household). The brain's `read_file` shows the body without front-matter or status block; `write_file`
puts both back byte for byte and refuses, with one sentence naming what to do instead: overwriting a
note the part has not read, an eleventh root folder, a ninth note outside People/ and Groups/, a README
past 350 words, a period-stamped or near-duplicate title, a second People/ file for someone the registry
already places, and any delete under People/ or Groups/. A live vault is stamped once at bootstrap.

## People and groups
- **The registry** (`.brownie/people.json`): every person seen, with their spellings and chat handles
  (WhatsApp JID, phone, Telegram id, Slack user, email). One matcher, `PersonKey`, decides whether two
  labels are the same person, and every place that compares people (loops, asks, the quiet check, card
  dedupe, the household) goes through it. Two names that may be one person are shown on the Notes screen
  as a banner — *Merge* folds the notes and ledgers, *Keep separate* is remembered and never asked again.
- **The status block** (`<!-- brownie:status -->` … `<!-- /brownie:status -->`) sits under the title of a
  People note and is Brownie's ledger of what is open between the user and that person: ⏳ they asked
  / you promised, ✅ answered or done (shown 14 days, then a dated one-liner under Earlier), ⌛ let go
  (an ask 45 days unanswered, a promise 90 days old). Code writes it; the brain and the editor never see it.
- **What a People note answers, in order**: where things stand today (the first bullet under Now), what is owed both ways (the status block), who they are to the user and what they are doing together (the first bullet under About). One bullet per thread: a continuing thread rewrites its bullet with the newest state; the gardener folds a second telling into the newer one.
- **The shape** (kept by the gardener every night, so a year of runs cannot bloat or stale a note):
  `# Title` · status block · `## About` (standing facts, undated, ≤ 20) · `## Now` (dated bullets, ≤ 6,
  none older than 45 days — what the cards are made from) · `## Context` (dated, ≤ 12) · `## Earlier`
  (one line per month, ≤ 12 lines, nothing past a year). Every dated bullet ends `(YYYY-MM-DD)` or
  `(since YYYY-MM-DD)`; an undated one is marked `(date unclear)` rather than given a date.
- **Archive**: a person quiet for 180 days (a group for 120) with nothing ⏳ moves to `People/Archive/`;
  the moment a summary, ask or loop names them again the note comes back. Archived notes stay
  searchable and on the phone; the brain and the health counts do not see them.

## What is read the first time
Connecting a chat source does not read its whole history: the first read takes 90 days (600 messages
per direct chat, 300 per group), mail 30 days, files 180 days, notes a year, recordings 90 days. The
Sources screen says exactly what was read ("WhatsApp: 14 chats, 90 days, 2 older not read") and
**Read further back** reaches older messages on request. A message dated in the future or before the
source existed is recorded once as bad-dated and never moves a cursor.

## Build (first time) and update (every run)
Both are **agentic**: the brain works in a staging directory with file tools, writing/editing notes
across turns. Both are **staged, then atomically swapped** into place:

1. `newStagingDir()` — sibling of the KB (same volume, so the swap is atomic). Build seeds it empty;
   update seeds it with a copy of the live KB. Orphaned staging dirs are swept first.
2. Feed the summaries as a **byte-budgeted sequence of parts** (~700 KB each; entries never split;
   deterministic slicing so a resume re-derives identical parts). Part 1 uses the build prompt; later
   parts fold in through the update prompt into the same staging dir.
3. Verify: build → > 0 notes; update → the live KB's fingerprint (`sha256` over
   `relpath|size|mtime` of every `.md`) still equals the one captured at seed time. If the user edited
   a note during the run, **abort the swap** (discard staging, retry next run) rather than clobber.
4. Swap with `FileManager.replaceItemAt`. Any throw leaves the live KB untouched.
5. Re-index.

**Resume:** a `ResumeToken {sessionID?, stagingPath, sliceIndex, fingerprint}` persists to the store;
a usage-limit error or app restart resumes the same staging dir at the same part instead of
rebuilding from scratch. A token whose staging dir is gone is discarded.

## Update prompt requirements (our words)
- ~90% of merges edit an existing note; a new file is rare and must be "genuinely deserved".
- Every merge must make the KB *more valuable*, not merely longer.
- Source-trust tiers: the user's own words > DMs > group chats > inferred.
- Cite nothing that isn't in a summary; never assume; prefer omission.
- Keep shape targets (folders, density) and the README map current.

## Index and search (`KnowledgeStore`)
- SQLite FTS5 over note title + body; a query is the AND of its words (prefix on the last, a quoted
  phrase kept whole, only pure function words dropped) with a snippet per hit; when nothing matches
  strictly, Ask and the MCP server fall back to a loose OR. Optional local embeddings (EmbeddingGemma
  via LiteRT-LM) for semantic search — used by Hands and the command bar to ground actions.
- A watcher on the vault folder: an edit in any editor or from the phone re-indexes and refreshes the
  Notes screen within seconds; `user_edited` follows from the hash, not from who saved.
- Backlinks: `[[Name]]`, `[[Name|alias]]` and `[[Name#heading]]` resolve through titles and aliases;
  a note shows where it is mentioned.

## Vault health and housekeeping
Every night at FINISH the vault is counted — notes per folder, words and their median, the largest
notes, what is over budget (README past 350 words, a person or group past 1,500, anything else past
2,500), quiet people, links no note answers to, pairs that may be one person, the oldest ⏳ line — into
one record a day kept 90 days, and read on Settings → Knowledge as a sentence with the lists behind
it. The same pass lets go of what has aged out: runs and drops past 90 days, sends past 30, Sunday
letters past 26 weeks, transcripts nobody asked for in 180, and rotates the log.

## Editing in-app
The Notes screen renders the Markdown (headings, lists, checkboxes, links; the status block as its own
card; the HTML markers never shown) and searches as you type; ⌘K opens any note by name. *Edit* opens
the raw Markdown without the front-matter and status block, which are put back on save. Deleting a
note asks first; it deletes the file and (when the mirror is on) the sealed cloud copy within a minute,
and a note deleted on the Mac is taken off the phone rather than coming back.

## The welcome letter
Once, the first time a KB exists, the brain writes a short first-person letter *about the user* from
the finished KB. It is stored in the app's store (not in the KB, not mirrored) and shown as a sealed
envelope card until opened.

## The graph
A derived view: nodes are `People/*` and `Work/*` notes, sized by mention count across summaries in
the last 30 days; edges from co-mentions. No new data; purely a projection of the KB + drop-free
statistics.
