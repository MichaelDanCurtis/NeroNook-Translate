# Milestone 1b · TranslateEngine: one model, three voices, finish-and-discard

**October 20, 2026 · local only · reference Mac: Mac16,5 (16‑inch MacBook Pro), Apple M4 Max, 128 GB, macOS 27.0.1, Swift 6.4**

## What exists now

- `Engine/`: a separate package producing `TranslateEngine`, pinned to the same `mlx-audio-swift` revision as Voice (`01dec7c9…`) with every transitive pin matched (`Engine/Package.resolved` seeded from Voice's). One resident Qwen3‑TTS 1.7B Base 8‑bit model; one prepared `Qwen3TTSReferenceConditioning` per voice slot (`local`, `remote`, `generic`); one generation at a time; framed protocol on a private copy of stdout; `cancel` is finish-and-discard (D‑8).
- `Sources/TranslateEngineClient`: the app-side client. Spawns the engine under `sandbox-exec` (no network, microphone or camera), decodes any reference file to 24 kHz mono Float32, streams synthesis events, cancels out of band.
- `TranslateCheck --engine …`: the receipts below; `scripts/import-model.py`: hash-verified APFS-clone import of a pinned checkpoint; `scripts/engine-probe.py`: a dependency-free protocol driver for debugging.
- Three synthetic reference clips under `Fixtures/Voices` (macOS `say`, 7.9–8.6 s) with exact transcripts. They measure the engine; they say nothing about voice quality.

## Owner approvals used

- Import of the Qwen Base checkpoint from Voice's model folder into Translate storage (12 files, 2.9 GB as an APFS clone, every size and SHA‑256 verified; `model-import.json`).
- No other action outside the workspace. Nothing downloaded except the pinned open-source Swift packages into `Engine/.build`.

## Receipts (`engine-receipt.json`, `engine-summary.md`)

Debug `TranslateCheck`, release `TranslateEngine` under the client's sandbox, warm disk cache, nothing else running on the GPU. This is the run after the review fixes; the pre-review run gave the same figures within a few milliseconds.

| Measure | Result |
| --- | --- |
| Spawn to `ready` (warm disk cache) | 489 ms (model load 466 ms). The first-ever load in a fresh process measured 868 ms; a cold-cache start was not measured |
| Prepare a voice (≈8 s reference) | 50 / 35 / 35 ms for generic / local / remote |
| First audio, warm, per slot | 146–150 ms on every slot |
| Real-time factor | 0.29–0.30 (about 3.4× faster than real time) |
| **Switch overhead** (alternating slots − same slot, mean first audio, 12 vs 9 runs) | **−0.4 ms**, i.e. none: the generation path keeps no reference-keyed state, so a different conditioning object is just a different pointer |
| **Discard-to-idle**, overlapped like the app (cancel at first chunk, other lane queued at once, ≈6.5 s utterance) | generation ran 1,729 ms, 1,583 ms of it after the cancel; **0 frames arrived after the cancel**; the other lane's first audio came 1,733 ms after the cancel (its own first audio 150 ms) |
| **Stress: 100× overlapped stop, then start the other lane** | **0 errors**, 388.0 s total; max wasted 2,575 ms; other lane's first audio after cancel mean 1,932 ms, max 2,729 ms; **audio after cancel in 0 of 100 rounds** |
| Memory after all of it | resident 3,083 MB; MLX active 3,063 MB, peak 3,939 MB, cache 128 MB |

Also verified by the direct protocol probe: cross-lingual synthesis works in both directions with these references (English reference → Spanish text, Spanish reference → English text); the probe is a timing and plumbing check, not a listening test.

**Tests:** `swift test` runs 66 tests with 0 failures: 55 in `TranslateCoreTests`, 10 in `TranslateEngineClientTests` (four frame-codec tests including number-versus-boolean typing, five fake-engine routing tests, and one integration test that launches the real engine under the client's sandbox, rejects an unprepared slot, prepares two voices, synthesizes in both language directions with matching frame counts, cancels mid-generation and recovers on the same slot, drops a cancel-before-start, and checks the engine log for reference-cache aliasing; about 6 s), and 1 manifest test. The integration test skips itself when the engine binary or the imported checkpoint is absent.

## Findings while building

- **Resolver pins.** `swift package resolve` picked `mlx-swift 0.32.3` because `mlx-audio-swift` declares a range; Voice's measurements are on 0.31.6. Seeding `Engine/Package.resolved` from Voice's pins fixed it. An interrupted resolve printed a trait error that did not recur.
- **Identity-keyed reference cache (library).** `Qwen3TTS` caches the last reference context by the `MLXArray`'s object identity. A freed array's address was reused by the next voice, so the second voice silently got the first voice's context ("Returning cached context" in the engine log). The engine now keeps every slot's reference array alive, which makes identities unique for the process. This is worth an upstream note.
- **`stats` without an id.** The engine answered `stats` without echoing the request id, so the client waited forever at the end of the run. Fixed; `docs/PROTOCOL.md` updated.
- Voice's `patch-mlx-audio.py` touches only Nemo alignment, so the engine needs no patch.

## Independent review and what changed

A separate reviewer read the code against the plan and the library. Its findings and the fixes made before the receipts above were re-run:

| Severity | Finding | Fix |
| --- | --- | --- |
| High | Replies were delivered by one task per frame, so `done` could overtake trailing audio and chunks could reorder | One ordered consumer task; audio `seq` is checked and a gap fails the stream |
| High | Neither side ignored SIGPIPE, so a dead peer would kill the app or the engine by signal | `F_SETNOSIGPIPE` on both pipe ends; a write to a dead engine fails every outstanding request with an error |
| High | An engine-side limit threw out of the library's loop, leaving the cancelled library task to reset decoder state asynchronously while the next request could start | Limits now stop forwarding and drain the loop to its end; the error follows afterwards |
| Medium | A cancel arriving before the generation started still ran the whole generation; stray cancels grew an unbounded table | Cancel-before-start replies `done` at once; only ids the reader has seen are recorded |
| Medium | A launch that timed out or failed left the 3 GB helper running | Terminate on every launch failure, in `deinit`, and on a lingering shutdown |
| Medium | `(allow default)` let the engine write anywhere, unlike the plan's claim | Writes under the home folder are denied except caches; the integration test passes under it |
| Low | Client-supplied `maxTokens` unclamped; unknown `language` silently accepted; reference decoding blocked the actor; dead reply-routing branch; benchmark constants presented as measurements; "cold start" mislabelled | All fixed; the receipts now count frames after cancel and label the warm cache |

Found while testing the fixes: JSON `0` and `1` in reply headers were read as booleans (an `NSNumber` bridges to `Bool`), which the new `seq` check exposed at once; the reader now decides by the number's real type, with a codec test.

Added tests: a fake engine (`Tests/TranslateEngineClientTests/Fixtures/fake-engine.py`) exercises the client without a model: a 50-frame burst arrives complete and in order before `done` (five times), cancel is reflected, a request error fails only its stream, engine death fails outstanding work without a signal, and a launch timeout terminates the helper rather than leaking it. The integration test now covers an unprepared slot, both language directions, cancel and recovery on the same slot, cancel-before-start, and asserts the library never reports a cached reference context.

Not changed, and noted: the stress rounds check audio for presence, duration and real-time factor, not by listening; cold-cache start is still unmeasured; `sandbox-exec` is deprecated by Apple.

## What the numbers mean for the plan

- D‑8 (finish-and-discard) is workable: with sentence-sized units (§2.3, ≤300 bytes) the wasted generation after a Stop or Mute should be well under the 1.6–2.4 s seen here on ~7 s utterances. The library patch stays a fallback, not a need.
- The three-conditioning design holds: voice switching is free, preparation is tens of milliseconds, and one resident model serves both directions.
- First audio of ~150 ms leaves most of the plan's ≤0.3 s synthesis budget unused.

## Not done or not verified

- No listening evaluation, identity, accent or pronunciation judgement; the references are synthetic voices. That is milestone 1d with real recordings and consent.
- Cold start with a cold disk cache was not measured separately.
- No measurement with recognition or translation running at the same time (§6.1 "under load").
- The engine's behaviour on a mid-generation library error (model-wide decoder state) is handled by reporting the error and continuing; whether a restart is safer is for the review.
- Nothing is installed, captured or published; the app process and audio routing are later milestones.
