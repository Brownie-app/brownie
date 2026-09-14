# 11 · Measured facts and numbers the design rests on

These are engineering facts (not expression) gathered from public documentation, the category's
published architecture, and platform behaviour. Re-measure any of them on our own hardware before
relying on them in a release; mark with `[MEASURED]` once we have.

## On-device inference
- Gemma 4 E4B `.litertlm` ≈ 3.7 GB on disk; needs ~10 GB free for download + cache. Runs on 8 GB
  Apple-silicon Macs; E2B (~2.5 GB) for tighter machines.
- LiteRT-LM GPU (Metal) backend works for text and vision on macOS; GPU vision ≈ 20% faster than CPU
  with the same quality. Package: `https://github.com/google-ai-edge/LiteRT-LM` (SwiftPM, binary
  xcframework, macOS 12+). Latest tag at time of writing: v0.17.0.
- Sampler: `topK 64 / topP 0.95` (vendor recommendation); `temperature 0.15` for reliable JSON while
  avoiding the greedy repetition groove. Runtime default `topK 1` produces loops — always set the
  sampler explicitly.
- A 1,024-token output cap bounds a repetition loop to ~16 s instead of ~165 s at the KV ceiling.
- Long runs can wedge the GPU executor (buffer-map errors) after which every call fails; a full
  engine teardown + ~1 s pause + fresh load recovers it. Preemptive reload every ~40 items keeps
  overnight runs clean. One unguarded run in the category produced >1,500 cascade failures.
- Fresh conversation per item keeps RAM flat across hundreds of items.
- First load ≈ 10 s (shader compilation); warm ≈ 3–5 s.
- Throughput on M-series: ~2–3 items/s for short files; a chat window of ~12 KB takes ~3–6 s.

## Sleep and wake (macOS)
- `PreventUserIdleSystemSleep` assertion does **not** hold a closed lid.
- `pmset schedule wake` fires reliably; the sleeping process resumes at the wake.
- `pmset disablesleep 1` (root) holds the Mac awake with the lid shut; must be released by a deadman
  outside the app.
- GPU inference runs with the lid shut.

## Data formats
- WhatsApp Desktop (Mac) keeps history in plaintext SQLite (WAL); message dates are seconds since
  2001-01-01 (Apple reference date). Group container path under `~/Library/Group Containers/`.
- iMessage `~/Library/Messages/chat.db`: modern message text is in an archived attributed-string
  blob (`attributedBody`), plain `text` for older rows; dates are nanoseconds since 2001.
- Apple Notes `NoteStore.sqlite`: bodies are gzip-compressed protobuf; plain text is recoverable.
- All three need Full Disk Access; WhatsApp's install can be detected without it.

## Cloud
- A single request to a frontier model should stay under ~1 MB; we cap at 950 KB and slice KB
  inputs at ~700 KB parts. Verified in the category at ~1,800 summaries / 2.5 MB → 4 parts with no
  fragmentation across the seams.
- High reasoning effort is the sweet spot for KB synthesis; the highest tier thinks far too long.

## Product
- A first-run soft launch in this category reached 2,000+ installs in 48 h from one community post.
  Assume install spikes; the model download must be resumable and hosted where egress is free
  (Hugging Face).
