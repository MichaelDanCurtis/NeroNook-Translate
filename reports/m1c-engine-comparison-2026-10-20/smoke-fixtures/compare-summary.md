# Engine comparison · fixtures (synthetic voices; plumbing check only)

2026-10-20T21:32:32Z · Mac16,5

Build: gitHead 5e0eb89 (plus uncommitted changes unless the receipt says otherwise) · sdkStamp 27.0

Settings: appleLocales = en-US, es-ES, zh-CN; applePaced = reporting: volatileResults; one analyzer per phrase, prepared and started before the clock; 320 ms buffers; chunkMs = 560; contextWindow = 2; load = true; paced = true; prefixEvery = 1.0; spanishLocale = es-ES

Models:
- engine tts: `Qwen3-TTS-12Hz-1.7B-Base-8bit-e7dd0585652209fa0d7783659aad4e8a324de11c`
- hy-mt2-1.8b-4bit: `/Volumes/Main External/Development/NeroNook-Voice/build/interpreter-models/translator`
- nemotron: `nemotron-3.5-asr-streaming-0.6b-8bit-7279359e4481b5e9e185a318bd618e429c6d86cd`
- qwen3.5-2b: `Qwen3.5-2B-4bit-674aaa7240b91e8012fcad5d791b7dfe5ba90207`
- qwen3asr-0.6b: `Qwen3-ASR-0.6B-4bit-313d850181767edf09f00a9c289becca70e58cd0`
- qwen3asr-1.7b: `Qwen3-ASR-1.7B-8bit-a8379a2e2f9e313c9292cdf1af4055ab56d50d55`

## Recognition (whole recording, phrase mode)

| Recognizer | Item | Load | Error rate | Checks | Names | Numbers | Dates | Negation | Corrections | Time / audio | RTF |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nemotron | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 109 ms / 8.37 s | 0.013 |
| nemotron | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 96 ms / 7.85 s | 0.012 |
| nemotron | fixture/remote-es | – | 0.0% (0/30) | 0/0 | – | – | – | – | – | 110 ms / 8.57 s | 0.013 |
| qwen3asr-0.6b | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 179 ms / 8.37 s | 0.021 |
| qwen3asr-0.6b | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 139 ms / 7.85 s | 0.018 |
| qwen3asr-0.6b | fixture/remote-es | – | 3.3% (1/30) | 0/0 | – | – | – | – | – | 199 ms / 8.57 s | 0.023 |
| qwen3asr-0.6b+context | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 167 ms / 8.37 s | 0.02 |
| qwen3asr-0.6b+context | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 139 ms / 7.85 s | 0.018 |
| qwen3asr-0.6b+context | fixture/remote-es | – | 3.3% (1/30) | 0/0 | – | – | – | – | – | 196 ms / 8.57 s | 0.023 |
| qwen3asr-1.7b | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 354 ms / 8.37 s | 0.042 |
| qwen3asr-1.7b | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 276 ms / 7.85 s | 0.035 |
| qwen3asr-1.7b | fixture/remote-es | – | 0.0% (0/30) | 0/0 | – | – | – | – | – | 410 ms / 8.57 s | 0.048 |
| qwen3asr-1.7b+context | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 321 ms / 8.37 s | 0.038 |
| qwen3asr-1.7b+context | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 275 ms / 7.85 s | 0.035 |
| qwen3asr-1.7b+context | fixture/remote-es | – | 0.0% (0/30) | 0/0 | – | – | – | – | – | 406 ms / 8.57 s | 0.047 |
| apple-speech | fixture/generic-en | – | 0.0% (0/29) | 0/0 | – | – | – | – | – | 143 ms / 8.37 s | 0.017 |
| apple-speech | fixture/local-en | – | 0.0% (0/27) | 0/0 | – | – | – | – | – | 144 ms / 7.85 s | 0.018 |
| apple-speech | fixture/remote-es | – | failed: Apple speech failed for es-ES (asset status supported): Error Domain=SFSpeechErrorDomain Code=3 "Audio format is not supported" UserInfo={NSLocalizedDescription=Audio format is not supported} | | | | | | | | |
| nemotron | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 102 ms / 8.37 s | 0.012 |
| nemotron | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 91 ms / 7.85 s | 0.012 |
| nemotron | fixture/remote-es | TTS | 0.0% (0/30) | 0/0 | – | – | – | – | – | 108 ms / 8.57 s | 0.013 |
| qwen3asr-0.6b | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 172 ms / 8.37 s | 0.021 |
| qwen3asr-0.6b | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 133 ms / 7.85 s | 0.017 |
| qwen3asr-0.6b | fixture/remote-es | TTS | 3.3% (1/30) | 0/0 | – | – | – | – | – | 193 ms / 8.57 s | 0.023 |
| qwen3asr-0.6b+context | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 155 ms / 8.37 s | 0.019 |
| qwen3asr-0.6b+context | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 176 ms / 7.85 s | 0.022 |
| qwen3asr-0.6b+context | fixture/remote-es | TTS | 3.3% (1/30) | 0/0 | – | – | – | – | – | 195 ms / 8.57 s | 0.023 |
| qwen3asr-1.7b | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 361 ms / 8.37 s | 0.043 |
| qwen3asr-1.7b | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 301 ms / 7.85 s | 0.038 |
| qwen3asr-1.7b | fixture/remote-es | TTS | 0.0% (0/30) | 0/0 | – | – | – | – | – | 418 ms / 8.57 s | 0.049 |
| qwen3asr-1.7b+context | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 345 ms / 8.37 s | 0.041 |
| qwen3asr-1.7b+context | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 324 ms / 7.85 s | 0.041 |
| qwen3asr-1.7b+context | fixture/remote-es | TTS | 0.0% (0/30) | 0/0 | – | – | – | – | – | 493 ms / 8.57 s | 0.058 |
| apple-speech | fixture/generic-en | TTS | 0.0% (0/29) | 0/0 | – | – | – | – | – | 168 ms / 8.37 s | 0.02 |
| apple-speech | fixture/local-en | TTS | 0.0% (0/27) | 0/0 | – | – | – | – | – | 161 ms / 7.85 s | 0.021 |
| apple-speech | fixture/remote-es | TTS | failed: Apple speech failed for es-ES (asset status supported): Error Domain=SFSpeechErrorDomain Code=3 "Audio format is not supported" UserInfo={NSLocalizedDescription=Audio format is not supported} | | | | | | | | |

