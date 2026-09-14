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

## Pull requests

- One change per PR, with a sentence on *why*.
- Tests pass (`swift test`); the eval score does not drop.
- If the change touches something the user sees, include a screenshot.
- You will be asked to sign the [Contributor License Agreement](CLA.md) once (a comment on your first PR is enough).

## Reporting security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
