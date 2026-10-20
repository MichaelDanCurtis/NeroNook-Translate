import XCTest
@testable import TranslateCore

final class FileJournalSinkTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("journal.jsonl") }
    private let policy = PersistencePolicy(saving: .transcript, recordingConsent: true)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("translate-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions() throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testOpenCreatesOwnerOnlyFileAndResumesTheSequence() throws {
        let utterance = Fixtures.utterance()
        do {
            let (journal, recovery) = try Journal.open(url: url, policy: policy)
            XCTAssertTrue(recovery.events.isEmpty)
            try journal.record(.committed(utterance), at: 1, utterance: utterance.id)
            try journal.flush()
        }
        XCTAssertEqual(try permissions(), 0o600)

        let (journal, recovery) = try Journal.open(url: url, policy: policy)
        XCTAssertEqual(recovery.events.count, 1)
        XCTAssertEqual(journal.lastSeq, 1)
        try journal.record(.sessionState(SessionStateChange(state: .saved)), at: 2)
        try journal.flush()

        let final = JournalReader.recover(try Data(contentsOf: url))
        XCTAssertEqual(final.events.map(\.seq), [1, 2])
        XCTAssertFalse(final.ignoredTail)
        let (transcript, summary) = Transcript.replay(final.events)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(summary.sessionState, .saved)
    }

    func testResumingAfterACrashCutsThePartialLineInsteadOfAppendingToIt() throws {
        let utterance = Fixtures.utterance()
        let (first, _) = try Journal.open(url: url, policy: policy)
        try first.record(.committed(utterance), at: 1, utterance: utterance.id)
        try first.flush()
        // A crash mid-write leaves a partial line with no newline.
        let partial = FileHandle(forWritingAtPath: url.path)!
        try partial.seekToEnd()
        try partial.write(contentsOf: Data("{\"seq\":2,\"at\":2,\"type\":\"session.sta".utf8))
        try partial.close()

        let (resumed, recovery) = try Journal.open(url: url, policy: policy)
        XCTAssertEqual(recovery.events.count, 1)
        XCTAssertTrue(recovery.ignoredTail)
        XCTAssertEqual(resumed.lastSeq, 1)
        try resumed.record(.sessionState(SessionStateChange(state: .interrupted)), at: 2)
        try resumed.record(.sessionState(SessionStateChange(state: .saved)), at: 3)
        try resumed.flush()

        let final = JournalReader.recover(try Data(contentsOf: url))
        XCTAssertEqual(final.events.map(\.seq), [1, 2, 3], "Later events are reachable because the partial line was cut")
        XCTAssertNil(final.stoppedAtLine)
        XCTAssertFalse(final.ignoredTail)
    }

    func testResumingAfterACorruptLineKeepsOnlyTheValidPrefix() throws {
        let utterance = Fixtures.utterance()
        let (first, _) = try Journal.open(url: url, policy: policy)
        try first.record(.committed(utterance), at: 1, utterance: utterance.id)
        try first.record(.sessionState(SessionStateChange(state: .interrupted)), at: 2)
        try first.flush()
        var lines = try Data(contentsOf: url).split(separator: 10, omittingEmptySubsequences: false)
        lines[1] = Data("garbage".utf8)
        try Data(lines.joined(separator: Data([10]))).write(to: url)

        let (resumed, recovery) = try Journal.open(url: url, policy: policy)
        XCTAssertEqual(recovery.stoppedAtLine, 2)
        XCTAssertEqual(resumed.lastSeq, 1)
        try resumed.record(.sessionState(SessionStateChange(state: .saved)), at: 3)
        let final = JournalReader.recover(try Data(contentsOf: url))
        XCTAssertEqual(final.events.map(\.seq), [1, 2])
        XCTAssertNil(final.stoppedAtLine)
    }

    func testOpenTightensLoosePermissions() throws {
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        _ = try Journal.open(url: url, policy: policy)
        XCTAssertEqual(try permissions(), 0o600)
    }

    func testNothingSavedRefusesToOpenAJournal() throws {
        XCTAssertThrowsError(try Journal.open(url: url, policy: PersistencePolicy(saving: .none, recordingConsent: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "No file is created for a session that saves nothing")
    }
}
