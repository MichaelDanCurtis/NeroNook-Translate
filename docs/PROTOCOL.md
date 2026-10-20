# Engine protocol (version 1)

`TranslateEngine` is a separate process built from `Engine/`. The app (or `TranslateCheck`) spawns it under `sandbox-exec` with network, microphone and camera denied, passes `--model <checkpoint directory>`, writes requests to its stdin and reads replies from its stdout. The engine moves its real stdout to a private descriptor before loading anything and points stdout at stderr, because the inference library prints diagnostics.

## Framing

```
u32 big-endian header length · JSON header · u32 big-endian payload length · payload
```

Headers are flat JSON objects with a `type` and, for requests and their replies, an `id`. Headers are at most 64 KiB; payloads at most 4 MiB. Audio payloads are raw Float32 little-endian mono samples. The codec is `Engine/Sources/TranslateEngine/Frames.swift` and its copy `Sources/TranslateEngineClient/EngineFrames.swift`; keep them identical.

## Requests (client → engine)

| `type` | Header fields | Payload | Reply |
| --- | --- | --- | --- |
| `prepareVoice` | `id`, `slot` (`local`/`remote`/`generic`), `transcript` (the exact words in the reference), `language` (Qwen language name for the slot's target), `sampleRate` (must equal the engine's) | reference audio, 3–30 s | `voiceReady` |
| `synthesize` | `id`, `slot`, `text` (≤2,048 bytes), optional `streamingInterval` (0.16–1 s, default 0.32), optional `maxTokens` (clamped to 16–1800; default 1800, about 144 s of audio) | — | `audio`… then `done`, or `error` |
| `cancel` | `id` of a synthesis the engine has already seen | — | none; handled at once, out of band. A cancel for an unknown id is ignored |
| `stats` | `id` | — | `stats` |
| `ping` | `id` | — | `pong` |
| `shutdown` | — | — | the engine finishes the requests already queued, then exits 0 |

The engine runs one `prepareVoice` or `synthesize` at a time, in arrival order. `cancel`, `stats` and `shutdown` are handled by the reader thread immediately. `language` must be one of Qwen's ten names (English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, Italian).

## Replies (engine → client)

| `type` | Fields |
| --- | --- |
| `ready` | `version`, `sampleRate` (24000), `loadMs`, `residentBytes` — sent once after the model loads |
| `voiceReady` | `id`, `slot`, `seconds`, `prepareMs`, `language`, `residentBytes` |
| `audio` | `id`, `seq`, `sampleRate`; payload is one streamed chunk |
| `done` | `id`, `frames` (all generated), `forwardedFrames` (sent before any cancel), `sampleRate`, `firstAudioMs`, `generationMs`, `discarded`, and `wastedMs` when discarded |
| `stats` | `id`, `residentBytes`, `activeBytes`, `peakBytes`, `cacheBytes` |
| `pong` | `id` |
| `error` | `message`, and `id` when the error belongs to one request (an empty `id` means the request was malformed and the client ignores the reply). A request error leaves the engine running; a protocol error or model-load failure exits 1 |

## Cancellation (D‑8, finish-and-discard)

After `cancel`, the engine keeps generating until the library finishes but forwards no more audio. The `done` reply carries `discarded: true` and `wastedMs`, the time from the cancel to completion. A cancel that arrives before the generation starts drops the unit at once (`done` with `frames: 0`). The next request starts only after the current one has ended, so the model's streaming decoder is entered once per generation: the engine never breaks out of the library's loop itself. If an engine-side limit trips (generation time, non-finite audio, audio length), forwarding stops, the loop is drained to its end, and an `error` follows. Silence on the user's side comes from the app stopping playback, not from the engine.

## Process boundary

The client spawns the engine under `sandbox-exec` with network, microphone and camera denied and file writes under the home folder denied except `~/Library/Caches` and the temporary folder, so the engine can read the checkpoint and voices but never alter them (`sandbox-exec` is deprecated by Apple; it is the same mechanism Voice uses). Both ends ignore SIGPIPE: a dead peer surfaces as an error on the outstanding request, never as a signal. The client consumes replies through one ordered task and checks `seq` on audio frames, so chunks cannot be reordered or overtaken by `done`. If the engine exits or stops reading, every outstanding request fails with an error and the client refuses further writes.

## Conditionings

Each `prepareVoice` builds a `Qwen3TTSReferenceConditioning` (speaker embedding, reference speech codes, reference text tokens, language) and keeps it under its slot. A `synthesize` passes the slot's conditioning object directly, so switching voices costs nothing beyond the generation itself; `TranslateCheck --engine` measures that as "switch overhead".
