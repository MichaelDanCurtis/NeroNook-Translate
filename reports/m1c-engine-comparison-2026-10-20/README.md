# Milestone 1c · engine comparison harness

**October 20, 2026 · local only · reference Mac: Mac16,5 (16‑inch MacBook Pro), Apple M4 Max, 128 GB, macOS 27.0.1, Swift 6.4, plugged in**

This receipt covers the harness and the approved acquisitions. **Nothing is scored yet**: every number below comes from the three synthetic `say` clips under `Fixtures/Voices` and only shows that each path runs. D‑4 and D‑5 are decided from the recorded corpus (plan §6.1), which waits on the owner (items 1–5, 10 and 11 of `docs/M1C-PLAN.md`).

## What exists now

- `Engine/` builds a second helper, **`TranslateASR`** (Nemotron 3.5 streaming sessions, Qwen3‑ASR phrase mode with an optional `context` name list, Qwen3‑ForcedAligner), and **`TranslateEngine`** gained `loadTranslator`/`translate` for a Qwen text model next to the TTS model. Both share `EngineProtocol` (the frame codec) and the client's sandbox. `docs/PROTOCOL.md` documents both.
- `Sources/TranslateEngineClient`: one generic `HelperClient` (launch, ordered replies, subscriptions, fail-all on exit) under `EngineClient` and the new `ASRClient`.
- `Sources/TranslateCompare`: corpus loader (`raw/` recordings, `codec/` Opus copies sharing the same gold text and checks), normalization and token error rates (words and single digits; characters for Mandarin) with per‑category checks (names, numbers, dates, negations, corrections) matched inside their own sentence, candidate adapters (Apple SpeechAnalyzer and Translation in‑process; the helpers; Hy‑MT2 through `scripts/hymt2-server.py`), **paced runs** (energy‑gated phrases fed at wall‑clock pace; final delay from the nominal phrase end, first partial, and the cost of re‑running a phrase‑mode engine every second), a **load generator** (continuous Qwen TTS in the engine while every pass repeats), the **listening‑set writer** (blinded clip ids, `key.json` apart from the sheet, one slot preparation per target language, a pass while Nemotron streams), and the receipts (`compare-receipt.json`, `compare-summary.md`, `translation-review.md`, `tts-summary.md`, `listening-sheet.md`).
- `TranslateCheck --compare`, `--listening-set`, `--prepare-model`, `--install-speech-locale`; `scripts/corpus-codec.sh` (Opus 24 kb/s VoIP copy); `scripts/corpus-gold.py` and `scripts/corpus-checks/{en,es}.json`; `Fixtures/Corpus/scripts/{en,es,zh}.md` and `gold/`.
- Tests: 20 new (`Tests/TranslateCompareTests` and `HelperClientTests`: normalization incl. 24 word/digit pairs in three languages, error rates, sentence‑scoped checks, phrase splitting incl. trailing silence and quiet speech, corpus pairing, SDK stamp, receipt rendering, sheet blinding, load generator against the fake engine, oversized frames, deadlines, nested numbers).

## Owner approvals used

| Approval | What happened | Receipt |
| --- | --- | --- |
| 6 · pinned downloads | Qwen3‑ASR 1.7B 8‑bit (2.47 GB), Qwen3‑ASR 0.6B 4‑bit (0.71 GB), Qwen3‑ForcedAligner 0.6B 4‑bit (0.98 GB), Qwen3‑TTS 0.6B Base 8‑bit (1.99 GB), Qwen3.5‑2B 4‑bit (1.75 GB); LFS files verified against Hub SHA‑256 | `download-*.json`, recipes in `Resources/Models/` |
| 7 · Apple speech assets | Mandarin (`zh-CN`) installed. **Spanish not downloaded**: the variety (item 1) is still open | — |
| 8 · imports | Nemotron 3.5 0.6B 8‑bit from Voice's model folder (0.76 GB); Qwen3‑TTS 1.7B Base bf16 from the Hugging Face cache (4.54 GB); APFS clones, every file hashed | `import-nemotron.json`, `import-qwen-base-bf16.json` |
| 9 · Hy‑MT2 | Run read‑only from `NeroNook-Voice/build/interpreter-models/translator` through `build/interpreter-venv/bin/python`; nothing written there | `smoke-fixtures/hymt2-compare-receipt.json` |
| one‑time prepare | The runtime generates `tokenizer.json` for checkpoints that ship without one; done once outside the sandbox for Qwen3‑ASR 0.6B and 1.7B, the aligner, and the 0.6B and bf16 TTS checkpoints | `prepared-tokenizers.json` |

