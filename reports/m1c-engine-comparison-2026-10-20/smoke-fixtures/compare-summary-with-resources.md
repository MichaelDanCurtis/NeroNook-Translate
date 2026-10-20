# Engine comparison · fixtures (synthetic voices; plumbing check only)

2026-10-20T22:58:37Z · Mac16,5

Build: gitHead 543dc50 (plus uncommitted changes unless the receipt says otherwise) · sdkStamp 27.0

Settings: appleLocales = en-US, es-ES, zh-CN; applePaced = reporting: volatileResults; one analyzer per phrase, prepared and started before the clock; 320 ms buffers; chunkMs = 560; contextWindow = 2; load = true; paced = true; prefixEvery = 1.0; spanishLocale = es-ES

Models:
- engine tts: `Qwen3-TTS-12Hz-1.7B-Base-8bit-e7dd0585652209fa0d7783659aad4e8a324de11c`
- hy-mt2-1.8b-4bit: `/Volumes/Main External/Development/NeroNook-Voice/build/interpreter-models/translator`
- nemotron: `nemotron-3.5-asr-streaming-0.6b-8bit-7279359e4481b5e9e185a318bd618e429c6d86cd`
- qwen3.5-2b: `Qwen3.5-2B-4bit-674aaa7240b91e8012fcad5d791b7dfe5ba90207`
- qwen3asr-0.6b: `Qwen3-ASR-0.6B-4bit-313d850181767edf09f00a9c289becca70e58cd0`

## Recognition (whole recording, phrase mode)

| Recognizer | Item | Load | Error rate | Checks | Names | Numbers | Dates | Negation | Corrections | Time / audio | RTF |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nemotron | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 109 ms / 8.37 s | 0.013 |
| nemotron | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 102 ms / 7.85 s | 0.013 |
| nemotron | fixture/remote-es | – | 0.0% (0/30) | 0/0 | – | – | – | – | – | 118 ms / 8.57 s | 0.014 |
| qwen3asr-0.6b | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 173 ms / 8.37 s | 0.021 |
| qwen3asr-0.6b | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 136 ms / 7.85 s | 0.017 |
| qwen3asr-0.6b | fixture/remote-es | – | 3.3% (1/30) | 0/0 | – | – | – | – | – | 209 ms / 8.57 s | 0.024 |
| qwen3asr-0.6b+context | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 164 ms / 8.37 s | 0.02 |
| qwen3asr-0.6b+context | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 138 ms / 7.85 s | 0.018 |
| qwen3asr-0.6b+context | fixture/remote-es | – | 3.3% (1/30) | 0/0 | – | – | – | – | – | 200 ms / 8.57 s | 0.023 |
| apple-speech | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 144 ms / 8.37 s | 0.017 |
| apple-speech | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 144 ms / 7.85 s | 0.018 |
| apple-speech | fixture/remote-es | – | failed: Apple speech failed for es-ES (asset status supported): Error Domain=SFSpeechErrorDomain Code=3 "Audio format is not supported" UserInfo={NSLocalizedDescription=Audio format is not supported} | | | | | | | | |
| nemotron | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 154 ms / 8.37 s | 0.018 |
| nemotron | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 113 ms / 7.85 s | 0.014 |
| nemotron | fixture/remote-es | TTS | 0.0% (0/30) | 0/0 | – | – | – | – | – | 137 ms / 8.57 s | 0.016 |
| qwen3asr-0.6b | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 373 ms / 8.37 s | 0.045 |
| qwen3asr-0.6b | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 167 ms / 7.85 s | 0.021 |
| qwen3asr-0.6b | fixture/remote-es | TTS | 3.3% (1/30) | 0/0 | – | – | – | – | – | 256 ms / 8.57 s | 0.03 |
| qwen3asr-0.6b+context | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 203 ms / 8.37 s | 0.024 |
| qwen3asr-0.6b+context | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 168 ms / 7.85 s | 0.021 |
| qwen3asr-0.6b+context | fixture/remote-es | TTS | 3.3% (1/30) | 0/0 | – | – | – | – | – | 245 ms / 8.57 s | 0.029 |
| apple-speech | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 163 ms / 8.37 s | 0.019 |
| apple-speech | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 164 ms / 7.85 s | 0.021 |
| apple-speech | fixture/remote-es | TTS | failed: Apple speech failed for es-ES (asset status supported): Error Domain=SFSpeechErrorDomain Code=3 "Audio format is not supported" UserInfo={NSLocalizedDescription=Audio format is not supported} | | | | | | | | |

