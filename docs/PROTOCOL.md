# Engine protocol (version 1)

`TranslateEngine` is a separate process built from `Engine/`. The app (or `TranslateCheck`) spawns it under `sandbox-exec` with network, microphone and camera denied, passes `--model <checkpoint directory>`, writes requests to its stdin and reads replies from its stdout. The engine moves its real stdout to a private descriptor before loading anything and points stdout at stderr, because the inference library prints diagnostics.

## Framing

```
u32 big-endian header length · JSON header · u32 big-endian payload length · payload
```

Headers are JSON objects with a `type` and, for requests and their replies, an `id`; values are strings, numbers, booleans, arrays of strings, or arrays of flat objects (segments, alignment items). Headers are at most 64 KiB; payloads at most 64 MiB (ten minutes of 16 kHz Float32 is 38 MiB). Audio payloads are raw Float32 little-endian mono samples. The codec is `Engine/Sources/EngineProtocol/Frames.swift` and its copy `Sources/TranslateEngineClient/EngineFrames.swift`; keep them identical.

## Requests (client → engine)

| `type` | Header fields | Payload | Reply |
| --- | --- | --- | --- |
| `prepareVoice` | `id`, `slot` (`local`/`remote`/`generic`), `transcript` (the exact words in the reference), `language` (Qwen language name for the slot's target), `sampleRate` (must equal the engine's) | reference audio, 3–30 s | `voiceReady` |
| `synthesize` | `id`, `slot`, `text` (≤2,048 bytes), optional `streamingInterval` (0.16–1 s, default 0.32), optional `maxTokens` (clamped to 16–1800; default 1800, about 144 s of audio) | — | `audio`… then `done`, or `error` |
| `cancel` | `id` of a synthesis the engine has already seen | — | none; handled at once, out of band. A cancel for an unknown id is ignored |
| `loadTranslator` | `id`, `model` (checkpoint directory of a Qwen text model; the multimodal Qwen3.5 checkpoint loads its text model alone) | — | `translatorReady` |
| `translate` | `id`, `text` (≤2,048 bytes), `target` (`en`/`es`/`zh` or the Qwen name), optional `source`, optional `context` (previous phrases; the last three are used), optional `glossary` (≤32 names of ≤80 bytes) | — | `translation` |
| `stats` | `id` | — | `stats` |
| `ping` | `id` | — | `pong` |
| `shutdown` | — | — | the engine finishes the requests already queued, then exits 0 |

The engine runs one `prepareVoice`, `synthesize`, `loadTranslator` or `translate` at a time, in arrival order. `cancel`, `stats` and `shutdown` are handled by the reader thread immediately. `language` must be one of Qwen's ten names (English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, Italian).

## Replies (engine → client)

| `type` | Fields |
| --- | --- |
| `ready` | `version`, `sampleRate` (24000), `loadMs`, `residentBytes` — sent once after the model loads |
| `voiceReady` | `id`, `slot`, `seconds`, `prepareMs`, `language`, `residentBytes` |
| `audio` | `id`, `seq`, `sampleRate`; payload is one streamed chunk |
| `done` | `id`, `frames` (all generated), `forwardedFrames` (sent before any cancel), `sampleRate`, `firstAudioMs`, `generationMs`, `discarded`, and `wastedMs` when discarded |
| `translatorReady` | `id`, `loadMs`, `residentBytes` |
| `translation` | `id`, `text`, `firstTokenMs`, `generationMs`, `chunks` (streamed text chunks, not model tokens) |
| `stats` | `id`, `residentBytes`, `activeBytes`, `peakBytes`, `cacheBytes` |
| `pong` | `id` |
| `error` | `message`, and `id` when the error belongs to one request. An empty `id` means the helper could not tell which request failed (a malformed frame), and the client fails every outstanding request. A request error leaves the engine running; a protocol error or model-load failure exits 1 |

## Cancellation (D‑8, finish-and-discard)

After `cancel`, the engine keeps generating until the library finishes but forwards no more audio. The `done` reply carries `discarded: true` and `wastedMs`, the time from the cancel to completion. A cancel that arrives before the generation starts drops the unit at once (`done` with `frames: 0`). The next request starts only after the current one has ended, so the model's streaming decoder is entered once per generation: the engine never breaks out of the library's loop itself. If an engine-side limit trips (generation time, non-finite audio, audio length), forwarding stops, the loop is drained to its end, and an `error` follows. Silence on the user's side comes from the app stopping playback, not from the engine.

