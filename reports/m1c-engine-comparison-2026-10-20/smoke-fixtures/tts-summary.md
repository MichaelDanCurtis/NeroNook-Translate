# TTS variants · 2026-10-20T21:03:59Z · Mac16,5

| Variant | Startup ms | Load ms | Prepare ms per voice | Resident MB |
| --- | --- | --- | --- | --- |
| base-0.6b-8bit | 448 | 426 | generic-en→en 36, generic-en→es 35, local-en→en 33, local-en→es 34, remote-es→en 35, remote-es→es 35 | 2024.9 |
| base-1.7b-bf16 | 537 | 515 | generic-en→en 38, generic-en→es 36, local-en→en 36, local-en→es 36, remote-es→en 36, remote-es→es 38 | 4456.7 |

| Variant | Interval s | Under recognition | Clips | Mean first audio ms | Max first audio ms | Mean RTF | Max RTF |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base-0.6b-8bit | 0.16 | no | 12 | 70 | 76 | 0.278 | 0.291 |
| base-0.6b-8bit | 0.32 | no | 12 | 104 | 111 | 0.258 | 0.280 |
| base-0.6b-8bit | 0.32 | yes | 6 | 104 | 107 | 0.255 | 0.263 |
| base-1.7b-bf16 | 0.16 | no | 12 | 300 | 361 | 1.731 | 1.948 |
| base-1.7b-bf16 | 0.32 | no | 12 | 550 | 716 | 1.723 | 2.054 |
| base-1.7b-bf16 | 0.32 | yes | 6 | 570 | 705 | 1.715 | 1.780 |

Notes:
- Clip ids are blinded; key.json maps them to variant and interval and must stay away from listeners.
- First audio and RTF are warm (one synthesis per slot before measuring). 'Under recognition' clips were made while Nemotron streamed a clip in a loop.
- Identity ratings only mean something with the speakers' own reference recordings; synthetic fixtures check the plumbing.
