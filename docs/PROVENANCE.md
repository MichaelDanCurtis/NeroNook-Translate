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

Recipes are pinned with `scripts/pin-model.py` (exact commit, every file's size, the Hub's SHA-256 for LFS files); the first verified download or import records the hashes of the small files and rewrites the recipe complete. `scripts/download-model.py` fetches a recipe from huggingface.co at its commit. Run the scripts with `/usr/bin/python3 -I`: the python.org build on this Mac has no certificate bundle.

| Model | Commit | How it arrived | Receipt |
| --- | --- | --- | --- |
| Qwen3-TTS-12Hz-1.7B-Base-8bit | `e7dd0585…` | Imported October 20, 2026 from Voice's model folder (owner approved) | `reports/m1b-engine-2026-10-20/model-import.json` |
| Qwen3-TTS-12Hz-1.7B-Base-bf16 | `a6eb4f68…` | Imported October 20 from the Hugging Face cache snapshot of the same commit, LFS files verified against Hub hashes (approval 8) | `reports/m1c-engine-comparison-2026-10-20/import-qwen-base-bf16.json` |
| nemotron-3.5-asr-streaming-0.6b-8bit | `7279359e…` | Imported October 20 from Voice's model folder, LFS files verified against Hub hashes (approval 8) | `…/import-nemotron.json` |
| Qwen3-ASR-1.7B-8bit | `a8379a2e…` | Downloaded October 20 (approval 6) | `…/download-qwen3-asr-1.7b-8bit.json` |
| Qwen3-ASR-0.6B-4bit | `313d8501…` | Downloaded October 20 (approval 6) | `…/download-qwen3-asr-0.6b-4bit.json` |
| Qwen3-ForcedAligner-0.6B-4bit | `2f652af8…` | Downloaded October 20 (approval 6) | `…/download-qwen3-forced-aligner-0.6b-4bit.json` |
| Qwen3-TTS-12Hz-0.6B-Base-8bit | `50f45ef0…` | Downloaded October 20 (approval 6) | `…/download-qwen-base-0.6b-8bit.json` |
| Qwen3.5-2B-4bit | `674aaa72…` | Downloaded October 20 (approval 6); a multimodal checkpoint whose text model the pinned runtime loads alone | `…/download-qwen3.5-2b-4bit.json` |

Hy‑MT2 1.8B 4‑bit is not imported: for the comparison only, `scripts/hymt2-server.py` runs it from Voice's `build/interpreter-models/translator` through Voice's interpreter environment, read-only (approval 9). All model licenses are Apache-2.0 except Nemotron (NVIDIA Open Model License); rights review before any packaging remains an M0 exit item.

**Generated files next to checkpoints.** The pinned runtime writes a `tokenizer.json` (built from `vocab.json` and `merges.txt`) into a Qwen3‑ASR, ForcedAligner or Base TTS folder that ships without one the first time it loads it. `TranslateCheck --prepare-model` did that once outside the sandbox on October 20, 2026; the files are not part of the Hub revision and are listed in `reports/m1c-engine-comparison-2026-10-20/prepared-tokenizers.json` with their sizes and SHA‑256. Verification of a folder against its recipe ignores them.

## Engine dependencies

`Engine/Package.swift` pins `mlx-audio-swift` to `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT), the same revision Voice's helper uses; its transitive pins (mlx-swift 0.31.6, mlx-swift-lm 3.31.4, swift-transformers 1.3.4 and others) are recorded in `Engine/Package.resolved`. Voice's `patch-mlx-audio.py` changes only Nemo alignment code, which the engine does not use, so no patch is applied.
