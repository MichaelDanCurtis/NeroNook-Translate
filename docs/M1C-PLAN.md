# Milestone 1c · engine comparison plan

**October 20, 2026 · planning only.** This runs the protocol in [ARCHITECTURE-PLAN.md §6.1](ARCHITECTURE-PLAN.md#61-engine-comparison-protocol-m1c). D‑4 (recognition) and D‑5 (translation) were taken on October 20 from its first scripted receipts (Apple by default, an optional Qwen recognition pack); the rest of the comparison is the evidence behind that option and its in-app description. Nothing here downloads, records or installs anything; every such step is an owner approval listed below.

## Status, October 20 (evening)

- **Decision taken (D‑4, D‑5):** Apple SpeechTranscriber and Apple Translation by default; an optional in-app pack with Qwen3‑ASR 1.7B for users who want better names and numbers; the Qwen text model joins the pack only if the review sheets favour it. Basis: the owner's scripted English take (Apple 9.5% / names 41%; Qwen 1.7B with a names list 6.4% / 91%). Still to measure before the pack's description is written: Apple with its own names list, the natural take, Spanish, and the translation review sheets.

- **Approved and done (items 6–9):** the five pinned downloads, the Mandarin Apple speech asset, the Nemotron and bf16 imports, and Hy‑MT2 through Voice's interpreter environment (read-only). Hashes and receipts are in `PROVENANCE.md` and `reports/m1c-engine-comparison-2026-10-20/`. The Spanish Apple asset waits on item 1 (variety).
- **Harness built, independently reviewed and smoke-tested** on the synthetic fixtures with every candidate and mode; see the receipt. Every pass records CPU time and footprint per process, MLX counters and GPU utilization (no privileges); energy and thermal behaviour still need `powermetrics` (root) and wait for Milestone 3. Three things it taught: Qwen3‑ASR and the aligner need a one-time `--prepare-model` run (the runtime writes `tokenizer.json` into the model folder, which the sandbox then keeps read-only); Apple Translation reports installed packs as `supported` to any binary that SwiftPM's build system stamps with the deployment target as SDK, fixed with an explicit linker platform version; the Qwen3.5‑2B checkpoint is multimodal and its text model loads alone.
- **Waiting on the owner:** items 2–5 (recordings, speakers, corrections), 10 (pass bars) and 11 (listeners). Item 1 is settled (`es-MX`). Nothing in the comparison is scored until the recordings exist.

## Already on this Mac (October 20 inventory)

| Candidate | Where | Needed action |
| --- | --- | --- |
| Apple Translation EN↔ES, EN↔ZH | installed system assets | none |
| Apple SpeechTranscriber | English, Mexican Spanish (`es-MX`, installed October 20 after item 1) and Mandarin installed | done (approval 7) |
| Nemotron 3.5 ASR 0.6B 8‑bit | Voice's model folder | import by clone + hash (approval 8) |
| Qwen3‑TTS Base 1.7B 8‑bit | Translate storage (imported in 1b) | none |
| Qwen3‑TTS Base 1.7B bf16 | Hugging Face cache (`mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16`, snapshot complete, 4.2 GB) | import by clone + hash (approval 8); no download |
| Qwen3‑0.6B 4‑bit text model | Hugging Face cache (complete, 335 MB) | smoke test of the translation path only; too small to be the candidate |
| Hy‑MT2 1.8B 4‑bit | Voice's `build/interpreter-models/translator` (970 MB) + `interpreter-venv` | run read‑only for measurement (approval 9) |
| Qwen3‑ASR 0.6B / 1.7B, Qwen3‑ForcedAligner, Qwen3‑TTS 0.6B Base, Qwen3.5‑2B text | not present | download (approval 6) |
| `ffmpeg` | `/opt/homebrew/bin/ffmpeg` | none; makes the Opus call‑codec copies |
| Microphones | Komplete Audio 6 MK2, MacBook Pro, iPhone | none |

## Owner approvals and actions

1. ~~Choose the Spanish variety.~~ **`es-MX` (Mexico), chosen October 20.** Apple speech uses `es-MX`; Nemotron's checkpoint has no Mexican prompt, so it runs with `es-US`; Apple Translation and the Qwen models are variety-agnostic.
2. Record the English set: `Fixtures/Corpus/scripts/en.md`, then ~4 minutes of natural speech on its prompts.
3. Arrange a Spanish speaker for `es.md` plus natural speech, with their agreement to be recorded and to have the recording used in these tests.
4. Arrange a Mandarin native speaker for `zh.md` (may trail the EN↔ES pass).
5. Correct the drafted transcripts of the natural parts (you and the speakers).
6. Approve the pinned downloads: Qwen3‑ASR 1.7B 8‑bit and 0.6B 4‑bit, Qwen3‑ForcedAligner 0.6B 4‑bit, Qwen3‑TTS 0.6B Base, a Qwen3.5‑2B 4‑bit text model (about 5 GB together; exact sizes and hashes are recorded at import).
7. Approve the Apple speech asset downloads for Spanish and Mandarin.
8. Approve imports from Voice's model folder and the Hugging Face cache (Nemotron 3.5; the bf16 TTS variant if complete).
9. Approve read‑only use of Voice's interpreter environment to run Hy‑MT2.
10. Confirm or amend the §6.1 pass bars before scoring. With D‑4/D‑5 taken, the bars describe the two shipped paths rather than gate a choice; the names and dates bars are out of reach on the current take for every engine (two shared misses), which the receipt says.
11. Listeners for the TTS‑variant part: one or two people who know the owner's voice, plus the Spanish and Mandarin speakers for pronunciation.

## Recording how‑to (per speaker, about 10 minutes)

The easy way is the local recorder page: it shows each script as a teleprompter, records from the microphone you choose with echo cancellation, noise suppression and automatic gain switched off, lets you listen back, and saves 16‑bit WAV straight into the right folder. Nothing leaves the Mac.

```bash
python3 -I scripts/corpus-recorder.py
```

Then open <http://127.0.0.1:8765> in Safari or Chrome, allow the microphone, pick the language and the Komplete Audio 6 (or the MacBook microphone), and record the three takes below. A quiet room, your usual pace, no headphones needed.

QuickTime Player works too (File → New Audio Recording, quality Maximum): save the files under `Fixtures/Corpus/raw/<language>/` (git ignores them; recordings never enter the repository). Any format QuickTime writes is fine (`.m4a`); the names matter:

| File | What to record |
| --- | --- |
| `raw/en/scripted.m4a` | `Fixtures/Corpus/scripts/en.md`, every numbered sentence once, naturally, with a short pause between sentences; a slip is fine, just continue |
| `raw/en/natural-1.m4a` (and `natural-2.m4a` if you split it) | about four minutes of unscripted speech on the prompts at the end of the script; one take under ten minutes |
| `raw/en/reference.m4a` | sentences 1 to 3 of the script read again as one take, 10 to 20 seconds; this becomes your reference voice for the listening set |

The same three files under `raw/es/` for the Spanish speaker (`scripts/es.md`), and under `raw/zh/` for the Mandarin speaker (`scripts/zh.md`), who may trail. Stereo recordings are fine (channels are averaged).

Then one command does the rest:

```bash
scripts/run-m1c.sh
```

It derives the scripted gold, installs the Apple speech asset for the chosen Spanish variety, drafts a transcript for each natural recording as `gold/<language>/<name>.draft.txt`, makes the Opus call‑codec copies, runs the comparison with every candidate (paced and under load) for the language pairs the recordings allow, builds the listening‑set voices from the reference takes, and renders the listening set. Natural recordings count only after the speaker corrects the draft and renames it to `<name>.txt`; run the command again afterwards. Everything lands under `reports/m1c-engine-comparison-<date>/run/`; the listening key stays under `private/`.

## Work that needs no approval (starts now)

- **Harness:** `TranslateCheck --compare`: corpus loader (scripted sentences with known text; natural parts with corrected transcripts), WER and CER with per‑category checks for names, numbers and dates, final‑result and partial latency timing, an under‑load mode that runs Qwen synthesis concurrently, Opus re‑encoding through `ffmpeg`, and JSON plus Markdown receipts.
- **Recognition adapters:** Apple `SpeechAnalyzer` in‑app; Nemotron 3.5 and Qwen3‑ASR in a `TranslateASR` helper target of the `Engine/` package, with Qwen's `context` name list switchable; the forced aligner is loadable in the helper for timestamps but is not scored in 1c.
- **Translation adapters:** Apple `TranslationSession` in‑app; a Qwen text model through MLXLLM in the engine with context and glossary prompts; a driver for Hy‑MT2 against the interpreter environment.
- **TTS variants:** engine support for loading a different Base checkpoint (bf16, 0.6B) and a listening‑set writer that renders the same sentences with the same references for blinded rating.
- **Scoring sheets** for the meaning checklist and the listening ratings.

## Order

1. ~~Harness and adapters (code), smoke‑tested on the synthetic fixtures.~~ Done October 20.
2. ~~Owner replies to 1~~ (`es-MX`, October 20) and 10 and schedules 2–4 (6–9 approved October 20). The §6.1 pass bars stand as written unless the owner changes them before scoring starts.
3. ~~Downloads and imports on approval; hashes into `PROVENANCE.md`.~~ Done October 20.
4. Recordings arrive; `scripts/run-m1c.sh <variety>` makes codec copies and transcript drafts; speakers correct the drafts; run again.
5. Comparison runs: EN↔ES first (both directions), then TTS variants, then EN↔ZH when the Mandarin set exists. Receipts under `reports/m1c-…`.
6. ~~D‑4 and D‑5 decided from the receipts~~ (taken October 20; the receipts now describe the pack); Milestone 1d opens.

## Exit (from the plan)

Every candidate scored on the same corpus with the same receipt; pass bars agreed before scoring; caption latency measured while synthesis is saturated; D‑4 and D‑5 recorded in §8 with the receipts' numbers.
