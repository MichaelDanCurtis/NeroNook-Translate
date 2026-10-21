# Comparison report · reports/m1c-engine-comparison-2026-10-20/run/compare · source: compare-receipt.json · items: en/scripted

## Recognition, whole recording (phrase mode); check columns count the clean and codec copies together

| Candidate | Error rate clean | Error rate codec | Names | Numbers | Dates | Negation | Corrections | Checks | Clean, TTS running |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-speech | 9.5% | 9.7% | 9/22 (41%) | 28/32 (88%) | 14/18 (78%) | 14/14 (100%) | 6/8 (75%) | 71/94 | 9.5% |
| apple-speech+context | 9.5% | 9.7% | 9/22 (41%) | 28/32 (88%) | 14/18 (78%) | 14/14 (100%) | 6/8 (75%) | 71/94 | 9.5% |
| nemotron | 10.3% | 10.3% | 8/22 (36%) | 30/32 (94%) | 12/18 (67%) | 14/14 (100%) | 6/8 (75%) | 70/94 | 10.3% |
| qwen3asr-0.6b | 8.9% | 8.9% | 10/22 (45%) | 30/32 (94%) | 14/18 (78%) | 14/14 (100%) | 6/8 (75%) | 74/94 | 8.9% |
| qwen3asr-0.6b+context | 8.6% | 8.9% | 11/22 (50%) | 30/32 (94%) | 14/18 (78%) | 14/14 (100%) | 5/8 (62%) | 74/94 | 8.6% |
| qwen3asr-1.7b | 7.2% | 7.8% | 11/22 (50%) | 30/32 (94%) | 14/18 (78%) | 14/14 (100%) | 6/8 (75%) | 75/94 | 7.2% |
| qwen3asr-1.7b+context | 6.4% | 7.0% | 20/22 (91%) | 30/32 (94%) | 14/18 (78%) | 14/14 (100%) | 6/8 (75%) | 84/94 | 6.4% |

## Paced, phrases fed in real time (clean recording)

| Candidate | Phrases | Coverage | Error rate | Final delay mean / p90 / max ms | First partial ms | Prefix re-run mean / max ms | Final p90, TTS running | Error rate codec |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| apple-speech | 30 | 79% | 11.4% | 63 / 90 / 115 | 3264 | – | 81 | 11.1% |
| apple-speech+context | 30 | 79% | 11.4% | 58 / 79 / 90 | 3265 | – | 83 | 11.1% |
| nemotron | 30 | 79% | 11.4% | 51 / 71 / 76 | 1746 | – | 71 | 12.0% |
| qwen3asr-0.6b | 30 | 79% | 10.0% | 155 / 211 / 391 | 1121 | 99 / 484 | 168 | 10.9% |
| qwen3asr-1.7b | 30 | 79% | 8.4% | 221 / 313 / 354 | 1188 | 147 / 289 | 341 | 8.4% |

## Translation timing per line (meaning is rated by people from translation-review.md)

| Translator | Pair | Lines | Mean ms alone | Mean ms, TTS running | First token ms alone |
| --- | --- | --- | --- | --- | --- |
| apple-translation | en→es | 25 | 422 | 510 | – |
| hy-mt2-1.8b-4bit | en→es | 25 | 178 | 228 | 84 |
| qwen3.5-2b-4bit | en→es | 25 | 240 | 2272 | 77 |
| qwen3.5-2b-4bit-nocontext | en→es | 25 | 137 | 2013 | 61 |

## Qwen TTS during the under-load passes

- paced: 1034 syntheses, RTF 0.324, first audio 161 ms
- recognition: 25 syntheses, RTF 0.563, first audio 342 ms
- translation: 103 syntheses, RTF 0.346, first audio 170 ms

## Against the §6.1 bars (names, numbers, dates ≥ 95%; error rate ≤ 10% clean, ≤ 15% codec; final text ≤ 0.5 s after the phrase)

- **apple-speech**: fails: names 41% < 95%; numbers 88% < 95%; dates 78% < 95%
- **apple-speech+context**: fails: names 41% < 95%; numbers 88% < 95%; dates 78% < 95%
- **nemotron**: fails: error rate clean 10.3% > 10%; names 36% < 95%; numbers 94% < 95%; dates 67% < 95%
- **qwen3asr-0.6b**: fails: names 45% < 95%; numbers 94% < 95%; dates 78% < 95%
- **qwen3asr-0.6b+context**: fails: names 50% < 95%; numbers 94% < 95%; dates 78% < 95%
- **qwen3asr-1.7b**: fails: names 50% < 95%; numbers 94% < 95%; dates 78% < 95%
- **qwen3asr-1.7b+context**: fails: names 91% < 95%; numbers 94% < 95%; dates 78% < 95%

Meaning (translation), consistency and the listening set are rated by people; this report covers the measured bars only.

> Scoring tokens: lowercase, compatibility mapping, punctuation removed; number words folded to digits where the grammar allows (two numbers in a row stay separate), Chinese numerals folded, percent, currency and minus kept as tokens, and then every digit scored as one token, so '10:30', '1030' and 'ten thirty' agree. The error rate is therefore a token error rate (characters for Mandarin), and a wrong number costs one error per digit.

> Checks pass when an accepted form appears inside the stretch of the transcript aligned with the check's reference sentence (edit-distance alignment, a few tokens of slack); checks without a sentence number search the whole transcript.
