# 03 · Ingest (the run)

`IngestRun` drives any `Source` through the reader and commits results. It is crash-safe by
construction: **every processed item commits its optional summary AND its cursor advance in one
atomic store write.** There is no window for a crash to land in, so a run never duplicates or skips.

## Store (`RunStore`, SQLite via GRDB or raw sqlite3)
- `bucket_cursor(bucket_id PK, source_id, mark_order, mark_tiebreak, floor_order?, floor_tiebreak?, updated_at)`
- `summary(id PK, run_id, source_id, bucket_id, kind, title, text, item_date, created_at)` —
  **ephemeral**: wiped at the end of a fully successful run.
- `drop_log(id PK, run_id, source_id, bucket_id, reason, at)` — reason only, never content.
- `run(id PK, started_at, ended_at?, trigger, outcome, read, kept, dropped, sensitive, failed, deferred)`
- `walkthrough_done(key PK, at)`; `setting(key PK, value)`.

## Modes
- **Initial** (a bucket with no cursor): walk items newest → oldest, sinking a **floor** (oldest
  item done so far) per item. A crash resumes strictly below the floor. On reaching the bottom the
  floor collapses into the normal high-water mark.
- **Incremental** (a bucket with a completed cursor): take items `> mark`, walk oldest → newest,
  advancing the mark per item.
- **Auto** (what Home and the scheduler use): per bucket — initial if no mark or a floor is set
  (resume), else incremental. One "Analyze now" therefore backfills a new folder, resumes an
  interrupted one, and catches up the rest in a single pass.
- Caps (see `01-sources.md`) are applied per bucket per run; deferred counts are reported.

## Item loop
```
for bucket in source.buckets(since: marks):
  for item in plan(bucket, mode):
     artifact = source.load(item)                 // may throw → count failed, continue
     result   = reader.generate(prompt(artifact)) // may throw → failure streak++
     verdict  = decide(result.text)
     store.commit(bucket, item.key, verdict.summary?)   // ONE write: summary (if kept) + cursor
     stats.record(verdict.reason)
     every 40 items → reader.reload(); on 3 consecutive failures → reload + retry once
```
Progress is published per item: `{source, bucket, index, total, read, kept, dropped, sensitive,
lastTitle?, lastSummary?}`. Sensitive items publish **no** title or summary — only the count.

## Cloud-door sources (Gmail, Calendar, MCP)
Same loop; the source's `load` fetches the item from the user's account to the Mac, and the reader
judges it locally like anything else. (Alternative kept behind the protocol: let the brain summarise
mail server-side. Not used in v1 — it would breach invariant 1 for mail bodies.)

## Run orchestration (`RunCoordinator`)
```
read all enabled sources (on-device)  →  KB build/update (brain)  →  judge  →  verify & prepare
→  wipe summaries  →  record run  →  notify (not before 7 AM)
```
- Only one run at a time (actor). "Analyze now" while a run is active = no-op with a toast.
- A failed cloud stage keeps the summaries and records the failure; the next run retries synthesis
  with the union of old + new summaries.
- The run is **cancellable**: Stop terminates the current reader call, commits nothing partial (the
  last commit already happened), and the run ends as `cancelled`.
- Trigger ∈ `{overnight, manual, catchUp, firstRun}`; the morning banner reads the last run's outcome.

## Factory reset
Wipes summaries, cursors, drop log, runs, KB, and walkthrough completions. Keeps settings and
credentials. Uninstall wipes everything (see `09-privacy.md`).
