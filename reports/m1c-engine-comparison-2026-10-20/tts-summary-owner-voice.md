# TTS variants · 2026-10-21T01:59:02Z · Mac16,5

| Variant | Startup ms | Load ms | Prepare ms per voice and language | Resident MB | Recognition load |
| --- | --- | --- | --- | --- | --- |
| base-1.7b-8bit | 873 | 848 | local-en→en 77, local-en→en (under recognition) 69 | 3087.1 | 0 passes |
| base-1.7b-bf16 | 1040 | 1018 | local-en→en 93, local-en→en (under recognition) 72 | 4455.6 | 2 passes |
| base-0.6b-8bit | 716 | 690 | local-en→en 84, local-en→en (under recognition) 74 | 2027.4 | 0 passes |

| Variant | Interval s | Under recognition | Clips | Mean first audio ms | Max first audio ms | Mean RTF | Max RTF |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base-0.6b-8bit | 0.16 | no | 2 | 116 | 136 | 0.357 | 0.391 |
| base-0.6b-8bit | 0.32 | no | 2 | 139 | 140 | 0.341 | 0.382 |
| base-0.6b-8bit | 0.32 | yes | 1 | 130 | 130 | 0.300 | 0.300 |
| base-1.7b-8bit | 0.16 | no | 2 | 155 | 156 | 0.341 | 0.343 |
| base-1.7b-8bit | 0.32 | no | 2 | 202 | 207 | 0.321 | 0.322 |
| base-1.7b-8bit | 0.32 | yes | 1 | 201 | 201 | 0.312 | 0.312 |
| base-1.7b-bf16 | 0.16 | no | 2 | 293 | 297 | 1.704 | 1.724 |
| base-1.7b-bf16 | 0.32 | no | 2 | 619 | 666 | 1.744 | 1.797 |
| base-1.7b-bf16 | 0.32 | yes | 1 | 683 | 683 | 1.949 | 1.949 |

| Pass | Wall s | GPU device % mean / max | Process | CPU s | CPU % | Footprint MB | Peak footprint MB | MLX active / peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base-0.6b-8bit alone | 7.9 | 64% / 79% (31 samples) | engine | 10.26 | 130 | 2413.8 | 2940.2 | 2009.1 / 3535.3 |
| base-0.6b-8bit alone | 7.9 | 64% / 79% (31 samples) | TranslateCheck | 0.02 | 0 | 13.1 | 19.6 | – |
| base-0.6b-8bit alone | 7.9 | 64% / 79% (31 samples) | asr-nemotron | 0.0 | 0 | 834.8 | 1029.8 | 760.0 / 784.6 |
| base-0.6b-8bit under recognition | 3.1 | 64% / 74% (13 samples) | engine | 4.21 | 135 | 2426.1 | 2940.2 | 2009.1 / 3669.5 |
| base-0.6b-8bit under recognition | 3.1 | 64% / 74% (13 samples) | TranslateCheck | 0.01 | 0 | 13.2 | 19.6 | – |
| base-0.6b-8bit under recognition | 3.1 | 64% / 74% (13 samples) | asr-nemotron | 0.07 | 2 | 999.4 | 1029.8 | 762.3 / 784.6 |
| base-1.7b-8bit alone | 8.4 | 79% / 88% (33 samples) | engine | 10.48 | 125 | 3499.0 | 4092.3 | 3070.9 / 4589.6 |
| base-1.7b-8bit alone | 8.4 | 79% / 88% (33 samples) | TranslateCheck | 0.03 | 0 | 13.9 | 14.4 | – |
| base-1.7b-8bit alone | 8.4 | 79% / 88% (33 samples) | asr-nemotron | 0.0 | 0 | 821.4 | 821.5 | 760.0 / 760.0 |
| base-1.7b-8bit under recognition | 3.3 | 81% / 88% (13 samples) | engine | 4.06 | 123 | 3495.6 | 4109.3 | 3070.9 / 4731.2 |
| base-1.7b-8bit under recognition | 3.3 | 81% / 88% (13 samples) | TranslateCheck | 0.01 | 0 | 14.1 | 17.3 | – |
| base-1.7b-8bit under recognition | 3.3 | 81% / 88% (13 samples) | asr-nemotron | 0.08 | 3 | 997.3 | 1017.6 | 762.3 / 778.1 |
| base-1.7b-bf16 alone | 41.8 | 78% / 91% (160 samples) | engine | 50.21 | 120 | 4843.4 | 6279.0 | 4444.3 / 5967.4 |
| base-1.7b-bf16 alone | 41.8 | 78% / 91% (160 samples) | TranslateCheck | 0.05 | 0 | 12.6 | 19.6 | – |
| base-1.7b-bf16 alone | 41.8 | 78% / 91% (160 samples) | asr-nemotron | 0.0 | 0 | 833.5 | 1017.6 | 760.0 / 778.1 |
| base-1.7b-bf16 under recognition | 20.1 | 76% / 93% (77 samples) | engine | 24.04 | 120 | 4847.7 | 6375.4 | 4444.3 / 6104.7 |
| base-1.7b-bf16 under recognition | 20.1 | 76% / 93% (77 samples) | TranslateCheck | 0.03 | 0 | 13.2 | 19.6 | – |
| base-1.7b-bf16 under recognition | 20.1 | 76% / 93% (77 samples) | asr-nemotron | 0.6 | 3 | 999.1 | 1029.8 | 762.3 / 784.6 |

Notes:
- Clip ids are blinded; private/key.json and private/listening-receipt.json map them to variant and interval and must stay away from listeners.
- First audio and RTF are warm (one synthesis per slot before measuring). 'Under recognition' clips were made while Nemotron streamed a clip in a loop.
- Identity ratings only mean something with the speakers' own reference recordings; synthetic fixtures check the plumbing.
- Resources: CPU time and footprint per process from the kernel, MLX counters from the helpers, GPU device utilization from the graphics driver polled every 250 ms (whole GPU, every process).
