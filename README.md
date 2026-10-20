# NeroNook Translate

An independent NeroNook plugin for one-to-one calls in two languages. Each person hears the other in a voice that sounds like them, speaking the other language. Both directions have live original and translated captions. Saving the meeting is optional and keeps the original audio, a bilingual transcript and notes that cite their evidence.

Product brief: [PRD](../NeroNook/docs/TRANSLATE-PRD.md) · [handoff](../NeroNook/docs/TRANSLATE-CLAUDE-HANDOFF.md). Design and decisions: [architecture plan](docs/ARCHITECTURE-PLAN.md). Origins of anything brought in: [provenance](docs/PROVENANCE.md).

## Status

| Milestone | State |
| --- | --- |
| 0 · Plan and decisions | Delivered October 19, 2026. D‑1 to D‑14 decided except D‑4/D‑5 (recognition, translation), which wait for the engine comparison. |
| 1a · Workspace skeleton and `TranslateCore` | Delivered October 20, 2026, independently reviewed; 55 tests pass. [Receipt](reports/m1a-workspace-skeleton-2026-10-20/README.md). |
| 1b · `TranslateEngine` with one model and three voices | Delivered October 20, 2026, independently reviewed: 100 overlapped stress rounds with 0 errors and no audio after any cancel, switch overhead ≈0 ms, first audio ≈150 ms, RTF 0.29. [Receipt](reports/m1b-engine-2026-10-20/README.md). |
| 1c–1d · Engine comparison, voice experiments | Not started. |
| 2–5 · Audio routing, live calls, saved meeting, notes and packaging | Not started. |

Nothing is installed, nothing captures audio and no model is downloaded by this workspace yet.

## Layout

```
Package.swift            Swift package: TranslateCore (Foundation + CryptoKit, no SDK), TranslateCheck, tests
Resources/NookPlugin.json  Plugin manifest (cafe.nero.plugin.translate, launchMode application)
Sources/TranslateCore/   Versioned session schema, append-only journal, revision rules,
                         two-lane synthesis scheduler, consent and persistence policy,
                         caption window, evidence items and per-item staleness
Sources/TranslateEngineClient/  Engine protocol client: process supervision, framing, reference decoding
Sources/TranslateCheck/  Host-free checks: manifest validation, journal replay, engine receipts
Engine/                  Separate MLX helper package → TranslateEngine (one Qwen Base model, three voice slots)
Fixtures/                Journal sample; synthetic reference clips for engine measurements
Tests/                   State, schema and protocol tests
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

Engine receipts (needs the imported Qwen Base checkpoint, see `docs/PROVENANCE.md`):

```bash
.build/debug/TranslateCheck --engine Engine/.build/release/TranslateEngine --model "$HOME/Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models/Qwen3-TTS-12Hz-1.7B-Base-8bit-e7dd0585652209fa0d7783659aad4e8a324de11c" --voices Fixtures/Voices --out reports/m1b-engine-2026-10-20
```

Requires macOS 26 and a Swift 6 toolchain on Apple silicon. The package uses the Swift 5 language mode, like the other NeroNook plugins; strict concurrency checking is not on yet. `doctor` verifies the vendored SDK hashes; the drift check for copied Voice code arrives with the first such copy.
