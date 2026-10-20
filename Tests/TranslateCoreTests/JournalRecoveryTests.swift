import XCTest
@testable import TranslateCore

final class JournalRecoveryTests: XCTestCase {
    private func populatedJournal() throws -> (InMemoryJournalSink, Transcript) {
        let sink = InMemoryJournalSink()
        let journal = Journal(sink: sink, policy: PersistencePolicy(saving: .audioAndTranscript, recordingConsent: true))
        var transcript = Transcript()
        let first = Fixtures.utterance(start: 1, end: 3)
        let second = Fixtures.utterance(direction: .outgoing, start: 4, end: 6, text: "Nice to meet you.")
        try journal.record(try transcript.commit(first), at: 3, utterance: first.id)
        try journal.record(try transcript.addTranslation(first.id, text: "Hi, I'm Ana.", provider: "mt"), at: 3.4, utterance: first.id)
        try journal.record(try transcript.recordSynthesis(first.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: VoiceSelection(slot: .generic), status: .played, route: .headphones, playback: TimeRange(start: 4, end: 5.5))), at: 5.5, utterance: first.id)
        try journal.record(try transcript.commit(second), at: 6, utterance: second.id)
        try journal.record(.gap(Gap(track: .call, start: 6, end: 8, reason: .deviceLost)), at: 8)
        try journal.record(try transcript.reviseSource(first.id, text: "Hola, soy Ana."), at: 9, utterance: first.id)
        try journal.record(try transcript.reviseSpeaker(second.id, speaker: .me, label: "Michael"), at: 9.5, utterance: second.id)
        try journal.record(.recordingPaused, at: 10)
        try journal.record(.sessionState(SessionStateChange(state: .interrupted)), at: 11)
        try journal.flush()
        XCTAssertEqual(sink.flushes, 1)
        return (sink, transcript)
    }

    func testReplayRebuildsTheSameTranscript() throws {
        let (sink, original) = try populatedJournal()
        let recovery = JournalReader.recover(sink.bytes)
        XCTAssertFalse(recovery.ignoredTail)
        XCTAssertNil(recovery.stoppedAtLine)
        XCTAssertEqual(recovery.events.count, 9)
        XCTAssertEqual(recovery.validBytes, sink.bytes.count)
        let (replayed, summary) = Transcript.replay(recovery.events)
        XCTAssertEqual(replayed, original)
        XCTAssertNil(summary.stoppedAtSeq)
        XCTAssertEqual(summary.lastSeq, 9)
        XCTAssertEqual(summary.gaps.count, 1)
        XCTAssertTrue(summary.recordingPaused)
        XCTAssertEqual(summary.sessionState, .interrupted)
    }

    func testTruncatedLastLineIsIgnored() throws {
        let (sink, _) = try populatedJournal()
        let cut = sink.bytes.prefix(sink.bytes.count - 7)
        let recovery = JournalReader.recover(cut)
        XCTAssertTrue(recovery.ignoredTail)
        XCTAssertEqual(recovery.events.count, 8, "Everything up to the last complete line is kept")
        XCTAssertNil(recovery.stoppedAtLine)
        XCTAssertLessThan(recovery.validBytes, cut.count, "The partial tail is outside the valid prefix")
        XCTAssertEqual(cut[cut.startIndex + recovery.validBytes - 1], 10, "The valid prefix ends on a newline")
        let (_, summary) = Transcript.replay(recovery.events)
        XCTAssertNil(summary.sessionState, "The interrupted line was the truncated one")
    }

    func testOverlongLineStopsRecovery() throws {
        let (sink, _) = try populatedJournal()
        var lines = sink.bytes.split(separator: 10, omittingEmptySubsequences: false)
        lines[2] = Data(String(repeating: " ", count: Bounds.maxJournalLineBytes + 1).utf8)
        let recovery = JournalReader.recover(Data(lines.joined(separator: Data([10]))))
        XCTAssertEqual(recovery.stoppedAtLine, 3)
        XCTAssertEqual(recovery.events.count, 2)
    }

    func testCorruptMiddleLineStopsRecoveryThere() throws {
        let (sink, _) = try populatedJournal()
        var lines = sink.bytes.split(separator: 10, omittingEmptySubsequences: false)
        lines[3] = Data("{not json".utf8)
        let data = Data(lines.joined(separator: Data([10])))
        let recovery = JournalReader.recover(data)
        XCTAssertEqual(recovery.stoppedAtLine, 4)
        XCTAssertEqual(recovery.events.count, 3)
    }

    func testOutOfOrderSequenceStopsRecovery() throws {
        let (sink, _) = try populatedJournal()
        var lines = sink.bytes.split(separator: 10, omittingEmptySubsequences: false)
        lines.swapAt(1, 2)
        let data = Data(lines.joined(separator: Data([10])))
        let recovery = JournalReader.recover(data)
        XCTAssertEqual(recovery.events.count, 1)
        XCTAssertEqual(recovery.stoppedAtLine, 2)
    }

    func testLinesAreSingleLineBoundedAndRoundTrip() throws {
        let utterance = Fixtures.utterance(text: "Line one\nline two \"quoted\" / slash")
        let event = JournalEvent(seq: 1, at: 2.5, utterance: utterance.id, payload: .committed(utterance))
        let line = try event.line()
        XCTAssertEqual(line.filter { $0 == 10 }.count, 1, "Exactly one newline, at the end")
        let decoded = try SessionJSON.decoder().decode(JournalEvent.self, from: line.dropLast())
        XCTAssertEqual(decoded, event)
        var huge = utterance
        huge.sourceRevisions[0].text = String(repeating: "x", count: Bounds.maxTextBytes)
        for n in 2...8 { huge.sourceRevisions.append(SourceRevision(rev: n, origin: .user, text: String(repeating: "y", count: Bounds.maxTextBytes))) }
        XCTAssertThrowsError(try JournalEvent(seq: 2, at: 3, utterance: huge.id, payload: .committed(huge)).line())
    }

    func testReplayKeepsThePrefixBeforeAnEventThatCannotApply() throws {
        let utterance = Fixtures.utterance()
        let good = JournalEvent(seq: 1, at: 1, utterance: utterance.id, payload: .committed(utterance))
        let orphan = JournalEvent(seq: 2, at: 2, utterance: UUID(), payload: .sourceRevised(SourceRevision(rev: 2, origin: .user, text: "x")))
        let later = JournalEvent(seq: 3, at: 3, utterance: nil, payload: .sessionState(SessionStateChange(state: .saved)))
        let (transcript, summary) = Transcript.replay([good, orphan, later])
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(summary.stoppedAtSeq, 2)
        XCTAssertEqual(summary.lastSeq, 1)
        XCTAssertNil(summary.sessionState, "Nothing after the fault is applied")
    }

    func testFractionalDatesRoundTripExactly() throws {
        for _ in 0..<200 {
            let utterance = Fixtures.utterance(text: "ahora")
            let revision = SourceRevision(rev: 2, origin: .user, text: "now", at: Date().addingTimeInterval(Double.random(in: 0..<1)))
            var revised = utterance
            revised.sourceRevisions.append(revision)
            let line = try JournalEvent(seq: 1, at: 1, utterance: revised.id, payload: .committed(revised)).line()
            let decoded = try SessionJSON.decoder().decode(JournalEvent.self, from: line.dropLast())
            guard case .committed(let back) = decoded.payload else { return XCTFail() }
            XCTAssertEqual(back.sourceRevisions[1].at, revision.at, "Date must round-trip bit for bit")
        }
    }

    func testPrepareFailsBeforeTheTranscriptMutates() throws {
        let sink = InMemoryJournalSink()
        let journal = Journal(sink: sink, policy: PersistencePolicy(saving: .transcript, recordingConsent: true))
        var transcript = Transcript()
        var huge = Fixtures.utterance()
        huge.sourceRevisions[0].words = (0..<2000).map { Word("w\($0)", start: Double($0), end: Double($0) + 0.5) }
        // Two-phase use: encode first, mutate second, append third.
        XCTAssertThrowsError(try journal.prepare(.committed(huge), at: 1, utterance: huge.id), "Line exceeds its bound")
        XCTAssertEqual(transcript.count, 0, "The transcript was never touched")
        XCTAssertEqual(journal.lastSeq, 0)

        let fine = Fixtures.utterance()
        let prepared = try journal.prepare(.committed(fine), at: 1, utterance: fine.id)
        _ = try transcript.commit(fine)
        XCTAssertEqual(try journal.append(prepared)?.seq, 1)
    }

    func testWriteFailureStopsTheJournalPermanently() throws {
        let sink = InMemoryJournalSink()
        let journal = Journal(sink: sink, policy: PersistencePolicy(saving: .transcript, recordingConsent: true))
        try journal.record(.sessionState(SessionStateChange(state: .live)), at: 1)
        sink.failNextAppend = true
        XCTAssertThrowsError(try journal.record(.sessionState(SessionStateChange(state: .interrupted)), at: 2))
        XCTAssertNotNil(journal.failure)
        XCTAssertThrowsError(try journal.record(.sessionState(SessionStateChange(state: .saved)), at: 3), "Nothing is appended behind a possibly partial line")
        XCTAssertEqual(journal.lastSeq, 1)
        XCTAssertEqual(JournalReader.recover(sink.bytes).events.count, 1)
    }

    func testSynthesisStatusNeverMovesBackwards() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        _ = try transcript.addTranslation(utterance.id, text: "x")
        let voice = VoiceSelection(slot: .generic)
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: voice, status: .generating, route: .headphones))
        XCTAssertThrowsError(try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: voice, status: .queued, route: .headphones)))
        XCTAssertThrowsError(try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: VoiceSelection(slot: .remote), status: .played, route: .headphones)), "Voice cannot change")
        XCTAssertThrowsError(try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: voice, status: .played, route: .virtualMicrophone)), "Route cannot change")
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: voice, status: .played, route: .headphones, playback: TimeRange(start: 2, end: 3)))
        XCTAssertThrowsError(try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: voice, status: .failed, route: .headphones)), "A terminal state is final")
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 2, translationRev: 1, voice: voice, status: .queued, route: .headphones))
    }

    func testManifestRoundTripAndValidation() throws {
        var manifest = Fixtures.manifest(saving: .audioAndTranscript, consent: Fixtures.fullConsent)
        manifest.audioChunks.append(AudioChunk(file: "audio/mic-0001.caf", track: .mic, start: 0, frames: 48_000))
        manifest.gaps.append(Gap(track: .call, start: 12, end: 14.5, reason: .paused))
        try manifest.validate()
        let data = try SessionJSON.encoder(pretty: true).encode(manifest)
        let decoded = try SessionJSON.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.audioChunks.first?.codec, "alac")
        manifest.schemaVersion = 2
        XCTAssertThrowsError(try manifest.validate())
        XCTAssertThrowsError(try SessionManifest(languages: Languages(me: "en", other: "en"), saving: .none).validate())
        XCTAssertThrowsError(try SessionManifest(languages: Languages(me: "english!", other: "es"), saving: .none).validate())
        for bad in ["/tmp/x.caf", "../x.caf", "audio/../x.caf", "mic.caf"] {
            var escaped = Fixtures.manifest()
            escaped.audioChunks = [AudioChunk(file: bad, track: .mic, start: 0, frames: 1)]
            XCTAssertThrowsError(try escaped.validate(), bad)
        }
    }
}
