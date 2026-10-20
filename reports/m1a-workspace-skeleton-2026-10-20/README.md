# Milestone 1a · workspace skeleton and TranslateCore

**October 20, 2026 · local only**

## What exists now

- `Development/NeroNook-Translate` is a Swift package that builds alone: `TranslateCore` (Foundation and CryptoKit only), `TranslateCheck` (uses the real SDK validators), two test targets.
- The shared SDK is vendored from NeroNook `main` @ `91590c9b18255b297bfa1ebdb72fc10af73ff75c` (host 0.34.24), the last commit before the seasonal-surface candidate. `SDK-SNAPSHOT.json` holds all 103 file hashes; the Creator kit is vendored under `Tools/` from the same commit.
- `Resources/NookPlugin.json`: `cafe.nero.plugin.translate`, `launchMode: application`, passes `PluginManifest.validate()`.
- Core covers: session schema v1, append-only journal with policy-gated persistence and recovery, transcript with append-only revisions, two-lane synthesis scheduler with finish-and-discard epochs, consent and persistence policy, bounded caption window, evidence items with per-item staleness.

## Checks run on this Mac

Mac16,5 · Apple M4 Max · 128 GB · macOS 27.0.1 · Swift 6.4 · Xcode MacOSX27.0.sdk.

| Check | Result |
| --- | --- |
| `swift build` | Build complete; warnings only inside the vendored SDK (deprecated `onChange`), none in Translate code |
| `swift test` | **55 tests, 0 failures** (TranslateCoreTests 54, TranslatePluginTests 1), after the review fixes below |
| `.build/debug/TranslateCheck --manifest Resources/NookPlugin.json` | `OK manifest cafe.nero.plugin.translate 0.1.0` |
| `.build/debug/TranslateCheck --replay Fixtures/journal-sample.jsonl` | `events=4 utterances=1 lastSeq=4 validBytes=962 ignoredTail=false` |
| Same on a file cut mid-line | `events=0 validBytes=0 ignoredTail=true` |
| `python3 -I Tools/nook.py doctor .` | 8 of 8 PASS (snapshot, manifest, package, macOS, Swift, SDK, XCTest, codesign/ditto) |

## Exit checks from the plan (§6, 1a)

| Check | Test |
| --- | --- |
| Revision linkage; spoken translation retained after correction | `RevisionLinkageTests` |
| Queue bounds, oldest-first fairness, cancellation epochs, finish-and-discard, 100× stop/start stress | `SchedulerTests` |
| Every saving × consent × pause combination; nothing-saved writes no bytes and opens no file; pause or withdrawn agreement keeps only gap/state events, in either order | `PersistencePolicyTests`, `FileJournalSinkTests` |
| Journal recovery from a truncated last line; corrupt, over-long or out-of-order line stops replay; replay equals the live transcript bit for bit; resume after a crash cuts the partial line; two-phase prepare/append; write failure stops the record | `JournalRecoveryTests`, `FileJournalSinkTests` |
| Per-item stale-note detection; regeneration refused on stale citations; thoughts preserved | `EvidenceStalenessTests` |
| Caption state fits 32 KiB by trimming oldest from the heavier lane | `CaptionWindowTests` |
| Manifest passes the SDK validator | `ManifestTests` |

## Findings while building

- `.macOS(.v26)` is not in the tools-6.0 manifest API; `.macOS("26.0")` is.
- `secondsSince1970` date encoding changed the last bit of 967 of 2,000 random dates in a probe; Swift's `deferredToDate` changed none. Core uses the latter.
- The journal reader requires contiguous sequence numbers; a gap stops replay rather than being skipped.

## Independent review and what changed

A separate reviewer read the code against the plan and ran the checks. Its findings and the fixes made:

| Severity | Finding | Fix |
| --- | --- | --- |
| High | Reopening a journal after a crash appended onto the partial last line, stranding every later event | `Journal.open` recovers, cuts the file to `validBytes`, seeds the sequence; test resumes after a simulated crash and after a corrupt line |
| Medium | A transcript mutation could succeed while its journal line failed (over-long line or write error), so the two drift | Two-phase `prepare`/`append`; a write failure stops the journal permanently; tests for both |
| Medium | Withdrawing recording agreement could not itself be journaled if the policy changed first | State events (`consent.changed`, `session.state`, gaps, pause, voice readiness) persist whenever a record exists; withdrawal keeps its timestamp |
| Medium | The splitter broke "1.5 million", "10:30", "1,000", "e.g."; the test hid it by stripping spaces | Latin enders break only before whitespace or the end; units rejoin to the exact normalized input; test asserts exact equality |
| Medium | Backlog lost a phrase's seconds once its first unit started | Seconds are shared across units by text size; the running unit is reported separately |
| Low | Status could move backwards; voice/route could silently change; replay threw away the prefix on a fault; default evidence quotes could exceed the bound; chunk paths accepted absolute paths; committed-event ID unchecked | All fixed with tests |

Not changed, by design and now documented: a speaker-label correction does not mark evidence stale (the hash covers the words, not the label); the scheduler's fairness unit is the sentence-sized unit, not the phrase; phrase queues are unbounded in memory because nothing is silently dropped, and "queue bounds" means the backlog levels.

## Not done or not verified

- No app process, no handshake with the host, no custom view, no audio, no engine, no driver. Nothing installed, captured or downloaded.
- `transcript.json` compaction and `session.json` writing are schema-only; no writer yet.
- Strict concurrency checking is off (Swift 5 language mode, matching the other plugins).
- No public release; the release floor (host 0.35.0) is unchanged.
