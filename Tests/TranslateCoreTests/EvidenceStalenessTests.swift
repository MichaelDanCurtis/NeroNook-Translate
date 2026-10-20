import XCTest
@testable import TranslateCore

final class EvidenceStalenessTests: XCTestCase {
    private func transcriptWithTwo() throws -> (Transcript, Utterance, Utterance) {
        var transcript = Transcript()
        let a = Fixtures.utterance(start: 1, end: 3, text: "Entregamos el viernes.")
        let b = Fixtures.utterance(direction: .outgoing, start: 4, end: 6, text: "Friday works for me.")
        _ = try transcript.commit(a); _ = try transcript.commit(b)
        return (transcript, a, b)
    }

    func testCorrectionMarksOnlyDependentItemsStale() throws {
        var (transcript, a, b) = try transcriptWithTwo()
        let meeting = UUID()
        let aboutA = NoteItem(kind: .decision, text: "Delivery on Friday", status: .agreed, evidence: [EvidenceItem(meetingID: meeting, utterance: a)])
        let aboutB = NoteItem(kind: .action, text: "Confirm Friday", evidence: [EvidenceItem(meetingID: meeting, utterance: b)])
        let aboutBoth = NoteItem(kind: .topic, text: "Scheduling", evidence: [EvidenceItem(meetingID: meeting, utterance: a), EvidenceItem(meetingID: meeting, utterance: b)])
        var notebook = Notebook(thoughts: "Ask about the invoice.", generated: GeneratedNotes(provider: ProviderRecord(id: "test"), items: [aboutA, aboutB, aboutBoth]))
        try notebook.validate()
        notebook.refreshStaleness(against: transcript)
        XCTAssertEqual(notebook.generated?.items.map(\.stale), [false, false, false])

        _ = try transcript.reviseSource(a.id, text: "Entregamos el jueves.")
        notebook.refreshStaleness(against: transcript)
        XCTAssertEqual(notebook.generated?.items.map(\.stale), [true, false, true], "Only items citing the corrected utterance go stale")
        XCTAssertEqual(notebook.thoughts, "Ask about the invoice.", "Personal thoughts are untouched")
    }

    func testHashDependsOnlyOnCitedRevisions() throws {
        let (_, a, b) = try transcriptWithTwo()
        let meeting = UUID()
        let one = NoteItem.hash([EvidenceItem(meetingID: meeting, utterance: a), EvidenceItem(meetingID: meeting, utterance: b)])
        let reordered = NoteItem.hash([EvidenceItem(meetingID: meeting, utterance: b), EvidenceItem(meetingID: meeting, utterance: a)])
        XCTAssertEqual(one, reordered)
        var revised = a
        revised.sourceRevisions.append(SourceRevision(rev: 2, origin: .user, text: "changed"))
        XCTAssertNotEqual(one, NoteItem.hash([EvidenceItem(meetingID: meeting, utterance: revised), EvidenceItem(meetingID: meeting, utterance: b)]))
        var differentQuote = EvidenceItem(meetingID: meeting, utterance: a)
        differentQuote.quote = "a shorter quote"
        XCTAssertEqual(NoteItem.hash([differentQuote]), NoteItem.hash([EvidenceItem(meetingID: meeting, utterance: a)]), "The quote text is not part of the hash")
    }

    func testRegenerationIsRejectedWhenItCitesAChangedRevision() throws {
        var (transcript, a, _) = try transcriptWithTwo()
        let meeting = UUID()
        var notebook = Notebook(thoughts: "keep me")
        let staleCitation = EvidenceItem(meetingID: meeting, utterance: a)           // cites rev 1
        _ = try transcript.reviseSource(a.id, text: "Entregamos el jueves.")        // now rev 2
        let stale = GeneratedNotes(provider: ProviderRecord(id: "test"), items: [NoteItem(kind: .decision, text: "x", evidence: [staleCitation])])
        XCTAssertThrowsError(try notebook.replaceGenerated(with: stale, against: transcript))
        XCTAssertNil(notebook.generated)
        let fresh = GeneratedNotes(provider: ProviderRecord(id: "test"), items: [NoteItem(kind: .decision, text: "x", evidence: [EvidenceItem(meetingID: meeting, utterance: transcript[a.id]!)])])
        XCTAssertNoThrow(try notebook.replaceGenerated(with: fresh, against: transcript))
        XCTAssertEqual(notebook.thoughts, "keep me")
        XCTAssertEqual(notebook.generated?.items.first?.evidence.first?.sourceRevision, 2)
    }

    func testValidationRules() throws {
        let (_, a, _) = try transcriptWithTwo()
        let meeting = UUID()
        var tampered = NoteItem(kind: .action, text: "x", evidence: [EvidenceItem(meetingID: meeting, utterance: a)])
        tampered.evidence[0].sourceRevision = 3
        XCTAssertThrowsError(try tampered.validate(), "Hash no longer matches the citations")
        XCTAssertThrowsError(try NoteItem(kind: .decision, text: "no evidence", evidence: []).validate())
        XCTAssertNoThrow(try NoteItem(kind: .summary, text: "summaries may stand alone", evidence: []).validate())
        var longQuote = EvidenceItem(meetingID: meeting, utterance: a)
        longQuote.quote = String(repeating: "q", count: Bounds.maxQuoteBytes + 1)
        XCTAssertThrowsError(try longQuote.validate())
        let item = NoteItem(kind: .action, text: "call back", owner: nil, due: nil, uncertain: true, evidence: [EvidenceItem(meetingID: meeting, utterance: a)])
        XCTAssertTrue(item.uncertain)
        XCTAssertEqual(item.evidence.first?.speaker, .other)
        XCTAssertEqual(item.evidence.first?.language, "es-ES")
    }

    func testDefaultQuoteIsCutOnACharacterBoundary() throws {
        var transcript = Transcript()
        let long = Fixtures.utterance(text: String(repeating: "ñ", count: 600))   // 1,200 bytes
        _ = try transcript.commit(long)
        let item = EvidenceItem(meetingID: UUID(), utterance: long)
        XCTAssertNoThrow(try item.validate())
        XCTAssertLessThanOrEqual(item.quote.utf8.count, Bounds.maxQuoteBytes)
        XCTAssertEqual(item.quote.count, 256, "Two-byte characters: 256 of them fit in 512 bytes, never a split one")
    }

    func testNotebookRoundTrip() throws {
        let (_, a, _) = try transcriptWithTwo()
        let notebook = Notebook(thoughts: "t", generated: GeneratedNotes(provider: ProviderRecord(id: "apple-foundation", model: "default"), generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                                      items: [NoteItem(kind: .question, text: "When?", evidence: [EvidenceItem(meetingID: UUID(), utterance: a)])]))
        let data = try SessionJSON.encoder(pretty: true).encode(notebook)
        XCTAssertEqual(try SessionJSON.decoder().decode(Notebook.self, from: data), notebook)
    }
}
