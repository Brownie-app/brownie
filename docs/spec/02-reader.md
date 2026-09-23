# 02 · The reader (on-device inference)

## Model and runtime
- **Gemma 4 E4B instruction-tuned**, `.litertlm` format, ~3.7 GB, from Hugging Face
  `litert-community/gemma-4-E4B-it-litert-lm` (public, no token). E2B is the fallback for Macs with
  < 12 GB memory (user-selectable; auto-suggested).
- **Runtime: LiteRT-LM** Swift package, GPU (Metal) backend for text *and* vision. Behind the
  `LocalModel` protocol so it can be swapped (MLX, llama.cpp) without touching the pipeline.
- Model lives in `~/Library/Application Support/Brownie/Models/`. Resolution order: env override
  (`BROWNIE_MODEL_PATH`) → Application Support → app bundle (if someone bundles it). Missing model ⇒
  Home shows "the reader is missing" with a download button; nothing else breaks.
- A writable cache dir for compiled shaders: `~/Library/Application Support/Brownie/ModelCache/`.
  First load after install ≈ 10 s; warm loads faster.

## Engine wrapper (`Reader`)
An actor that owns one engine for the duration of a run. Surface:

```swift
actor Reader: LocalModel {
    init(modelPath: URL, contextTokens: Int, collectStats: Bool = false)
    func load() async throws                 // expensive; once per run
    func generate(_ req: GenerateRequest) async throws -> GenerateResult   // stateless: fresh conversation per call
    func reload() async throws               // full teardown → 1 s pause → load  (GPU-wedge recovery)
    func unload()
}
```

- **Stateless per item.** A fresh conversation per `generate` — no history bleed, flat memory.
- **No streaming** in the pipeline path; the full response is collected. (Streaming exists only for
  the dev "thinking" trail and is optional.)
- **Sampler:** `topK 64`, `topP 0.95`, `temperature 0.15`. Never greedy (argmax loops), never hot
  (JSON reliability). See `11-measured.md`.
- **Output cap:** 1,024 tokens per item — a backstop against runaway repetition, not a size target.
- **Speculative decoding** on when the runtime supports it (Gemma 4 ships draft heads).
- **Vision:** JPEG bytes in; visual token budget 280 — the public `.litertlm` build ships vision signatures 70/140/280 only (560 returns null) `[MEASURED]`; 560/1120 for
  dense documents when the user opts into "careful" mode.
- **Context:** sized to the largest window any enabled source produces (chat windows need ~16k).

## Resilience (the pipeline owns *when*, the reader owns *how*)
- Preemptive `reload()` every 40 items.
- Reactive `reload()` after 3 consecutive failures; the failing item is retried once on the fresh
  engine, then counted as failed and skipped (no poison pills, no per-item retry bookkeeping).
- After 4 reloads with no forward progress the run stops with a typed error; the morning banner
  explains it.

## The judgement contract
The reader receives **one item** and returns **one compact JSON object**. Keys in this order:

```
{"summary": "<~30 words, third person, 'the user' never 'I' or 'Me'>",
 "title":   "<3–6 words>",
 "keep":    true|false}
```
plus, only when it applies: `,"sensitive": true`.

Rules the prompt must encode (write our own words; these are the *requirements*):

1. **Summary first, then judge.** Writing the summary forces the model to read before deciding.
2. **Default to not keeping.** Most of a Downloads folder and almost all chat is not worth a place in
   a curated vault of someone's life. Keep only durable facts: plans, commitments, decisions, people,
   recommendations, dates, bookings.
3. **Attribution is the #1 rule for group chats.** Only "Me" is the user. Anyone else's "I", "my",
   "I'm building", "I won" is about *them*. Participating in a discussion is not a fact about the
   user. Every fact in the summary names whose it is; a subject-less fact is forbidden.
4. **Sanitise, don't just flag.** If an item is useful *and* contains private specifics (an amount,
   an account detail, a diagnosis), keep it and omit the specifics. Mark `sensitive` only when nothing
   useful remains after omitting — an ID document, a password, a bank statement, raw medical records.
5. **"Not keeping" never deletes anything** — the item stays where it is on disk. The prompt says so,
   so the model judges vault-worthiness, not file-worthiness.
6. Today's date and the item's own dates are supplied so "expired" and "upcoming" are judged
   correctly.

Prompt flavours by `SourceKind`: `document` (files, notes, Drive), `directMessage`, `groupChat`
(much stricter), `mail`, `event`, `ticket`. Same output contract for all.

## Decision (`Verdict`)
```
parse fails               → drop      (reason: parseFailed)     ← fail closed
sensitive == true         → sensitive (reason: modelSensitive)  ← zero trace
keep == false             → drop      (reason: modelDrop)
summary empty             → drop      (reason: emptySummary)
PII backstop hits         → sensitive (reason: piiBackstop)     ← zero trace, summary discarded
otherwise                 → keep
```
Parsing is lenient (isolate the outermost `{…}`, recover individual fields from almost-JSON) but a
missing summary or an unreadable `keep` still fails closed. Reasons are counted separately so the
diagnostics can tell "the model dropped it" from "the model garbled it".

## PII backstop (`Privacy`)
Deterministic regexes on the *summary and title* of every would-be keeper: US SSN, Luhn-valid card
numbers, passport-shaped numbers, Indian Aadhaar (12 digits, Verhoeff-valid) and PAN
(`[A-Z]{5}[0-9]{4}[A-Z]`), IFSC + account-number pairs. A hit drops the whole item as sensitive.
The backstop runs *behind* the model, never instead of it.

## Prompts are files
`Packages/Ingest/Prompts/*.md`, one per flavour, versioned. A fixture harness in `Tests/Eval/` runs
them against a labelled corpus and reports keep/drop/sensitive accuracy and attribution errors.