## Paced (phrases fed in real time)

| Recognizer | Item | Load | Phrases | Coverage | Error rate | Checks | Final delay mean / p90 / max ms | First partial ms | Prefix re-run mean / max ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nemotron | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 72 / 72 / 72 | 1160 | – |
| nemotron | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 53 / 53 / 53 | 1186 | – |
| nemotron | fixture/remote-es | – | 1 | 99% | 0.0% | 0/0 | 33 / 33 / 33 | 1180 | – |
| qwen3asr-0.6b | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 312 / 312 / 312 | 1145 | 113 / 162 |
| qwen3asr-0.6b | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 184 / 184 / 184 | 1131 | 113 / 151 |
| qwen3asr-0.6b | fixture/remote-es | – | 1 | 99% | 0.0% | 0/0 | 227 / 227 / 227 | 1155 | 150 / 221 |
| qwen3asr-1.7b | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 436 / 436 / 436 | 1307 | 229 / 340 |
| qwen3asr-1.7b | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 283 / 283 / 283 | 1168 | 194 / 284 |
| qwen3asr-1.7b | fixture/remote-es | – | 1 | 99% | 0.0% | 0/0 | 402 / 402 / 402 | 1188 | 279 / 427 |
| apple-speech | fixture/generic-en | – | 1 | 98% | 0.0% | 0/0 | 82 / 82 / 82 | 4193 | – |
| apple-speech | fixture/local-en | – | 1 | 97% | 0.0% | 0/0 | 113 / 113 / 113 | 4186 | – |
| apple-speech | fixture/remote-es | – | failed: phrase 1: Apple speech offers no audio format for es-ES. | | | | | | |
| nemotron | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 60 / 60 / 60 | 1188 | – |
| nemotron | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 55 / 55 / 55 | 1169 | – |
| nemotron | fixture/remote-es | TTS | 1 | 99% | 0.0% | 0/0 | 37 / 37 / 37 | 1174 | – |
| qwen3asr-0.6b | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 304 / 304 / 304 | 1138 | 110 / 162 |
| qwen3asr-0.6b | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 189 / 189 / 189 | 1134 | 113 / 154 |
| qwen3asr-0.6b | fixture/remote-es | TTS | 1 | 99% | 0.0% | 0/0 | 257 / 257 / 257 | 1144 | 156 / 243 |
| qwen3asr-1.7b | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 408 / 408 / 408 | 1216 | 211 / 316 |
| qwen3asr-1.7b | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 326 / 326 / 326 | 1215 | 214 / 306 |
| qwen3asr-1.7b | fixture/remote-es | TTS | 1 | 99% | 0.0% | 0/0 | 524 / 524 / 524 | 1207 | 308 / 471 |
| apple-speech | fixture/generic-en | TTS | 1 | 98% | 0.0% | 0/0 | 89 / 89 / 89 | 4178 | – |
| apple-speech | fixture/local-en | TTS | 1 | 97% | 0.0% | 0/0 | 115 / 115 / 115 | 4182 | – |
| apple-speech | fixture/remote-es | TTS | failed: phrase 1: Apple speech offers no audio format for es-ES. | | | | | | |

## Translation (timing; meaning is rated from translation-review.md)

