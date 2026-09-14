# 01 · Sources

A source is one app or place Brownie reads. Sources are dumb: they list keyed work-items per bucket
and load one. All cursor logic, retries, and judgement live in the ingest core, never in a source.

## The contract

```swift
public protocol Source: Sendable {
    static var descriptor: SourceDescriptor { get }     // id, display name, kind, door, permissions, icon
    func availability() async -> Availability          // .available | .notInstalled | .needsPermission(…) | .needsSignIn
    func buckets(since marks: [BucketID: ItemKey]) async throws -> [Bucket]
    func load(_ candidate: Candidate) async throws -> Artifact
}
```

- **`SourceKind`** drives the reader's judgement flavour: `.document` (files, notes, Drive docs),
  `.directMessage`, `.groupChat` (WhatsApp/iMessage/Telegram/Slack groups & channels), `.mail`,
  `.event` (calendar), `.ticket` (Linear/GitHub issues, PRs).
- **`Door`** is how the data is reached: `.localDatabase` (Full Disk Access), `.localAPI`
  (EventKit etc.), `.userCloud(OAuth)` (Gmail, Telegram, Slack…), `.mcp(server)`.
- **`Bucket`** = an independent stream with its own cursor: a folder, a chat, a channel, a mailbox
  label, a project. `BucketID` is stable across runs (`"whatsapp:<chat-id>"`, `"files:<root-id>"`).
- **`ItemKey`** = a totally-ordered key within a bucket: `(order: Double, tiebreak: String)`.
  Files → `(dateAdded, path)`; notes → `(created, uuid)`; chat windows → `(lastRowID, "")`;
  mail → `(internalDate, messageId)`. Uniqueness is required so a cursor names exactly one boundary.
- **`Candidate`** = `{bucket, key, kind, sourceID, metadata}` — enough to load, nothing more.
- **`Artifact`** = `{candidate, text?, imageData?, metadata}` — the thing the reader sees.
- `since` marks are a hint for efficient listing; the core filters authoritatively, so a source may
  return extra items.
- Sources never throw for "nothing new". They throw for "could not read at all"; the core records the
  bucket as failed for this run and continues with the next bucket.

## Chat windowing (shared by every chat-like source)

The item for a chat is not a message but a **window**: a time-ordered slice of one chat sized by a
UTF-8 byte budget (~12 KB target, hard cap so the prompt never exceeds context). Each line is
`[time] Sender: text`; the user's own lines are labelled `Me`. The window header states the chat
name, DM vs group, member count, and *how many of the messages in this window are the user's* — the
reader needs that to avoid absorbing other people's lives into the user's. A window's key is the
last message's row id.

## v1 sources

| Source | Kind | Door | Where | Bucket | Key | Needs |
|---|---|---|---|---|---|---|
| Files | document | localDatabase (filesystem) | user-chosen roots; defaults Documents, Desktop, Downloads | root | (dateAdded, path) | none (user grants folder access on first pick) |
| Apple Notes | document | localDatabase | `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` | "notes" | (created, uuid) | Full Disk Access |
| iMessage | dm / group | localDatabase | `~/Library/Messages/chat.db` | chat | (rowid, "") | Full Disk Access |
| WhatsApp | dm / group | localDatabase | WhatsApp Desktop's group container `ChatStorage.sqlite` | chat | (rowid, "") | Full Disk Access; WhatsApp installed |
| Gmail | mail | userCloud (Google OAuth, own client) | Gmail API, last 7 days, threads | label/inbox | (internalDate, id) | Google sign-in |
| Calendar | event | userCloud or localAPI (EventKit) | last 7 days + next 24 h, all events | calendar | (start, id) | Calendar permission / Google sign-in |
| Telegram | dm / group | userCloud (TDLib, own account) | chats the user picks | chat | (messageId, "") | phone sign-in, API id/hash |
| Slack | group | userCloud (OAuth) or mcp | channels the user picks | channel | (ts, "") | Slack sign-in |
| Linear, GitHub, Notion, Granola, Drive | ticket / document | mcp (or OAuth) | user's MCP server | project/repo/workspace | (updatedAt, id) | MCP address + sign-in |
| Generic MCP | per manifest | mcp | any MCP server with a `list`/`get`-shaped tool pair | per manifest | (updatedAt, id) | address |

### Files — skip rules and caps
- Skip: hidden files, bundles/apps, installers (`.dmg .pkg .app .zip` > 20 MB), caches, `node_modules`,
  git internals, anything > 25 MB, anything the OS marks as a package.
- Text extraction: plain text, Markdown, code, CSV, PDF (text layer), docx/pages via Spotlight
  importer where available; images (`png jpg heic`) are downsampled to ≤1024 px JPEG for the reader's
  vision input; everything else is judged from path + dates only.
- Caps per run: 2,000 items per root on a first run (oldest deferred to the next run), 400 per root
  incrementally. The UI shows "deferred N" honestly.

### SQLite sources — the WAL-safe read
Copy the database **plus** its `-wal` and `-shm` files to a private temp dir, open the copy read-only,
read, then delete the copy immediately. A plaintext copy of a whole message history must never
linger. Never open the live database.

### Notes body decoding
Apple Notes bodies are compressed protobuf; extract plain text only. Edited notes are keyed by
creation date, so an edit does not re-trigger a read (accepted trade-off for v1).

### iMessage text
Modern messages store text in an archived attributed-string blob; fall back to the plain `text`
column when present. Resolve handles to contact names via the Contacts framework when permission is
granted; otherwise show the handle.

### Chat opt-in
Chats are **off by default**. The Settings → Sources picker lists chats with counts; only picked
chats are ever read. Group chats show member count and a "you sent N of M" hint.

## Per-source trust tag
Every summary carries `(sourceID, bucket, kind)`. The KB builder uses it as a trust tier: the user's
own documents and DMs outrank group chats; group-chat facts about the user require the user to have
said them.
