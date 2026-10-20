import XCTest
@testable import TranslateCore

final class RevisionLinkageTests: XCTestCase {
    func testSpokenTranslationSurvivesLaterCorrections() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        _ = try transcript.addTranslation(utterance.id, text: "Hi, my name is Anna.", provider: "mt-test")
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: VoiceSelection(slot: .generic), status: .queued, route: .headphones))
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: VoiceSelection(slot: .generic), status: .played, route: .headphones, playback: TimeRange(start: 14, end: 16)))

        // The user corrects the source and a new translation follows.
        _ = try transcript.reviseSource(utterance.id, text: "Hola, me llamo Anna.")
        _ = try transcript.addTranslation(utterance.id, text: "Hi, my name is Anna, with two n's.", provider: "mt-test")

        let current = try XCTUnwrap(transcript[utterance.id])
        XCTAssertEqual(current.currentSourceRevision, 2)
        XCTAssertEqual(current.currentTranslation?.rev, 2)
        XCTAssertEqual(current.currentTranslation?.sourceRev, 2)
        XCTAssertEqual(current.spokenText, "Hi, my name is Anna.", "What was spoken is the historical record")
        XCTAssertEqual(current.synthesis.first?.translationRev, 1)
        XCTAssertTrue(current.translationIsCurrent(2))
        XCTAssertFalse(current.translationIsCurrent(1))
    }

    func testSynthesisCannotChangeWhichTranslationItSpoke() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        _ = try transcript.addTranslation(utterance.id, text: "one")
        _ = try transcript.addTranslation(utterance.id, text: "two")
        _ = try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 1, voice: VoiceSelection(slot: .local), status: .played, route: .virtualMicrophone))
        XCTAssertThrowsError(try transcript.recordSynthesis(utterance.id, SynthesisAttempt(attempt: 1, translationRev: 2, voice: VoiceSelection(slot: .local), status: .played, route: .virtualMicrophone)))
    }

    func testTranslationMustCiteExistingSourceRevision() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        XCTAssertThrowsError(try transcript.addTranslation(utterance.id, text: "x", sourceRev: 2))
        XCTAssertNoThrow(try transcript.addTranslation(utterance.id, text: "x", sourceRev: 1))
    }

    func testSpeakerCorrectionKeepsIdentifier() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        let payload = try transcript.reviseSpeaker(utterance.id, speaker: .other, label: "Ana")
        guard case .speakerRevised(let revision) = payload else { return XCTFail("Expected a speaker revision") }
        XCTAssertEqual(revision.label, "Ana")
        XCTAssertEqual(transcript.order, [utterance.id])
        XCTAssertEqual(transcript[utterance.id]?.speakerLabel, "Ana")
        XCTAssertEqual(transcript[utterance.id]?.review, .reviewed)
    }

    func testDuplicateCommitAndLimitsAreRejected() throws {
        var transcript = Transcript()
        let utterance = Fixtures.utterance()
        _ = try transcript.commit(utterance)
        XCTAssertThrowsError(try transcript.commit(utterance))
        var long = Fixtures.utterance(start: 1, end: 2)
        long.sourceRevisions[0].text = String(repeating: "a", count: Bounds.maxTextBytes + 1)
        XCTAssertThrowsError(try transcript.commit(long))
        XCTAssertThrowsError(try transcript.commit(Fixtures.utterance(start: 0, end: Bounds.maxSessionSeconds + 1)))
    }

    func testSortedOrderUsesSourceTimeThenCommitOrder() throws {
        var transcript = Transcript()
        let late = Fixtures.utterance(start: 20, end: 21)
        let early = Fixtures.utterance(direction: .outgoing, start: 5, end: 6, text: "Hello")
        let tie = Fixtures.utterance(start: 5, end: 7, text: "Buenas")
        _ = try transcript.commit(late); _ = try transcript.commit(early); _ = try transcript.commit(tie)
        XCTAssertEqual(transcript.sorted.map(\.id), [early.id, tie.id, late.id])
    }
}