## Process boundary

The client spawns the engine under `sandbox-exec` with network, microphone and camera denied and file writes under the home folder denied except `~/Library/Caches` and the temporary folder, so the engine can read the checkpoint and voices but never alter them (`sandbox-exec` is deprecated by Apple; it is the same mechanism Voice uses). Both ends ignore SIGPIPE: a dead peer surfaces as an error on the outstanding request, never as a signal. The client consumes replies through one ordered task and checks `seq` on audio frames, so chunks cannot be reordered or overtaken by `done`. If the engine exits or stops reading, every outstanding request fails with an error and the client refuses further writes.

## Conditionings

Each `prepareVoice` builds a `Qwen3TTSReferenceConditioning` (speaker embedding, reference speech codes, reference text tokens, language) and keeps it under its slot. A `synthesize` passes the slot's conditioning object directly, so switching voices costs nothing beyond the generation itself; `TranslateCheck --engine` measures that as "switch overhead".

## TranslateASR (recognition helper, same framing)

`TranslateASR` is the second product of `Engine/`. It runs apart from the engine so captions never wait behind speech generation (plan §2.3), under the same sandbox, with no arguments; it answers `ready` with `version`, `sampleRate` (16000) and `residentBytes`. Audio payloads are Float32 little-endian mono at 16 kHz, at most ten minutes per request. It hosts up to one of each backend: `nemotron` (Nemotron 3.5 streaming RNN-T, incremental sessions), `qwen3asr` (Qwen3-ASR, a complete clip in, text out, with an optional `context` name list) and `aligner` (Qwen3-ForcedAligner, word timestamps for a known text).

| `type` | Header fields | Payload | Reply |
| --- | --- | --- | --- |
| `load` | `id`, `backend`, `model` (checkpoint directory) | — | `loaded`: `backend`, `sampleRate`, `loadMs`, `residentBytes` |
| `transcribe` | `id`, `backend` (`nemotron` or `qwen3asr`), optional `language` (for Nemotron one of the checkpoint's prompt keys such as `en-US`, `es-ES`, `es-US`, `zh-CN`, or `auto`; any other value is refused rather than silently auto-detected; for Qwen3-ASR a Qwen name or `auto`), optional `context` (≤4,096 bytes, Qwen3-ASR only) | the clip | `transcript`: `backend`, `text`, `ms`, `audioSeconds`, `segments` (`text`, `start`, `end`; dropped when they would not fit the header), `language` when detected |
| `streamStart` | `id`, optional `language`, optional `chunkMs` (80–2000, default 560) | — | `streamReady`: `chunkMs`. At most four open streams; Nemotron only |
| `streamAudio` | `id` of the stream | the next chunk | `partial`: `text` (the whole text so far), `ms` |
| `streamFinish` | `id` of the stream | — | `final`: `text`, `ms`, `segments` |
| `align` | `id`, `text` (≤4,096 bytes), optional `language` (Qwen name, default English) | the clip | `alignment`: `items` (`text`, `start`, `end`), `ms` |
| `stats`, `ping`, `shutdown` | as for the engine | — | `stats`, `pong`, exit |

`load` replaces the backend's model (one helper holds one model per backend, so the comparison launches one helper per candidate); `transcribe`, `streamAudio`, `streamFinish` and `align` run one at a time in arrival order, while `stats` and `shutdown` are answered by the reader thread at once. Errors use the engine's `error` shape; a reply too large to frame becomes an `error` for its request. The client gives every request a deadline (four times the audio length, at least a minute), so a stalled model fails one row rather than the run.

**Preparing a checkpoint once.** The runtime generates `tokenizer.json` from `vocab.json` and `merges.txt` the first time it loads a checkpoint that ships without one (Qwen3-ASR, the ForcedAligner, the 0.6B and bf16 Base TTS checkpoints), and the sandbox makes the model folder read-only. `TranslateASR --prepare <backend> <dir>` and `TranslateEngine --model <dir> --prepare` load a checkpoint once outside the sandbox so that file exists; `TranslateCheck --prepare-model <backend> …` runs them and `docs/PROVENANCE.md` records the generated files.