## Paced (phrases fed in real time)

| Recognizer | Item | Load | Phrases | Coverage | Error rate | Checks | Final delay mean / p90 / max ms | First partial ms | Prefix re-run mean / max ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nemotron | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 72 / 72 / 72 | 1194 | – |
| nemotron | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 62 / 62 / 62 | 1171 | – |
| nemotron | fixture/remote-es | – | 1 | 99% | 0.0% | 0/0 | 32 / 32 / 32 | 1189 | – |
| qwen3asr-0.6b | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 204 / 204 / 204 | 1145 | 116 / 164 |
| qwen3asr-0.6b | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 164 / 164 / 164 | 1141 | 116 / 155 |
| qwen3asr-0.6b | fixture/remote-es | – | 1 | 99% | 0.0% | 0/0 | 242 / 242 / 242 | 1102 | 158 / 258 |
| apple-speech | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 86 / 86 / 86 | 4196 | – |
| apple-speech | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 98 / 98 / 98 | 4199 | – |
| apple-speech | fixture/remote-es | – | failed: phrase 1: Apple speech offers no audio format for es-ES. | | | | | | |
| nemotron | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 43 / 43 / 43 | 1175 | – |
| nemotron | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 59 / 59 / 59 | 1156 | – |
| nemotron | fixture/remote-es | TTS | 1 | 99% | 0.0% | 0/0 | 42 / 42 / 42 | 1175 | – |
| qwen3asr-0.6b | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 285 / 285 / 285 | 1171 | 118 / 176 |
| qwen3asr-0.6b | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 190 / 190 / 190 | 1091 | 111 / 158 |
| qwen3asr-0.6b | fixture/remote-es | TTS | 1 | 99% | 0.0% | 0/0 | 257 / 257 / 257 | 1155 | 163 / 248 |
| apple-speech | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 74 / 74 / 74 | 4176 | – |
| apple-speech | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 124 / 124 / 124 | 4182 | – |
| apple-speech | fixture/remote-es | TTS | failed: phrase 1: Apple speech offers no audio format for es-ES. | | | | | | |

## Translation (timing; meaning is rated from translation-review.md)

| Translator | Item | Pair | Load | Lines ok | Mean ms | Mean first token ms |
| --- | --- | --- | --- | --- | --- | --- |
| apple-translation | fixture/generic-en | en→es | – | 1/1 | 1061 | – |
| apple-translation | fixture/generic-en | en→es | TTS | 1/1 | 1230 | – |
| apple-translation | fixture/local-en | en→es | – | 1/1 | 451 | – |
| apple-translation | fixture/local-en | en→es | TTS | 1/1 | 543 | – |
| apple-translation | fixture/remote-es | es→en | – | 1/1 | 594 | – |
| apple-translation | fixture/remote-es | es→en | TTS | 1/1 | 668 | – |
| hy-mt2-1.8b-4bit | fixture/generic-en | en→es | – | 1/1 | 316 | 115 |
| hy-mt2-1.8b-4bit | fixture/generic-en | en→es | TTS | 1/1 | 370 | 99 |
| hy-mt2-1.8b-4bit | fixture/local-en | en→es | – | 1/1 | 233 | 72 |
| hy-mt2-1.8b-4bit | fixture/local-en | en→es | TTS | 1/1 | 321 | 105 |
| hy-mt2-1.8b-4bit | fixture/remote-es | es→en | – | 1/1 | 217 | 88 |
| hy-mt2-1.8b-4bit | fixture/remote-es | es→en | TTS | 1/1 | 291 | 113 |
| qwen3.5-2b-4bit | fixture/generic-en | en→es | – | 1/1 | 212 | 64 |
| qwen3.5-2b-4bit | fixture/generic-en | en→es | TTS | 1/1 | 1498 | 49 |
| qwen3.5-2b-4bit | fixture/local-en | en→es | – | 1/1 | 163 | 45 |
| qwen3.5-2b-4bit | fixture/local-en | en→es | TTS | 1/1 | 2055 | 53 |
| qwen3.5-2b-4bit | fixture/remote-es | es→en | – | 1/1 | 179 | 54 |
| qwen3.5-2b-4bit | fixture/remote-es | es→en | TTS | 1/1 | 2038 | 60 |

