# NeroNook Translate

An independent NeroNook plugin for one-to-one calls in two languages. Each person hears the other in a voice that sounds like them, speaking the other language. Both directions have live original and translated captions. Saving the meeting is optional and keeps the original audio, a bilingual transcript and notes that cite their evidence.

Product brief: [PRD](../NeroNook/docs/TRANSLATE-PRD.md) · [handoff](../NeroNook/docs/TRANSLATE-CLAUDE-HANDOFF.md). Design and decisions: [architecture plan](docs/ARCHITECTURE-PLAN.md). Origins of anything brought in: [provenance](docs/PROVENANCE.md).

## Status

| Milestone | State |
| --- | --- |
| 0 · Plan and decisions | Delivered October 19, 2026. D‑1 to D‑14 decided; D‑4/D‑5 taken October 20 from the first comparison receipts: Apple recognition and translation by default, an optional in-app Qwen recognition pack. |
| 1a · Workspace skeleton and `TranslateCore` | Delivered October 20, 2026, independently reviewed; 55 tests pass. [Receipt](reports/m1a-workspace-skeleton-2026-10-20/README.md). |
| 1b · `TranslateEngine` with one model and three voices | Delivered October 20, 2026, independently reviewed: 100 overlapped stress rounds with 0 errors and no audio after any cancel, switch overhead ≈0 ms, first audio ≈150 ms, RTF 0.29. [Receipt](reports/m1b-engine-2026-10-20/README.md). |
| 1c · Engine comparison | Harness built October 20, 2026 and smoke-tested on the synthetic fixtures with every candidate: Nemotron, Qwen3‑ASR 0.6B/1.7B, Apple speech; Apple Translation, Qwen3.5‑2B, Hy‑MT2; paced, under‑load and listening‑set modes; independently reviewed, 86 tests pass. Waiting on the owner's recordings and the Spanish variety (items 1–5 of [the plan](docs/M1C-PLAN.md)). [Receipt](reports/m1c-engine-comparison-2026-10-20/README.md). |
| 1d · Voice experiments | Not started. |
| 2–5 · Audio routing, live calls, saved meeting, notes and packaging | Not started. |

Nothing is installed and nothing captures audio. The models under `~/Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models` arrived by owner approval and are listed with their hashes in `docs/PROVENANCE.md`.

## Layout

```
Package.swift            Swift package: TranslateCore (Foundation + CryptoKit, no SDK), TranslateCheck, tests
Resources/NookPlugin.json  Plugin manifest (cafe.nero.plugin.translate, launchMode application)
Sources/TranslateCore/   Versioned session schema, append-only journal, revision rules,
                         two-lane synthesis scheduler, consent and persistence policy,
                         caption window, evidence items and per-item staleness
Sources/TranslateEngineClient/  Helper protocol clients: process supervision, framing, audio decoding (engine and recognizer)
Sources/TranslateCompare/  Milestone 1c comparison: corpus, scoring, candidate adapters, paced runs, load, receipts, listening set
Sources/TranslateCheck/  Host-free checks: manifest validation, journal replay, engine receipts, --compare, --listening-set
Engine/                  Separate MLX helper package → TranslateEngine (Qwen TTS + Qwen text translator) and TranslateASR
Fixtures/                Journal sample; synthetic reference clips; corpus scripts and gold text (recordings stay out of git)
scripts/                 Model pin/download/import with hashes, Hy-MT2 server, corpus gold and codec helpers
Tests/                   State, schema, protocol and comparison tests
Vendor/NookPluginSDK/    Exact vendored SDK snapshot (see SDK-SNAPSHOT.json)
Tools/                   Vendored Creator kit: doctor, validate, signing helpers
docs/                    Plan, provenance, data format
```

## Build and check

```bash
swift build
```

```bash
swift test
```

```bash
python3 -I Tools/nook.py doctor .
```

The MLX helper is its own package. Its `Package.resolved` is seeded from Voice's pins so every transitive version matches (the resolver would otherwise pick a newer `mlx-swift`); keep it that way when updating.

```bash
swift build -c release --package-path Engine
```

That builds both helpers, `TranslateEngine` and `TranslateASR`. Engine receipts (needs the imported Qwen Base checkpoint, see `docs/PROVENANCE.md`):

