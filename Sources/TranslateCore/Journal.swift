import Foundation

/// Journal event types. The string values are the on-disk `type` field.
public enum JournalEventType: String, Codable, Sendable, CaseIterable {
    case utteranceCommitted = "utterance.committed"
    case sourceRevised = "source.revised"
    case translationAdded = "translation.added"
    case synthesisStatus = "synthesis.status"
    case speakerRevised = "speaker.revised"
    case spanMarked = "span.marked"
    case gap = "gap"
    case consentChanged = "consent.changed"
    case voiceReady = "voice.ready"
    case recordingPaused = "recording.paused"
    case recordingResumed = "recording.resumed"
    case sessionState = "session.state"
}

public struct SpeakerRevision: Codable, Equatable, Sendable {
    public var speaker: Speaker
    public var label: String?
    public init(speaker: Speaker, label: String? = nil) { self.speaker = speaker; self.label = label }
}

public struct VoiceReady: Codable, Equatable, Sendable {
    public var slot: VoiceSlot
    public var revision: Int
    public init(slot: VoiceSlot, revision: Int) { self.slot = slot; self.revision = revision }
}

public struct SessionStateChange: Codable, Equatable, Sendable {
    public var state: SessionState
    public init(state: SessionState) { self.state = state }
}

private struct EmptyPayload: Codable {}

/// One append-only, sequence-numbered line of `journal.jsonl`.
public struct JournalEvent: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case committed(Utterance)
        case sourceRevised(SourceRevision)
        case translationAdded(Translation)
        case synthesisStatus(SynthesisAttempt)
        case speakerRevised(SpeakerRevision)
        case spanMarked(Span)
        case gap(Gap)
        case consentChanged(Consent)
        case voiceReady(VoiceReady)
        case recordingPaused
        case recordingResumed
        case sessionState(SessionStateChange)

        public var type: JournalEventType {
            switch self {
            case .committed: return .utteranceCommitted
            case .sourceRevised: return .sourceRevised
            case .translationAdded: return .translationAdded
            case .synthesisStatus: return .synthesisStatus
            case .speakerRevised: return .speakerRevised
            case .spanMarked: return .spanMarked
            case .gap: return .gap
            case .consentChanged: return .consentChanged
            case .voiceReady: return .voiceReady
            case .recordingPaused: return .recordingPaused
            case .recordingResumed: return .recordingResumed
            case .sessionState: return .sessionState
            }
        }
        /// Payloads that change the transcript carry an utterance ID; the rest do not.
        public var touchesTranscript: Bool {
            switch self {
            case .committed, .sourceRevised, .translationAdded, .synthesisStatus, .speakerRevised, .spanMarked: return true
            default: return false
            }
        }
    }

    public var seq: UInt64
    public var at: Double              // session clock seconds
    public var utterance: UUID?
    public var payload: Payload

    public init(seq: UInt64, at: Double, utterance: UUID?, payload: Payload) {
        self.seq = seq; self.at = at; self.utterance = utterance; self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case seq, at, type, utterance, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(UInt64.self, forKey: .seq)
        at = try container.decode(Double.self, forKey: .at)
        utterance = try container.decodeIfPresent(UUID.self, forKey: .utterance)
        switch try container.decode(JournalEventType.self, forKey: .type) {
        case .utteranceCommitted: payload = .committed(try container.decode(Utterance.self, forKey: .data))
        case .sourceRevised: payload = .sourceRevised(try container.decode(SourceRevision.self, forKey: .data))
        case .translationAdded: payload = .translationAdded(try container.decode(Translation.self, forKey: .data))
        case .synthesisStatus: payload = .synthesisStatus(try container.decode(SynthesisAttempt.self, forKey: .data))
        case .speakerRevised: payload = .speakerRevised(try container.decode(SpeakerRevision.self, forKey: .data))
        case .spanMarked: payload = .spanMarked(try container.decode(Span.self, forKey: .data))
        case .gap: payload = .gap(try container.decode(Gap.self, forKey: .data))
        case .consentChanged: payload = .consentChanged(try container.decode(Consent.self, forKey: .data))
        case .voiceReady: payload = .voiceReady(try container.decode(VoiceReady.self, forKey: .data))
        case .recordingPaused: payload = .recordingPaused
        case .recordingResumed: payload = .recordingResumed
        case .sessionState: payload = .sessionState(try container.decode(SessionStateChange.self, forKey: .data))
        }
        guard at.isFinite, at >= 0 else { throw TranslateProblem("Invalid journal clock.") }
        if case .committed(let committed) = payload { guard committed.id == utterance else { throw TranslateProblem("Committed utterance ID does not match the event.") } }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(at, forKey: .at)
        try container.encodeIfPresent(utterance, forKey: .utterance)
        try container.encode(payload.type, forKey: .type)
        switch payload {
        case .committed(let value): try container.encode(value, forKey: .data)
        case .sourceRevised(let value): try container.encode(value, forKey: .data)
        case .translationAdded(let value): try container.encode(value, forKey: .data)
        case .synthesisStatus(let value): try container.encode(value, forKey: .data)
        case .speakerRevised(let value): try container.encode(value, forKey: .data)
        case .spanMarked(let value): try container.encode(value, forKey: .data)
        case .gap(let value): try container.encode(value, forKey: .data)
        case .consentChanged(let value): try container.encode(value, forKey: .data)
        case .voiceReady(let value): try container.encode(value, forKey: .data)
        case .recordingPaused, .recordingResumed: try container.encode(EmptyPayload(), forKey: .data)
        case .sessionState(let value): try container.encode(value, forKey: .data)
        }
    }

    /// One line, newline-terminated, bounded. Strings are JSON-escaped so no raw newline can appear inside.
    public func line() throws -> Data {
        var data = try SessionJSON.encoder().encode(self)
        guard !data.contains(10) else { throw TranslateProblem("Journal line contains a newline.") }
        data.append(10)
        guard data.count <= Bounds.maxJournalLineBytes else { throw TranslateProblem("Journal line exceeds its limit.") }
        return data
    }
}