| Translator | Item | Pair | Load | Lines ok | Mean ms | Mean first token ms |
| --- | --- | --- | --- | --- | --- | --- |
| apple-translation | fixture/generic-en | en→es | – | 1/1 | 1048 | – |
| apple-translation | fixture/generic-en | en→es | TTS | 1/1 | 1170 | – |
| apple-translation | fixture/local-en | en→es | – | 1/1 | 435 | – |
| apple-translation | fixture/local-en | en→es | TTS | 1/1 | 488 | – |
| apple-translation | fixture/remote-es | es→en | – | 1/1 | 583 | – |
| apple-translation | fixture/remote-es | es→en | TTS | 1/1 | 653 | – |
| hy-mt2-1.8b-4bit | fixture/generic-en | en→es | – | 1/1 | 319 | 126 |
| hy-mt2-1.8b-4bit | fixture/generic-en | en→es | TTS | 1/1 | 369 | 105 |
| hy-mt2-1.8b-4bit | fixture/local-en | en→es | – | 1/1 | 226 | 70 |
| hy-mt2-1.8b-4bit | fixture/local-en | en→es | TTS | 1/1 | 295 | 83 |
| hy-mt2-1.8b-4bit | fixture/remote-es | es→en | – | 1/1 | 202 | 78 |
| hy-mt2-1.8b-4bit | fixture/remote-es | es→en | TTS | 1/1 | 274 | 96 |
| qwen3.5-2b-4bit-nocontext | fixture/generic-en | en→es | – | 1/1 | 184 | 44 |
| qwen3.5-2b-4bit-nocontext | fixture/generic-en | en→es | TTS | 1/1 | 2117 | 59 |
| qwen3.5-2b-4bit-nocontext | fixture/local-en | en→es | – | 1/1 | 156 | 43 |
| qwen3.5-2b-4bit-nocontext | fixture/local-en | en→es | TTS | 1/1 | 2035 | 51 |
| qwen3.5-2b-4bit-nocontext | fixture/remote-es | es→en | – | 1/1 | 172 | 53 |
| qwen3.5-2b-4bit-nocontext | fixture/remote-es | es→en | TTS | 1/1 | 1994 | 59 |
| qwen3.5-2b-4bit | fixture/generic-en | en→es | – | 1/1 | 203 | 62 |
| qwen3.5-2b-4bit | fixture/generic-en | en→es | TTS | 1/1 | 1465 | 51 |
| qwen3.5-2b-4bit | fixture/local-en | en→es | – | 1/1 | 155 | 44 |
| qwen3.5-2b-4bit | fixture/local-en | en→es | TTS | 1/1 | 1930 | 55 |
| qwen3.5-2b-4bit | fixture/remote-es | es→en | – | 1/1 | 172 | 53 |
| qwen3.5-2b-4bit | fixture/remote-es | es→en | TTS | 1/1 | 1919 | 64 |

## Qwen TTS during the under-load passes

| Pass | Syntheses | Audio s | Generation RTF | Mean first audio ms | Errors | Valid |
| --- | --- | --- | --- | --- | --- | --- |
| paced | 52 | 306.9 | 0.301 | 153 | 0 | yes |
| recognition | 1 | 5.8 | 0.791 | 2665 | 0 | yes |
| translation | 8 | 47.4 | 0.312 | 158 | 0 | yes |

## Footprint

| Recognizer | Load | Audio s | ms per minute of speech | Resident MB after |
| --- | --- | --- | --- | --- |
| apple-speech | – | 16.22 | 1061 | – |
| apple-speech | TTS | 16.22 | 1217 | – |
| nemotron | – | 24.79 | 762 | 871 |
| nemotron | TTS | 24.79 | 728 | 872 |
| qwen3asr-0.6b+context | – | 24.79 | 1215 | 812 |
| qwen3asr-0.6b+context | TTS | 24.79 | 1273 | 814 |
| qwen3asr-0.6b | – | 24.79 | 1251 | 811 |
| qwen3asr-0.6b | TTS | 24.79 | 1205 | 814 |
| qwen3asr-1.7b+context | – | 24.79 | 2425 | 2485 |
| qwen3asr-1.7b+context | TTS | 24.79 | 2812 | 2488 |
| qwen3asr-1.7b | – | 24.79 | 2517 | 2485 |
| qwen3asr-1.7b | TTS | 24.79 | 2613 | 2488 |

Notes:
- Scoring tokens: lowercase, compatibility mapping, punctuation removed; number words folded to digits where the grammar allows (two numbers in a row stay separate), Chinese numerals folded, percent, currency and minus kept as tokens, and then every digit scored as one token, so '10:30', '1030' and 'ten thirty' agree. The error rate is therefore a token error rate (characters for Mandarin), and a wrong number costs one error per digit.
- Checks pass when an accepted form appears inside the stretch of the transcript aligned with the check's reference sentence (edit-distance alignment, a few tokens of slack); checks without a sentence number search the whole transcript.
- The '+context' recognizers and the translators' glossary receive the scripted names themselves, an oracle list: the best case for a participant list, not a prediction of one.
- Recognition rows run the complete recording in phrase mode. Paced rows feed energy-gated phrases in real time (coverage = fraction of the recording fed) and measure delays from the nominal phrase end; phrase-mode engines also re-run the growing phrase every 1.0 s.
- Translation rows translate the reference text, not recognizer output, so translation quality is isolated; meaning is rated by people from the review sheet.
- Under-load rows were measured while Qwen TTS synthesized continuously in the engine; the load table reports that synthesis. The Qwen text translator shares the engine process and its one-request-at-a-time executor, so its under-load delay is queueing behind the synthesis unit in progress.
