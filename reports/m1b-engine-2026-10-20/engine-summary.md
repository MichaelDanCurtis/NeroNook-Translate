| Measure | Result |
| --- | --- |
| Spawn to ready (warm disk cache) | 489 ms (model load 466 ms) |
| Prepare `generic` (8.37 s reference) | 50 ms |
| Prepare `local` (7.85 s reference) | 35 ms |
| Prepare `remote` (8.57 s reference) | 35 ms |
| `generic` first audio / RTF (3 warm runs) | 147, 146, 148 ms / 0.29, 0.29, 0.30 |
| `local` first audio / RTF (3 warm runs) | 150, 150, 147 ms / 0.29, 0.29, 0.29 |
| `remote` first audio / RTF (3 warm runs) | 150, 150, 148 ms / 0.30, 0.30, 0.30 |
| Switch overhead (alternating − same slot, mean first audio) | -0.4 ms |
| Discard-to-idle (overlapped) | cancel at 145 ms; generation ran 1729 ms, 1583 ms after the cancel; 0 frames after cancel; other lane's first audio 1733 ms after cancel |
| Stress 100× overlapped stop then start other lane | 0 errors in 388.0 s; max wasted 2575 ms; other lane first audio after cancel mean 1931.5 ms, max 2729 ms; audio after cancel in 0 rounds (max 0 frames) |
| Memory at end | resident 3083.4 MB; MLX active 3063.1 MB, peak 3939.0 MB |
