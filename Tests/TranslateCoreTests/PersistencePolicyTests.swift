import XCTest
@testable import TranslateCore

final class PersistencePolicyTests: XCTestCase {
    func testEveryCombinationOfSavingConsentAndPause() throws {
        for saving in [SavingMode.none, .transcript, .audioAndTranscript] {
            for consent in [false, true] {
                for paused in [false, true] {
                    let policy = PersistencePolicy(saving: saving, recordingConsent: consent, recordingPaused: paused)
                    let sink = InMemoryJournalSink()
                    let journal = Journal(sink: sink, policy: policy)
                    let utterance = Fixtures.utterance()
                    try journal.record(.committed(utterance), at: 1, utterance: utterance.id)
                    try journal.record(.translationAdded(Translation(rev: 1, sourceRev: 1, origin: .mt, text: "x")), at: 1.5, utterance: utterance.id)
                    try journal.record(.gap(Gap(track: .call, start: 1, end: 2, reason: .paused)), at: 2)
                    try journal.record(.recordingPaused, at: 2)
                    try journal.record(.consentChanged(Consent()), at: 2.5)
                    try journal.record(.sessionState(SessionStateChange(state: .interrupted)), at: 3)
                    let recovered = JournalReader.recover(sink.bytes).events.map(\.payload.type)
                    let label = "\(saving)/consent=\(consent)/paused=\(paused)"

                    if saving == .none {
                        XCTAssertTrue(sink.bytes.isEmpty, "\(label): a session that saves nothing writes nothing")
                        XCTAssertEqual(journal.suppressed, 6, label)
                        XCTAssertFalse(policy.persistsAnything)
                    } else if !consent || paused {
                        XCTAssertEqual(recovered, [.gap, .recordingPaused, .consentChanged, .sessionState], "\(label): only the record's own state survives")
                        XCTAssertFalse(policy.persistsText, label); XCTAssertFalse(policy.persistsAudio, label)
                        XCTAssertEqual(journal.suppressed, 2, label)
                    } else {
                        XCTAssertEqual(recovered, [.utteranceCommitted, .translationAdded, .gap, .recordingPaused, .consentChanged, .sessionState], label)
                        XCTAssertTrue(policy.persistsText, label)
                        XCTAssertEqual(policy.persistsAudio, saving == .audioAndTranscript, label)
                    }
                }
            }
        }
    }

    func testWithdrawingRecordingAgreementIsStillJournaledInEitherOrder() throws {
        let sink = InMemoryJournalSink()
        let journal = Journal(sink: sink, policy: PersistencePolicy(saving: .audioAndTranscript, recordingConsent: true))
        var consent = ConsentState(Fixtures.fullConsent)
        let utterance = Fixtures.utterance()
        try journal.record(.committed(utterance), at: 1, utterance: utterance.id)

        // Policy updated first, then the event: the withdrawal must still be recorded.
        let withdrawal = consent.setRecording(false, at: Date(timeIntervalSince1970: 1_800_000_100))
        journal.policy.recordingConsent = false
        XCTAssertNotNil(try journal.record(withdrawal, at: 2))
        XCTAssertNil(try journal.record(.translationAdded(Translation(rev: 1, sourceRev: 1, origin: .mt, text: "x")), at: 3, utterance: utterance.id), "Content stops")
        XCTAssertNotNil(try journal.record(.sessionState(SessionStateChange(state: .saved)), at: 4), "The end of the record is still written")

        let events = JournalReader.recover(sink.bytes).events
        XCTAssertEqual(events.map(\.payload.type), [.utteranceCommitted, .consentChanged, .sessionState])
        guard case .consentChanged(let recorded) = events[1].payload else { return XCTFail() }
        XCTAssertEqual(recorded.recording, Grant(granted: false, at: Date(timeIntervalSince1970: 1_800_000_100)), "Withdrawal keeps its timestamp")
    }