/// Where journal lines go. The app provides a file sink; tests use memory.
public protocol JournalSink: AnyObject {
    func append(_ line: Data) throws
    func flush() throws
}

public final class InMemoryJournalSink: JournalSink {
    public private(set) var bytes = Data()
    public private(set) var flushes = 0
    public var failNextAppend = false
    public init() {}
    public func append(_ line: Data) throws {
        if failNextAppend { failNextAppend = false; throw TranslateProblem("Simulated write failure.") }
        bytes.append(line)
    }
    public func flush() throws { flushes += 1 }
}

/// Appends to a regular owner-only file; `flush` forces the bytes to disk.
public final class FileJournalSink: JournalSink {
    private let handle: FileHandle

    /// `validBytes` is the length of the complete, valid prefix that `JournalReader.recover` reported;
    /// anything after it (a partial line left by a crash) is cut before the first append.
    public init(url: URL, validBytes: UInt64? = nil) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TranslateProblem("Could not create the journal file.")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        if let validBytes { try handle.truncate(atOffset: validBytes) }
        try handle.seekToEnd()
    }
    public func append(_ line: Data) throws { try handle.write(contentsOf: line) }
    public func flush() throws { try handle.synchronize() }
    deinit { try? handle.close() }
}

/// Sequences events and writes only what the persistence policy allows.
/// With `saving == .none` nothing ever reaches a sink; the live transcript stays in memory.
///
/// Writing is two-phase so the transcript can never get ahead of the record: `prepare` encodes and
/// bound-checks before the matching transcript mutation runs, `append` writes after it succeeded.
/// After a sink failure the journal refuses further writes; the saved record ends at `lastSeq`.
public final class Journal {
    public struct Prepared {
        public let event: JournalEvent
        fileprivate let line: Data
    }

    public var policy: PersistencePolicy
    public private(set) var lastSeq: UInt64
    public private(set) var suppressed = 0
    public private(set) var failure: TranslateProblem?
    private let sink: JournalSink

