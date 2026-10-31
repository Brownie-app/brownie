# Changelog

All notable changes. Brownie follows semantic versioning once 1.0 ships; before that, minor versions may change behaviour.

## Unreleased

**Mail is any mailbox now, and Gmail's sign-in is gone.** Reading your mail used to mean signing in to Google, which meant Brownie needed a Google OAuth client, an annual security assessment for a restricted scope, and a refresh token that expired every seven days while the app sat in Testing — and it only ever worked for Gmail. Mail is now read over IMAP with an app password you create yourself: Gmail, iCloud, Outlook, Fastmail, Proton through its Bridge, or a work server you type in. It is read with `EXAMINE`, so a 3 am read never marks anything seen, and only the headers are fetched for mail the reader drops on its subject line.

**What this costs, for now:** asks and loops no longer come from mail. Gmail's API handed back a thread id with every message, so a mail thread could be read as a conversation and a question in it could close on your reply. IMAP has no thread id — grouping a mailbox into conversations means walking `References` and `In-Reply-To` — so until that exists, mail is read and summarised but never reaches the ask ledger. Scenario 15 in `docs/scenarios.md` is marked GAP rather than quietly dropped.

## 0.3 — 11 October 2026

**A free brain that actually works.** Until now every key-free option gave you a daily note and nothing else: the small reader on your Mac can't build a knowledge base, and without notes there are no cards, because a card has to be grounded in one. On a Mac running macOS 26 with Apple Intelligence turned on, Brownie can now borrow Apple's own on-device model — no key, no signup, no download of ours — and it writes real notes. Cards and drafts follow from those. "What left your Mac" still reads 0 bytes.

If Apple Intelligence is switched off, the option says so and offers to take you to the right pane; turn it on, come back, and it's ready without restarting. On a Mac that can't run it, the option isn't offered at all rather than sitting there failing.

Hands is deliberately not part of this. A three-billion-parameter model shouldn't be driving your apps yet.

**A brain that answers badly no longer costs you the night.** If the model returns something Brownie can't use, it now writes the half of the night that never needed a model — the day's note, the status block — and carries on to the cards, instead of throwing all of it away. A rejected key or an exhausted quota still stops the run and says so, because that's yours to fix.

**Three ways work was being lost quietly, all fixed.** A night was sliced into parts sized for the largest brain imaginable, then cut down inside a smaller one where nothing could see it — and the whole part was marked as absorbed regardless, so summaries nobody had read were deleted for good. A brain now says how much it can take and the night is sliced to fit. When a cut does happen it drops the oldest rather than the newest, which is what it claimed to be doing all along. And a reply that wrote nothing at all used to pass silently; it fails now.

**The app stopped promising things it couldn't do.** "This Mac only" said notes worked "the same" — they have never once worked on that engine. The failure message said four words and threw away the reply that would have explained it; it now says which of five things went wrong and quotes what came back.

## 0.2 — 11 October 2026

The first build that can update itself. 0.1 shipped with no update feed and no signing key, so it never asks for one — if you are on 0.1, this is the last version you have to download by hand.

**It no longer needs an API key to be worth opening.** Choosing "This Mac only" was labelled "Your own API key" by a caption bug, and a Mac with no key believed it had one anyway: it called OpenAI with an empty token and reported the refusal as your fault. Now no key means no brain, the two options that cost nothing are offered first, and a run without a brain writes real notes — one per day under `Read/`, in the reader's own words, with the questions people are waiting on you for at the top. What it reads is kept unjudged, so adding a brain later still builds the proper notes out of it.

**The first ten seconds are quieter.** Brownie used to ask for Speech Recognition and Notifications before it had said anything, and touched Documents, Desktop and Downloads behind the welcome screen, which made macOS ask three more times with no reason given. Those prompts now arrive on the screens that explain them, carry a reason, and "Files and Folders" is a permission you can see and re-grant instead of a dead end.

**Fixes to what Brownie believes about your conversations**, found by replaying twenty invented weeks through the real rules:

- A card you turned down no longer comes back the next morning, or the fifty mornings after that.
- "Sorry, can't this week" is a refusal, not a promise to do it later.
- A sympathetic "oh no" about something else no longer closes a question you never answered.
- Saying "by Friday" no longer marks the Friday promise done.
- Mail, group chats and Slack threads reach the ask ledger at all now — a request emailed to you, or made to you by name in a group, or answered in a thread, used to be invisible.
- Two people who share a first name keep their own loops and their own cards.