    func testSavingNeedsRecordingAgreementButMatchingDoesNot() {
        XCTAssertNoThrow(try PersistencePolicy.validateStart(saving: .none, consent: Consent()))
        XCTAssertThrowsError(try PersistencePolicy.validateStart(saving: .transcript, consent: Consent()))
        XCTAssertThrowsError(try PersistencePolicy.validateStart(saving: .audioAndTranscript, consent: Consent(voiceMatching: Grant(granted: true))))
        XCTAssertNoThrow(try PersistencePolicy.validateStart(saving: .audioAndTranscript, consent: Consent(recording: Grant(granted: true))))
        XCTAssertFalse(LearningPolicy(consent: Consent(recording: Grant(granted: true))).mayLearnRemoteVoice, "Recording agreement does not imply voice matching")
        XCTAssertTrue(LearningPolicy(consent: Consent(voiceMatching: Grant(granted: true))).mayLearnRemoteVoice)
    }

    func testPauseCanChangeMidSessionAndSequenceStaysMonotonic() throws {
        let sink = InMemoryJournalSink()
        let journal = Journal(sink: sink, policy: PersistencePolicy(saving: .transcript, recordingConsent: true))
        let utterance = Fixtures.utterance()
        let first = try XCTUnwrap(try journal.record(.committed(utterance), at: 1, utterance: utterance.id))
        journal.policy.recordingPaused = true
        XCTAssertNil(try journal.record(.translationAdded(Translation(rev: 1, sourceRev: 1, origin: .mt, text: "x")), at: 2, utterance: utterance.id))
        let paused = try XCTUnwrap(try journal.record(.recordingPaused, at: 2))
        let ready = try XCTUnwrap(try journal.record(.voiceReady(VoiceReady(slot: .remote, revision: 1)), at: 2.5), "Voice state is not content")
        journal.policy.recordingPaused = false
        let resumed = try XCTUnwrap(try journal.record(.recordingResumed, at: 3))
        XCTAssertEqual([first.seq, paused.seq, ready.seq, resumed.seq], [1, 2, 3, 4], "Suppressed events do not consume sequence numbers")
        XCTAssertEqual(journal.lastSeq, 4)
    }

    func testRemoteVoiceIsDiscardedUnlessKeepingIsConfirmed() {
        XCTAssertEqual(RemoteVoiceRetention.atSessionEnd(saveRequested: false, keepConfirmed: false, profileID: "p"), .discard)
        XCTAssertEqual(RemoteVoiceRetention.atSessionEnd(saveRequested: true, keepConfirmed: false, profileID: "p"), .discard)
        XCTAssertEqual(RemoteVoiceRetention.atSessionEnd(saveRequested: true, keepConfirmed: true, profileID: "p"), .keep(profileID: "p"))
    }

    func testConsentChangesAreJournaledWithTimestamps() throws {
        var state = ConsentState(Consent())
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .consentChanged(let consent) = state.setVoiceMatching(true, at: at) else { return XCTFail() }
        XCTAssertEqual(consent.voiceMatching, Grant(granted: true, at: at))
        XCTAssertFalse(consent.recording.granted)
        let later = at.addingTimeInterval(60)
        guard case .consentChanged(let revoked) = state.setVoiceMatching(false, at: later) else { return XCTFail() }
        XCTAssertEqual(revoked.voiceMatching, Grant(granted: false, at: later))
    }

    func testTranscriptEventsRequireAMatchingUtteranceID() {
        let journal = Journal(sink: InMemoryJournalSink(), policy: PersistencePolicy(saving: .transcript, recordingConsent: true))
        let utterance = Fixtures.utterance()
        XCTAssertThrowsError(try journal.record(.committed(utterance), at: 1, utterance: nil))
        XCTAssertThrowsError(try journal.record(.committed(utterance), at: 1, utterance: UUID()), "A committed event must carry its own utterance's ID")
    }
}