Translate's model folder now holds 15 GB. Nothing else outside the workspace was touched; no driver, no capture, no publication.

## Smoke runs on the fixtures (plumbing only)

Debug `TranslateCheck`, release helpers under the sandbox, one `TranslateASR` per recognition candidate, warm models (every candidate is warmed once before the receipt rows). Full tables with the models, settings and build stamp: `smoke-fixtures/compare-summary.md`; every row as it was produced: `rows.jsonl` in the run folder.

| Path | Result on the three clips (8–9 s each) |
| --- | --- |
| Nemotron, whole clip | WER 0% (en, es); 90–140 ms per clip; 0.87 GB resident in its own helper |
| Qwen3‑ASR 0.6B 4‑bit, whole clip, with and without `context` | WER 0%; 130–200 ms per clip; 0.81 GB |
| Qwen3‑ASR 1.7B 8‑bit, whole clip, with and without `context` | WER 0%; 280–410 ms per clip; 2.5 GB |
| Apple SpeechTranscriber (en‑US) | WER 0%; 140–240 ms per clip. **es‑ES fails**: assets not installed (item 1) |
| Paced, Nemotron (560 ms chunks) | final text 33–72 ms after the phrase end; first partial ≈1.2 s after the phrase start |
| Paced, Qwen3‑ASR 0.6B | final text 180–310 ms after the phrase end; re‑running the growing phrase every second costs 110–150 ms per run |
| Paced, Qwen3‑ASR 1.7B | final text 280–440 ms after the phrase end; prefix re‑runs 190–280 ms (max 430 ms), still under the one‑second cadence |
| Paced, Apple (320 ms buffers, volatile results, analyzer started before the clock) | final text 80–115 ms after the phrase end; **first volatile result ≈4.2 s** after the phrase start, so start‑up was not the cause; check reporting options before scoring |
| Apple Translation en→es, es→en | 435–1,050 ms per line |
| Qwen3.5‑2B 4‑bit in the engine, with and without context | 155–205 ms per line alone, first token 45–60 ms |
| Hy‑MT2 1.8B 4‑bit (sandboxed, Voice's environment read‑only) | 200–320 ms per line, first token 70–125 ms, loaded in 1.1 s |
| Under load (Qwen TTS synthesizing continuously: RTF 0.30–0.31, first audio ≈155 ms, 52 syntheses during the paced pass) | recognition and paced delays unchanged within noise for every recognizer; Apple and Hy‑MT2 translation +10–20%; **Qwen translation 1.5–2.1 s per line**, because the engine runs one request at a time and a translation waits behind the synthesis unit in progress |
| Listening set (0.6B 8‑bit and 1.7B bf16 run; three fixture voices × en/es × two sentences × 0.32 and 0.16 s intervals, plus a pass while Nemotron streams) | 60 blinded clips, sheet and `tts-summary.md` written; key under `private/`. 0.6B 8‑bit: first audio 104 ms at 0.32 s, 70 ms at 0.16 s, RTF 0.26–0.29, unchanged under recognition, 2.0 GB resident. **1.7B bf16: first audio 550 ms, RTF 1.7** (slower than real time; 4.5 GB resident) against 0.29 for the 1.7B 8‑bit measured in M1b: worth a look at the runtime path before bf16 is judged on sound alone |

## Resources per pass (fixture run with Nemotron, Qwen3‑ASR 0.6B, Apple, Apple Translation, Qwen3.5‑2B and Hy‑MT2; `smoke-fixtures/compare-summary-with-resources.md`)

Measured without privileges: CPU time and physical footprint per process from the kernel, MLX counters from the helpers, GPU device utilization from the graphics driver polled every 250 ms. The GPU figure covers the whole GPU during the pass. Apple speech and Apple Translation run in system services, so their memory and CPU are not in any process row; their GPU share is inside the GPU figure.

| Process | Footprint (peak) | CPU during its busiest pass | MLX active (peak) |
| --- | --- | --- | --- |
| Engine: Qwen3‑TTS 1.7B 8‑bit + Qwen3.5‑2B 4‑bit text | 4.3–4.7 GB (5.1 GB) | 118–128% of one core while synthesizing continuously; 17% translating alone | 4.0–4.4 GB (4.8 GB) |
| TranslateASR, Nemotron 3.5 0.6B 8‑bit | 0.84–0.97 GB (1.29 GB) | 13% during whole‑clip recognition; 1% paced | 0.76 GB (0.90 GB) |
| TranslateASR, Qwen3‑ASR 0.6B 4‑bit | 0.76–0.94 GB (1.54 GB) | 57% during whole‑clip recognition; 4–5% paced | 0.68 GB (1.44 GB) |
| Hy‑MT2 server (sandboxed Python) | 1.4–1.5 GB (2.4 GB) | 10–20% translating | – |
| TranslateCheck itself (Apple candidates in‑process) | 10 MB | 0–3% | – |

| Pass | GPU device utilization mean / max |
| --- | --- |
| paced, alone (Nemotron, Qwen prefix re‑runs, Apple) | 42% / 100% |
| paced, Qwen TTS running | 79% / 94% |
| recognition, alone (whole clips; 1.7 s) | 72% / 85% |
| recognition, Qwen TTS running | 90% / 100% |
| translation, alone | 57% / 97% |
| translation, Qwen TTS running | 78% / 98% |

The listening set samples the same way per variant: the 0.6B 8‑bit TTS engine ran at 2.4 GB footprint (peak 2.8 GB), about 1.3 cores and 61% mean GPU while rendering clips, and 63% with Nemotron streaming beside it.

Energy and thermal behaviour are not measured; they need `powermetrics` (root) and are scheduled for Milestone 3.

## Independent review (static, same day) and what it changed

A separate reviewer read the uncommitted work without running it. Everything it rated a bug is fixed and covered by a test or a rerun; the rest is fixed where cheap or recorded here.

| Finding | Fix |
| --- | --- |
| Both Qwen3‑ASR sizes loaded into one helper, which holds one model per backend, so the "0.6B" rows had run on the 1.7B model (the earlier helper receipt showed identical timings; it is withdrawn) | One `TranslateASR` per recognition candidate, each with its own log; memory is now per candidate; the fixture smoke was rerun |
| A real recording (minutes) exceeded the 4 MiB frame, and the client resumed a continuation twice on that error (a fatal trap) | 64 MiB frames on both codecs; encode before registering a request; no double resume; per‑request deadlines (four times the audio length, at least a minute); tests with the fake engine |
| Number folding added adjacent numbers ("ten thirty" → 40), dropped %, $ and minus, and let a form elsewhere in the transcript satisfy a sentence check | Grammar‑aware folding, Chinese numerals, then **one token per digit** so "10:30", "1030" and "ten thirty" agree; checks match inside the stretch aligned with their sentence; 24 scoring cases in the tests |
| Nemotron silently auto‑detected for "zh" (no such prompt key) and took `es` regardless of the chosen variety | Corpus codes map to the checkpoint's prompt keys (`en-US`, the `--spanish-locale`, `zh-CN`); the helper refuses unknown keys instead of falling back |
| Apple's paced delays included analyzer start‑up; a thrown Nemotron session was never closed; the Hy‑MT2 client could be killed by SIGPIPE or desynchronized, ran unsandboxed and wrote bytecode into Voice's environment | Analyzer prepared and started before the clock; sessions closed on every exit path; Hy‑MT2 under the helpers' sandbox with `-I -B`, replies matched by id, deadlines, a log |
| Receipts were written only at the end; a load generator that gave up still produced "under load" rows; the listening set kept the blinding key next to the sheet and wrote clips in variant order; the codec script skipped `.m4a`; stereo recordings would lose a channel | `rows.jsonl` grows as rows complete; a pass whose load failed is marked invalid; key and receipt under `private/`, one modification date for all clips, clips and keys git‑ignored, consent text extended; all loader formats converted; stereo downmixed |
| Receipts lacked provenance (models, settings, git head, SDK stamp); "+context" and the glossary use the scripted names (an oracle list) without saying so | Recorded in every receipt, with a note |

Left as recorded risks: the harness never calls the aligner (not needed for D‑4); a translation of more than 2,048 bytes fails for Qwen and Hy‑MT2 (natural gold is one sentence per line); `swift test` timing assertions in the engine integration test fail when other helpers share the GPU (run it alone). After the review, per‑pass resource sampling was added (above), with three more tests; 89 tests pass.

## Findings that changed the design or the code

1. **Checkpoints without `tokenizer.json`.** The pinned runtime writes one into the model folder on first load; the sandbox forbids that, so `--prepare-model` loads each such checkpoint once outside the sandbox and the generated file is recorded. Runtime folders stay read‑only.
2. **Apple Translation and the SDK stamp.** A SwiftPM 6.4 executable is stamped with its deployment target as the SDK version (the Swift Build link step never gets `-target-sdk-version`), and the Translation framework then answers `supported` and `notInstalled` for installed packs. Verified by restamping binaries with `vtool` in both directions. `Package.swift` now passes `-platform_version macos 26.0 27.0` for `TranslateCheck`, `BuildStamp` reports the stamp in the error, and plan §9 lists it as a release check for the packaged app.
3. **Translation inside the TTS engine waits behind synthesis.** Measured above. If D‑5 picks the Qwen text model, it belongs in its own process (like recognition) or the engine must interleave; recorded as input to D‑5, not decided here.
4. **Qwen3.5‑2B is a multimodal checkpoint**; the pinned runtime loads its text model alone (the vision tower is dropped). Fine for measurement; the shipped model choice follows the comparison.
5. The engine wants Qwen language *names* for `prepareVoice`, and a slot is prepared for the language it will speak; the listening set prepares each voice per target language and records those preparation times apart from the clip numbers.
6. **The bf16 Base checkpoint runs far slower than 8‑bit** in the pinned runtime (RTF 1.7 against 0.29). Bandwidth alone would predict about twice the 8‑bit time, so this looks like a runtime path rather than the weights; it is recorded for the TTS stage of §6.1 and does not block anything.

## Not verified, and what is next

- No recorded audio exists yet, so no WER, delay or meaning number here means anything beyond "the path runs". Pass bars (item 10) are unconfirmed; the Mandarin checks file needs a native speaker; the Opus copy script has only run on fixtures.
- Apple's partial latency may depend on reporting options (`fastResults`); try it on the real corpus before scoring, and record whichever setting the live design would use.
- The battery pass (D‑11) and the 1.7B‑8bit/bf16 listening comparison with the owner's own references wait for the corpus and item 11.
- Next, in order: item 1 → Spanish Apple asset; recordings (2–5) → `scripts/corpus-codec.sh`, `scripts/corpus-gold.py`, corrections; `--compare --corpus Fixtures/Corpus --paced --load` for EN↔ES with every candidate; the listening set with the owner's references; receipts here; D‑4/D‑5 in plan §8.

## Files

`download-*.json`, `import-*.json`, `prepared-tokenizers.json`, `smoke-fixtures/` (the final fixture run with every candidate, paced and under load: receipt, summary, review sheet; the summary of the later run with resource sampling; the TTS summary of the two‑variant listening run), this README. Helper logs, clips and blinding keys are not kept (`.gitignore`).
