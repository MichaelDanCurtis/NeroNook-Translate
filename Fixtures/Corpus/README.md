# Comparison corpus

Scripts for the Milestone 1c engine comparison (plan §6.1). The scripts are versioned; the recordings are not. Raw and re-encoded audio live under `raw/` and `codec/`, which git ignores, so no voice ever enters the repository.

```
scripts/en.md   English reading script and natural-speech prompts
scripts/es.md   Spanish reading script and prompts (variety to be chosen by the owner)
scripts/zh.md   Mandarin reading script with tone-minimal pairs; drafted for a native speaker to check
raw/<lang>/     recordings as exported (ignored)
codec/<lang>/   low-bitrate Opus copies made by the harness (ignored)
gold/<lang>/    corrected transcripts of the natural parts (reviewed text only; may be committed)
```

Each numbered sentence in a script is its own ground truth. When a speaker read a sentence differently (a slip the recording keeps), `gold/<lang>/as-read.json` records what was said and that sentence's checks; the gold follows it, agreed before scoring, and the script stays as written for the next speaker. Names, numbers, dates, negations and self-corrections are deliberate: they are what the scoring checks. The natural-speech prompts produce the unscripted part; its transcript is drafted by one recognizer and corrected by the speaker before it counts.

Every speaker agrees, before recording, to be recorded for these tests, to have the recording used for listening comparisons, and to have a short part of it used as a reference so the TTS variants can be compared in their voice (the Milestone 1c listening set; the clips stay out of git and are deleted after the comparison). Using a voice in live calls (Milestone 1d onwards) is a separate agreement.