    public init(sink: JournalSink, policy: PersistencePolicy, lastSeq: UInt64 = 0) {
        self.sink = sink; self.policy = policy; self.lastSeq = lastSeq
    }

    /// Opens or resumes a file journal: recovers the complete lines, cuts any partial tail and seeds
    /// the sequence from the last recovered event. Refused for a session that saves nothing.
    public static func open(url: URL, policy: PersistencePolicy) throws -> (journal: Journal, recovery: JournalReader.Recovery) {
        guard policy.saving != .none else { throw TranslateProblem("A session that saves nothing has no journal.") }
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        let recovery = JournalReader.recover(existing)
        let sink = try FileJournalSink(url: url, validBytes: UInt64(recovery.validBytes))
        return (Journal(sink: sink, policy: policy, lastSeq: recovery.lastSeq), recovery)
    }

    /// Phase one: encode and bound-check without writing. Nil means the policy suppresses this event.
    public func prepare(_ payload: JournalEvent.Payload, at: Double, utterance: UUID? = nil) throws -> Prepared? {
        if let failure { throw failure }
        if payload.touchesTranscript { guard utterance != nil else { throw TranslateProblem("Transcript events need an utterance ID.") } }
        if case .committed(let committed) = payload { guard committed.id == utterance else { throw TranslateProblem("Committed utterance ID does not match the event.") } }
        guard policy.allows(payload.type) else { suppressed += 1; return nil }
        let event = JournalEvent(seq: lastSeq + 1, at: at, utterance: utterance, payload: payload)
        return Prepared(event: event, line: try event.line())
    }

    /// Phase two: write a prepared event. Returns nil for a suppressed one.
    @discardableResult
    public func append(_ prepared: Prepared?) throws -> JournalEvent? {
        guard let prepared else { return nil }
        if let failure { throw failure }
        guard prepared.event.seq == lastSeq + 1 else { throw TranslateProblem("Prepared event is out of sequence.") }
        do { try sink.append(prepared.line) } catch {
            failure = TranslateProblem("The saved record stopped after a write failure.")
            throw error
        }
        lastSeq = prepared.event.seq
        return prepared.event
    }

    /// Both phases at once, for events with no matching transcript mutation.
    @discardableResult
    public func record(_ payload: JournalEvent.Payload, at: Double, utterance: UUID? = nil) throws -> JournalEvent? {
        try append(try prepare(payload, at: at, utterance: utterance))
    }

    public func flush() throws { try sink.flush() }
}

/// Reads a journal back. Only complete, newline-terminated lines count; a truncated tail is
/// ignored, and parsing stops at the first malformed line or the first break in the contiguous
/// sequence (the writer never skips a number, so a gap means a lost or reordered line).
public enum JournalReader {
    public struct Recovery: Equatable, Sendable {
        public var events: [JournalEvent]
        public var ignoredTail: Bool
        public var stoppedAtLine: Int?
        /// Length of the prefix holding every accepted line; a resumed journal is cut here before appending.
        public var validBytes: Int
        public var lastSeq: UInt64 { events.last?.seq ?? 0 }
    }

    public static func recover(_ data: Data) -> Recovery {
        var events: [JournalEvent] = []
        var ignoredTail = false
        var stoppedAtLine: Int?
        let decoder = SessionJSON.decoder()
        var start = data.startIndex
        var accepted = data.startIndex
        var lineNumber = 0
        var lastSeq: UInt64 = 0
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 10) else { ignoredTail = true; break }
            lineNumber += 1
            let line = data[start..<newline]
            start = data.index(after: newline)
            if line.isEmpty { accepted = start; continue }
            guard line.count <= Bounds.maxJournalLineBytes, let event = try? decoder.decode(JournalEvent.self, from: line), event.seq == lastSeq + 1 else {
                stoppedAtLine = lineNumber
                break
            }
            lastSeq = event.seq
            events.append(event)
            accepted = start
        }
        return Recovery(events: events, ignoredTail: ignoredTail, stoppedAtLine: stoppedAtLine, validBytes: accepted - data.startIndex)
    }
}
