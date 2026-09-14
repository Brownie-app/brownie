# 04 · Knowledge base

The KB is the brain's synthesis of everything the reader kept. It is **plain Markdown on disk**, owned
by the user, plus a local index Brownie maintains.

## Layout
```
~/Brownie Knowledge Base/
  README.md                 ← who the user is, in ~200 words; the portrait every other note hangs off
  People/<Name>.md
  Work/<Project>.md
  Money/…  Health/…  Trips/…  Home/…  Admin/…  (≤ ~10 root folders)
```
- Target density **80–120 notes**; a folder holds 2–5 substantial notes; overflow is consolidated,
  never fragmented. Fewer, denser notes beat many thin ones.
- Every note has front-matter: `sources` (source ids + buckets that contributed), `updated`, and an
  optional `user_edited: true` flag.
- Amounts, account details, diagnoses and ID numbers are **never** in the KB (the reader already
  omitted them; the builder is told not to invent them).
- **Less knowledge is better than wrong knowledge.** The builder omits anything uncertain.

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
- Keep shape targets (folders, density) and the README-first portrait.

## Index and search (`KnowledgeStore`)
- SQLite FTS5 over note title + body; optional local embeddings (EmbeddingGemma via LiteRT-LM) for
  semantic search — used by Hands and the command bar to ground actions.
- Watches the KB folder; user edits in any editor re-index within seconds and set `user_edited`.

## Editing in-app
The Knowledge screen is a plain Markdown editor over the same files. Saving writes the file and marks
the KB dirty. Deleting a note deletes the file and (when the mirror is on) the sealed cloud copy
within a minute.

## The welcome letter
Once, the first time a KB exists, the brain writes a short first-person letter *about the user* from
the finished KB. It is stored in the app's store (not in the KB, not mirrored) and shown as a sealed
envelope card until opened.

## The graph
A derived view: nodes are `People/*` and `Work/*` notes, sized by mention count across summaries in
the last 30 days; edges from co-mentions. No new data; purely a projection of the KB + drop-free
statistics.
