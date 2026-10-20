# Session data format (schema 1)

This is what `TranslateCore` writes and reads today. The design is in the [architecture plan §5](ARCHITECTURE-PLAN.md#5-versioned-session-data-outline); this page records the concrete encoding rules the code enforces.

## Files

```
<session>/session.json      manifest; atomic rewrite
<session>/journal.jsonl     append-only events, one per line
<session>/transcript.json   compacted snapshot, derived from the journal (not written yet)
<session>/notes.json        personal thoughts + generated notes
```

Nothing is written for a session saved as **none**. While recording is **paused**, only `gap`, `recording.paused`, `recording.resumed`, `session.state` and `consent.changed` events are written.

## Encoding rules

- JSON with sorted keys, no escaped slashes, no pretty printing in the journal.
- Wall-clock dates (`at` on revisions, `createdAt`, `generatedAt`) are Swift `Date` values encoded as **seconds since 2001‑01‑01 UTC** (a double). This round-trips exactly, which replay equality depends on. Session-clock times (`at` on journal events, `start`/`end`) are plain seconds since the session epoch.
- Every new field must be optional so older files keep decoding.
- Bounds: 40,000 utterances and 4.5 h per session; 2,048 bytes per text; 16 KiB per journal line; 512 bytes per evidence quote; 80 bytes per label.

## journal.jsonl

One event per line, newline-terminated. `seq` starts at 1 and is contiguous; suppressed events do not consume numbers.

```json
{"at":3.4,"data":{…},"seq":2,"type":"translation.added","utterance":"<uuid>"}
```

| `type` | `data` | `utterance` |
| --- | --- | --- |
| `utterance.committed` | the full utterance | required |
| `source.revised` | `{rev, origin, text, words?, at}` | required |
| `translation.added` | `{rev, sourceRev, origin, provider?, text, at}` | required |
| `synthesis.status` | `{attempt, translationRev, voice{slot, revision, blend?}, status, route, playback?, generatedAudio?}`; the same attempt number updates status | required |
| `speaker.revised` | `{speaker, label?}` | required |
| `span.marked` | `{kind, from, to}` | required |
| `gap` | `{track, start, end, reason}` | — |
| `consent.changed` | `{voiceMatching{granted, at?}, recording{granted, at?}}` | — |
| `voice.ready` | `{slot, revision}` | — |
| `recording.paused` / `recording.resumed` | `{}` | — |
| `session.state` | `{state}` | — |

**Recovery.** Only complete lines count: a final line without its newline is ignored. Reading stops at the first malformed line or the first break in the sequence; everything before it is replayed, and replay itself keeps the prefix before any event that cannot apply (`stoppedAtSeq`). A session recovered this way is marked `interrupted` by the app.

**Resuming.** `Journal.open` recovers first, then cuts the file to the valid prefix (`validBytes`) before appending, so a partial line left by a crash never swallows later events. Writing is two-phase: the event is encoded and bound-checked before the transcript mutates, and appended after. If a write fails, the journal refuses further writes; the live transcript continues in memory and the saved record ends at the last written sequence, which the app reports as a recording failure.

**Invariants the replay enforces.** Utterance IDs never change. Source revisions and translations are append-only and numbered without gaps. A translation names the source revision it translated. A synthesis attempt names the translation revision it spoke and can never change it, so the spoken text stays on record after later corrections. Speaker corrections keep the ID.

A sample is in `Fixtures/journal-sample.jsonl`; `TranslateCheck --replay <file>` replays any journal and prints counts only.

## notes.json

`{schemaVersion, thoughts, generated?{provider, generatedAt, items[]}}`. Each item: `{id, kind, text, status, owner?, due?, uncertain, evidence[], evidenceHash, stale}`. An evidence item: `{meetingID, utteranceID, sourceRevision, quote, track, start, end, correctionState, speaker, language, translationRevision?}`. `evidenceHash` is SHA‑256 over the sorted `utteranceID:sourceRevision` pairs, so it changes only when a cited revision does. An item is stale when any cited utterance is missing or has moved past the cited revision. Regeneration is refused while any citation is stale. `speaker` and `correctionState` are snapshots taken when the item was made: a later speaker-label correction does not make the item stale, because the evidence is the words, not the label.