**Also:** on a Mac with under 12 GB the reader that downloaded was not the reader the app then looked for, so it never found one. The first read now starts by itself when the download lands, an interrupted download resumes, and the app no longer starts itself twice at launch.

## 0.1 — 23 September 2026

The first build, signed and notarised, for anyone with an Apple-silicon Mac. It carries no update feed yet, so a later version has to be downloaded by hand.

- Overnight read on-device (Gemma 4 via LiteRT-LM), knowledge base built by your own brain, morning cards, Hands that stop before Send.
- Sources: Files, Apple Notes, iMessage, WhatsApp, Telegram, Calendar, Gmail, Slack, Microsoft Teams, work apps over MCP.
- Things you said out loud: Voice Memos and a folder of meeting recordings, transcribed on this Mac with Apple's speech engine; a promise keeps its timestamp.
- Two-way vault sync with iCloud Drive: edits on the phone come back, Brownie's work goes out, a conflict keeps both under a heading.
- Ask from ⌘⇧Space: a question is answered inline with citations; anything else is a goal for Hands.
- Due-aware nudges the morning before a deadline; recipes that run when a file arrives in a folder.
- Cards that learn: “Not right…” with a reason becomes a standing instruction; the Sunday letter owns the week's corrections.
- Notes that learn: “Was this note right?” under every note — Good, or Not right… with a line — and the brain reads what you said before it writes the notes at night; the summaries behind a rated note stay thirty days and go out with it as a JSON corpus under Application Support/Evals for judging the prompts.
- The evidence viewer: the original chat window or the recording behind any card line or citation, read on demand and never stored.
- The quiet check before cards show: closed loops, fired twins, missing files and old notes (Settings: how old is too old).
- Meeting follow-ups: promises said out loud become loops with a timestamp and “Hear it”. Today.md carries the cards to your phone; a tick there marks the card done.
- A household: share only the group chats you're both in with the person you live with; an “Ours” band says who's on what and when they already did it.
- Loops — promises both ways, came-back cards, nudges. Pre-meeting briefs. The Sunday letter.
- Teach Hands: recipes by demonstration with an editor; replay verifies the right chat before typing.
- Ask, with citations that open the original. The knowledge base as an Obsidian vault, with an iCloud Drive mirror.
- Brownie as an MCP server for Claude Desktop, Cursor and any MCP app, with a log of what they asked.
- Daytime reads while idle and on power. What left your Mac. This-Mac-only brain. Panic wipe. `brownie://` links for Shortcuts and Siri.
- Diagnostics export; plain-words banners for every way a run can fail.
- Notes that stay exact: the first read of a chat takes 90 days (600 messages per direct chat, 300 per group), mail 30 days; the Sources screen says exactly what was read and “Read further back” reaches older messages; a message dated in the future never moves a cursor.
- One file per person, forever: a registry of everyone seen with their spellings and chat handles, one matcher everywhere, a “may be one person” banner with Merge and Keep separate.
- A status block under every People note — ⏳ what they asked and what you promised, ✅ when it was answered (with the reply), ⌛ when it was let go — kept by code, never by the brain; a reply that was not about the ask stays open.
- Code-owned front-matter on every note: `updated` moves only when the substance changes, and an edit made anywhere (Obsidian, the phone, the household) reads as yours.
- People and Groups notes keep one shape (About · Now · Context · Earlier); bullets are dated, age out of Now after 45 days into one line per month, and a person quiet for 180 days rests in Archive until named again. The file tools refuse a sprawl of folders, thin notes, a bloated README and any delete under People.
- The Notes screen, rebuilt: rendered Markdown, search as you type with snippets, ⌘K to open any note, backlinks, a header for each person with “Ask about” and “Open the chat”, delete that asks first, an editor that never loses Brownie's block, and a watcher that picks up edits from Obsidian or the phone within seconds.
- Vault health: every night the vault is measured (notes, words, what is over budget, quiet people, dangling links, the oldest open ask) into a sentence on Settings → Knowledge, and what has aged out is let go.