## Qwen TTS during the under-load passes

| Pass | Syntheses | Audio s | Generation RTF | Mean first audio ms | Errors | Valid |
| --- | --- | --- | --- | --- | --- | --- |
| paced | 37 | 219.7 | 0.305 | 151 | 0 | yes |
| recognition | 1 | 6.2 | 0.366 | 178 | 0 | yes |
| translation | 5 | 29.7 | 0.333 | 162 | 0 | yes |

## Resources per pass

| Pass | Wall s | GPU device % mean / max | Process | CPU s | CPU % | Footprint MB | Peak footprint MB | MLX active / peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| paced | 65.6 | 42% / 100% (251 samples) | TranslateCheck (Apple in-process) | 0.27 | 0 | 10.3 | 15.3 | – |
| paced | 65.6 | 42% / 100% (251 samples) | asr-nemotron | 0.9 | 1 | 840.3 | 1289.7 | 760.0 / 895.7 |
| paced | 65.6 | 42% / 100% (251 samples) | asr-qwen3asr-0.6b | 2.92 | 4 | 758.4 | 1538.4 | 680.5 / 1442.8 |
| paced | 65.6 | 42% / 100% (251 samples) | hy-mt2-1.8b-4bit | 0.0 | 0 | 1365.8 | 2397.6 | – |
| paced | 65.6 | 42% / 100% (251 samples) | engine (TTS + Qwen text) | 0.0 | 0 | 4338.5 | 4928.1 | 4039.8 / 4834.4 |
| paced under load | 65.8 | 79% / 94% (252 samples) | TranslateCheck (Apple in-process) | 0.31 | 0 | 9.9 | 15.3 | – |
| paced under load | 65.8 | 79% / 94% (252 samples) | asr-nemotron | 0.67 | 1 | 840.9 | 1289.7 | 760.0 / 895.7 |
| paced under load | 65.8 | 79% / 94% (252 samples) | asr-qwen3asr-0.6b | 3.01 | 5 | 758.9 | 1538.4 | 680.5 / 1442.8 |
| paced under load | 65.8 | 79% / 94% (252 samples) | hy-mt2-1.8b-4bit | 0.0 | 0 | 1368.4 | 2397.6 | – |
| paced under load | 65.8 | 79% / 94% (252 samples) | engine (TTS + Qwen text) | 84.2 | 128 | 4695.0 | 5108.1 | 4187.3 / 4834.4 |
| recognition | 1.7 | 72% / 85% (7 samples) | TranslateCheck (Apple in-process) | 0.05 | 3 | 14.0 | 15.3 | – |
| recognition | 1.7 | 72% / 85% (7 samples) | asr-nemotron | 0.21 | 13 | 967.3 | 1289.7 | 760.0 / 895.7 |
| recognition | 1.7 | 72% / 85% (7 samples) | asr-qwen3asr-0.6b | 0.95 | 57 | 937.5 | 1347.5 | 680.5 / 1442.8 |
| recognition | 1.7 | 72% / 85% (7 samples) | hy-mt2-1.8b-4bit | 0.0 | 0 | 1371.0 | 2397.6 | – |
| recognition | 1.7 | 72% / 85% (7 samples) | engine (TTS + Qwen text) | 0.0 | 0 | 4338.6 | 4928.1 | 4039.8 / 4834.4 |
| recognition under load | 2.2 | 90% / 100% (9 samples) | TranslateCheck (Apple in-process) | 0.06 | 3 | 9.9 | 15.3 | – |
| recognition under load | 2.2 | 90% / 100% (9 samples) | asr-nemotron | 0.22 | 10 | 964.3 | 1289.7 | 760.0 / 895.7 |
| recognition under load | 2.2 | 90% / 100% (9 samples) | asr-qwen3asr-0.6b | 1.06 | 49 | 939.8 | 1538.4 | 680.5 / 1442.8 |
| recognition under load | 2.2 | 90% / 100% (9 samples) | hy-mt2-1.8b-4bit | 0.0 | 0 | 1368.4 | 2397.6 | – |
| recognition under load | 2.2 | 90% / 100% (9 samples) | engine (TTS + Qwen text) | 2.56 | 118 | 4645.6 | 5085.9 | 4189.0 / 4834.4 |
| translation | 3.4 | 57% / 97% (14 samples) | TranslateCheck (Apple in-process) | 0.05 | 2 | 10.4 | 15.3 | – |
| translation | 3.4 | 57% / 97% (14 samples) | asr-nemotron | 0.0 | 0 | 840.3 | 1289.7 | 760.0 / 895.7 |
| translation | 3.4 | 57% / 97% (14 samples) | asr-qwen3asr-0.6b | 0.0 | 0 | 758.4 | 1538.4 | 680.5 / 1442.8 |
| translation | 3.4 | 57% / 97% (14 samples) | hy-mt2-1.8b-4bit | 0.68 | 20 | 1549.8 | 2397.6 | – |
| translation | 3.4 | 57% / 97% (14 samples) | engine (TTS + Qwen text) | 0.59 | 17 | 4518.8 | 4928.1 | 4039.8 / 4834.4 |
| translation under load | 9.0 | 78% / 98% (35 samples) | TranslateCheck (Apple in-process) | 0.07 | 1 | 9.8 | 15.3 | – |
| translation under load | 9.0 | 78% / 98% (35 samples) | asr-nemotron | 0.0 | 0 | 840.9 | 1289.7 | 760.0 / 895.7 |
| translation under load | 9.0 | 78% / 98% (35 samples) | asr-qwen3asr-0.6b | 0.0 | 0 | 758.9 | 1538.4 | 680.5 / 1442.8 |
| translation under load | 9.0 | 78% / 98% (35 samples) | hy-mt2-1.8b-4bit | 0.87 | 10 | 1549.7 | 2397.6 | – |
| translation under load | 9.0 | 78% / 98% (35 samples) | engine (TTS + Qwen text) | 11.41 | 127 | 4663.2 | 5108.1 | 4374.3 / 4834.4 |

