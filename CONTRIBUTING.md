# Contributing to Brownie

Thanks for wanting to help. Brownie is a small codebase with a few hard rules; read this before opening a pull request.

## Set up

Apple silicon, macOS 14+, Xcode 16.

```bash
git clone <this repo> brownie && cd brownie
brew install cmake gperf openssl@3
./Scripts/build-tdlib.sh        # once; builds the Telegram library (~30 min)
./Scripts/bundle.sh && open dist/Brownie.app
swift test                      # unit tests; `swift test --filter EvalTests` runs the reader eval
```

Developer credentials (an OpenAI/Anthropic key, a Google OAuth client, Telegram api_id/api_hash) go in `.secrets/brownie.env` — git-ignored, read only by Debug builds. See `docs/launch-setup.md`. Never commit them.

## The invariants

Every change must keep these true; there are tests for each and a PR that weakens one will not be merged:

1. Raw user data never leaves the Mac. The brain sees summaries only.
2. Anything the reader marks sensitive leaves zero trace — no title, no log line, no card.
3. The reader's judgement fails closed: unparseable output means the item is dropped, never kept.
4. Nothing is sent, paid, submitted or deleted without the user's tap on that exact step. Hands never presses Send.
5. Every card carries its evidence.
6. Run numbers are honest.
7. No account, no telemetry. The Mac's copy is the truth; deletion is total.
8. Walkthroughs play once.

## How the code is arranged

`Sources/Domain` holds value types and protocols and depends on nothing. Every other target depends inward. If you need to add a source, implement `Source` in `LocalSources`/`CloudSources` (or add an MCP preset); if you need a new brain, implement `Brain`/`AgenticBrain`. Prompts live next to the code that uses them (`Prompts/*.md`) and are treated as code: change one, add or update an eval case in `Tests/Eval/Corpus/corpus.json`.

Match the style of the file you are in. No new dependencies without a reason in the PR.

## Clean-room rule

Brownie's architecture was inspired by Sentient OS (AGPL). The implementation, prompts and docs were written from scratch — see `docs/spec/provenance.md`. Do not copy code, prompts or documentation from that project or any other incompatible source into a PR.

## Tests — what "covered" means here

Nothing merges without tests for what it changes. The tiers:

1. **Logic** — unit tests, on every PR (`swift test --skip EvalTests`, a few seconds). Cursors, the ledger of loops, card merging, every parser of brain output (they fail closed on garbage), the MCP server's protocol and off-switch, recipe recording and replay rules, the send log, scheduling decisions.
2. **Brain-facing code** — tested against recorded responses, never live API calls in CI.
3. **Prompts** — the eval corpus (`Tests/Eval/Corpus/corpus.json`). Needs the 3.7 GB reader, so it runs locally (`swift test --filter EvalTests`) and must be run before a release; the score must not drop. Add a case for every miss you see on real data.
4. **Integration** — the SQLite store, the knowledge base index, the MCP server end to end, all in-process.
5. **Not automatable** — Hands driving real apps, Telegram sign-in, Calendar, the 3 AM wake, notarisation. These are on the release checklist (`docs/release-checklist.md`) and are run by hand.

A PR that changes behaviour without a test in tiers 1, 2 or 4 will be sent back. Coverage is reported by CI; there is no percentage gate, because gates get gamed and punish honest refactors.

## Pull requests

- One change per PR, with a sentence on *why*.
- Tests pass (`swift test`); the eval score does not drop.
- If the change touches something the user sees, include a screenshot.
- You will be asked to sign the [Contributor License Agreement](CLA.md) once (a comment on your first PR is enough).

## Reporting security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