```bash
.build/debug/TranslateCheck --engine Engine/.build/release/TranslateEngine --model "$HOME/Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models/Qwen3-TTS-12Hz-1.7B-Base-8bit-e7dd0585652209fa0d7783659aad4e8a324de11c" --voices Fixtures/Voices --out reports/m1b-engine-2026-10-20
```

### Engine comparison (Milestone 1c)

Once, after importing a checkpoint that ships without `tokenizer.json` (Qwen3‑ASR, the ForcedAligner, the 0.6B and bf16 Base TTS variants), so the runtime's generated file exists before the sandbox makes the folder read-only:

```bash
.build/debug/TranslateCheck --prepare-model qwen3asr --asr-helper Engine/.build/release/TranslateASR --model Qwen3-ASR-0.6B-4bit
```

```bash
.build/debug/TranslateCheck --prepare-model tts --engine Engine/.build/release/TranslateEngine --model Qwen3-TTS-12Hz-0.6B-Base-8bit
```

The comparison itself, on the synthetic fixtures (plumbing check) or on the recorded corpus:

```bash
.build/debug/TranslateCheck --compare --fixtures Fixtures/Voices --languages en,es --recognizers nemotron,qwen3asr-0.6b,qwen3asr-1.7b,apple --translators apple,qwen3.5-2b,qwen3.5-2b-nocontext,hymt2 --pairs en:es,es:en --paced --load --asr-helper Engine/.build/release/TranslateASR --engine Engine/.build/release/TranslateEngine --hymt2-python "../NeroNook-Voice/build/interpreter-venv/bin/python" --hymt2-model "../NeroNook-Voice/build/interpreter-models/translator" --out .build/compare
```

`--corpus Fixtures/Corpus` replaces `--fixtures`; `scripts/corpus-codec.sh Fixtures/Corpus` makes the Opus call-codec copy that the loader picks up as `@codec` items (`--kinds scripted,natural,codec` filters). `--paced` feeds energy-gated phrases in real time for final and partial delays; `--load` runs Qwen TTS continuously for a second pass of every measure; `--spanish-locale es-ES` changes Apple's Spanish and Nemotron's prompt (default `es-MX`, the owner's choice; Nemotron uses `es-US` for Latin American varieties); `--install-speech-locale es-ES` downloads an Apple speech asset (owner approval). Every pass also records resources without privileges: CPU time and footprint per helper and for the harness itself, MLX counters from the helpers, and the GPU's device utilization polled from the graphics driver. Outputs: `compare-receipt.json`, `compare-summary.md`, `translation-review.md`, `rows.jsonl` (every row as it completes).

`python3 -I scripts/corpus-recorder.py` serves a local recorder page (teleprompter, WAV, saved straight into `Fixtures/Corpus/raw/`). With recordings in place, `scripts/run-m1c.sh` runs the whole comparison (Spanish variety `es-MX` by default) (gold, Spanish speech asset, transcript drafts via `--draft-gold`, codec copies, the comparison, voices from the reference takes via `--voices-from-corpus`, the listening set); `docs/M1C-PLAN.md` has the recording how‑to.

The TTS listening set, one engine per variant, blinded clips with the key under `private/` (never shown to listeners, never committed):

```bash
.build/debug/TranslateCheck --listening-set --engine Engine/.build/release/TranslateEngine --voices Fixtures/Voices --variants base-1.7b-8bit,base-1.7b-bf16,base-0.6b-8bit --intervals 0.32,0.16 --asr-helper Engine/.build/release/TranslateASR --out .build/listening
```

Requires macOS 26 and a Swift 6 toolchain on Apple silicon. `TranslateCheck` is linked with an explicit `-platform_version` (Package.swift) because SwiftPM 6.4's build system otherwise stamps the deployment target as the SDK version and Apple Translation then reports installed language packs as not installed; any executable of this plugin that uses Translation needs the same until SwiftPM fixes it. The package uses the Swift 5 language mode, like the other NeroNook plugins; strict concurrency checking is not on yet. `doctor` verifies the vendored SDK hashes; the drift check for copied Voice code arrives with the first such copy.
