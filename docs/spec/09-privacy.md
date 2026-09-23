# 09 · Privacy

## Data classes and where each may go

| Class | Examples | On disk | To the brain | To a Brownie server |
|---|---|---|---|---|
| Raw | files, messages, mail bodies, screenshots | read from source, WAL-safe copies deleted immediately | **never** | never |
| Summary | reader output, PII-scrubbed | store (fed to the notes once, judged once, then kept thirty days as the evidence behind a rated note and deleted) | yes | never |
| Eval corpus | a note the user rated, its verdict and the summaries that name it | `Application Support/Brownie/Evals/notes`, one JSON file per rating, written only when the user rates a note | — | never |
| Knowledge base | Markdown notes | `~/Brownie Knowledge Base` | yes (for judge/verify/Hands grounding) | only the sealed mirror, opt-in (v1.1) |
| Cards, letters | prepared actions | store | — | never |
| Sensitive | anything the reader or backstop flags | **nothing** (count + time + source only) | never | never |
| Credentials | API keys, OAuth tokens | Keychain | to the vendor they belong to | never |
| Diagnostics | crash traces, counters | opt-in | — | opt-in only |

## Sensitivity policy (typed, enforced by construction)
- `Survivor` values can only be created by `SensitivityPolicy.admit(_:)`, which runs the PII backstop.
  The pipeline cannot store or forward a summary that didn't pass.
- The drop log stores `reason` enums only; no free text.
- Progress events for sensitive items carry no title/summary.

## Retention
- Summaries: until the end of the next fully successful run.
- Drop log and run stats: 90 days.
- KB: until the user deletes it.
- Sealed mirror (v1.1): deleted on toggle-off; auto-deleted 30 days after the last sync.

## Wipe
- **Reset** (Settings → About): summaries, cursors, drop log, runs, KB, letters, cards, walkthroughs.
  Keeps settings and credentials.
- **Uninstall**: everything above + model files + cache + Keychain items + login item + wake helper
  (launchd unload + file removal, admin prompt) + app bundle, then quits. There is no account to close.

## Diagnostics (off by default, two separate switches)
- Crash reports: stack traces only; symbolicated locally; never include note or message text.
- Usage counts: event names and counts only ("run.completed", "card.fired"); random per-install id
  rotated on reset; no identifiers.

## Permissions copy (System Settings prompts are explained in-app before they appear)
Full Disk Access · Accessibility · Screen Recording · Microphone · Speech · Contacts · Calendar ·
Automation. Each is explained in one sentence with what stops working without it.

## Third-party terms
Brain engines use the user's own API keys under the vendor's API terms. Source connectors use the
user's own account under that service's terms. Brownie does not proxy either.
