# NeroNook Translate

An independent NeroNook plugin for one-to-one calls in two languages. Each person hears the other in a voice that sounds like them, speaking the other language. Both directions have live original and translated captions. Saving the meeting is optional and keeps the original audio, a bilingual transcript and notes that cite their evidence.

Product brief: [PRD](../NeroNook/docs/TRANSLATE-PRD.md) · [handoff](../NeroNook/docs/TRANSLATE-CLAUDE-HANDOFF.md). Design and decisions: [architecture plan](docs/ARCHITECTURE-PLAN.md). Origins of anything brought in: [provenance](docs/PROVENANCE.md).

## Status

| Milestone | State |
| --- | --- |
| 0 · Plan and decisions | Delivered October 19, 2026. D‑1 to D‑14 decided except D‑4/D‑5 (recognition, translation), which wait for the engine comparison. |
| 1a · Workspace skeleton and `TranslateCore` | Delivered October 20, 2026, independently reviewed; 55 tests pass. [Receipt](reports/m1a-workspace-skeleton-2026-10-20/README.md). |
| 1b–1d · Engine, comparison, voice experiments | Not started. |
| 2–5 · Audio routing, live calls, saved meeting, notes and packaging | Not started. |

Nothing is installed, nothing captures audio and no model is downloaded by this workspace yet.

## Layout

```
Package.swift            Swift package: TranslateCore (Foundation + CryptoKit, no SDK), TranslateCheck, tests
Resources/NookPlugin.json  Plugin manifest (cafe.nero.plugin.translate, launchMode application)
Sources/TranslateCore/   Versioned session schema, append-only journal, revision rules,
                         two-lane synthesis scheduler, consent and persistence policy,
                         caption window, evidence items and per-item staleness
Sources/TranslateCheck/  Host-free checks: manifest validation, journal replay
Tests/                   State and schema tests
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

Requires macOS 26 and a Swift 6 toolchain on Apple silicon. The package uses the Swift 5 language mode, like the other NeroNook plugins; strict concurrency checking is not on yet. `doctor` verifies the vendored SDK hashes; the drift check for copied Voice code arrives with the first such copy.
