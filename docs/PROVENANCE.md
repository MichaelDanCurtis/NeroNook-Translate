# Provenance

Translate builds independently. It never imports Voice or host source. Anything brought in from elsewhere is listed here with its origin, so drift stays visible. `scripts/provenance-check.py` (arrives with the first copied Voice file) diffs each entry below against its recorded origin and reports changes; it modifies nothing.

## Vendored packages

| Path in this workspace | Origin | Revision | License |
| --- | --- | --- | --- |
| `Vendor/NookPluginSDK/` | `NeroNook/SDK/NookPluginSDK` | `91590c9b18255b297bfa1ebdb72fc10af73ff75c` (`main`, host 0.34.24; the clean commit before the seasonal-surface candidate) | MIT (`LICENSE-NookPluginSDK`) |
| `Tools/` | `NeroNook/SDK/Creator` minus `Tests/` and `export-kit.py` | same | MIT |

`SDK-SNAPSHOT.json` records a SHA-256 for every vendored SDK file. `python3 -I Tools/nook.py doctor .` verifies them.

## Copied data

| Path | Origin | Change |
| --- | --- | --- |
| `Resources/Models/qwen-base.json` | `NeroNook-Voice/Resources/Models/qwen-base.json` @ `1600ece` (repository `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit`, revision `e7dd0585…`, 12 files with sizes and SHA-256) | None; data only |

## Copied source (with modification)

None yet. Each future copy records: destination path, origin path, origin commit, what was changed, and why. Planned copies (owner decision D‑14, October 19, 2026):

| Planned destination | Origin | Change intended |
| --- | --- | --- |
| `Sources/TranslateAudio/ProcessTapCapture.swift` | `NeroNook-Voice/Sources/VoiceAudio/MeetingCapture.swift` (itself adapted from the owner's OmniVoice `d3b5940`) | Mute-when-tapped, bundle-ID following, Translate's own exclusion, native rate |
| `Sources/TranslateEngineClient/WireValidation.swift` | `NeroNook-Voice/Sources/ModuleCore/SpeechBackend.swift` (`QwenSpeechWire`) | Framed binary payloads instead of NDJSON base64 |
| `Sources/TranslateEngineClient/ModelRecipe.swift` | `NeroNook-Voice/Sources/VoiceAudio/QwenModel.swift` | Verify at import and on demand, not on every start |
| `Driver/Sources/TimedRing.hpp`, `Driver/Vendor/libASPL/` | `NeroNook-Voice/Drivers/NeroInterpreterAudio/` | New identities; owner-token lease; feeder→microphone and optional speaker→return rings |

## Models

Not bundled. Recipes under `Resources/Models/` pin repository, revision and per-file SHA-256; acquisition is by download on Prepare or by hash-verified import from a user-chosen folder (owner decision D‑7). `scripts/import-model.py` performs the import: APFS clone of every recipe file, then size and SHA-256 verification, into `~/Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models/<repository tail>-<revision>/`.

| Model | Imported | From | Receipt |
| --- | --- | --- | --- |
| Qwen3-TTS-12Hz-1.7B-Base-8bit @ `e7dd0585…` | October 20, 2026 (owner approved) | Voice's model folder on this Mac | `reports/m1b-engine-2026-10-20/model-import.json` |

## Engine dependencies

`Engine/Package.swift` pins `mlx-audio-swift` to `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT), the same revision Voice's helper uses; its transitive pins (mlx-swift 0.31.6, mlx-swift-lm 3.31.4, swift-transformers 1.3.4 and others) are recorded in `Engine/Package.resolved`. Voice's `patch-mlx-audio.py` changes only Nemo alignment code, which the engine does not use, so no patch is applied.