## Footprint

| Recognizer | Load | Audio s | ms per minute of speech | Resident MB after |
| --- | --- | --- | --- | --- |
| apple-speech | – | 16.22 | 1065 | – |
| apple-speech | TTS | 16.22 | 1209 | – |
| nemotron | – | 24.79 | 796 | 872 |
| nemotron | TTS | 24.79 | 977 | 873 |
| qwen3asr-0.6b+context | – | 24.79 | 1215 | 810 |
| qwen3asr-0.6b+context | TTS | 24.79 | 1490 | 812 |
| qwen3asr-0.6b | – | 24.79 | 1253 | 810 |
| qwen3asr-0.6b | TTS | 24.79 | 1926 | 812 |

Notes:
- Scoring tokens: lowercase, compatibility mapping, punctuation removed; number words folded to digits where the grammar allows (two numbers in a row stay separate), Chinese numerals folded, percent, currency and minus kept as tokens, and then every digit scored as one token, so '10:30', '1030' and 'ten thirty' agree. The error rate is therefore a token error rate (characters for Mandarin), and a wrong number costs one error per digit.
- Checks pass when an accepted form appears inside the stretch of the transcript aligned with the check's reference sentence (edit-distance alignment, a few tokens of slack); checks without a sentence number search the whole transcript.
- The '+context' recognizers and the translators' glossary receive the scripted names themselves, an oracle list: the best case for a participant list, not a prediction of one.
- Recognition rows run the complete recording in phrase mode. Paced rows feed energy-gated phrases in real time (coverage = fraction of the recording fed) and measure delays from the nominal phrase end; phrase-mode engines also re-run the growing phrase every 1.0 s.
- Translation rows translate the reference text, not recognizer output, so translation quality is isolated; meaning is rated by people from the review sheet.
- Under-load rows were measured while Qwen TTS synthesized continuously in the engine; the load table reports that synthesis. The Qwen text translator shares the engine process and its one-request-at-a-time executor, so its under-load delay is queueing behind the synthesis unit in progress.
- Resources per pass: CPU time (user plus system) and physical footprint per process from the kernel (proc_pid_rusage), MLX active, peak and cache bytes from each helper's stats reply, and the GPU's device utilization from the graphics driver's IOKit statistics polled every 250 ms. GPU utilization is for the whole GPU during the pass (every helper and any other app), so it is a load figure, not a per-model cost; nothing here needs privileges, and energy and thermal behaviour are not measured (they need powermetrics, which needs root).
