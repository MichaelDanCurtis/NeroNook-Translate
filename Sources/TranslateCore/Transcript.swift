import Foundation

/// The in-memory transcript. Every mutation returns the journal payload that describes it, and the
/// journal's two-phase `prepare`/`append` lets the app encode the event before mutating, so the
/// transcript never gets ahead of the saved record. Replay uses the same mutation code path.
public struct Transcript: Equatable, Sendable {
    public private(set) var utterances: [UUID: Utterance] = [:]
    public private(set) var order: [UUID] = []

    public init() {}

    public var count: Int { order.count }
    public subscript(id: UUID) -> Utterance? { utterances[id] }
    /// Utterances by source start time, then commit order.
    public var sorted: [Utterance] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return utterances.values.sorted {
            if $0.source.start != $1.source.start { return $0.source.start < $1.source.start }
            return (index[$0.id] ?? 0) < (index[$1.id] ?? 0)
        }
    }

    // MARK: Mutations

    public mutating func commit(_ utterance: Utterance) throws -> JournalEvent.Payload {
        try utterance.validate()
        guard utterances[utterance.id] == nil else { throw TranslateProblem("Utterance already committed.") }
        guard order.count < Bounds.maxUtterances else { throw TranslateProblem("Session has too many utterances.") }
        guard utterance.source.end <= Bounds.maxSessionSeconds else { throw TranslateProblem("Session timeline exceeds its limit.") }
        utterances[utterance.id] = utterance
        order.append(utterance.id)
        return .committed(utterance)
    }

    public mutating func reviseSource(_ id: UUID, text: String, origin: RevisionOrigin = .user, words: [Word]? = nil, at: Date = Date()) throws -> JournalEvent.Payload {
        guard var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
        let revision = SourceRevision(rev: utterance.currentSourceRevision + 1, origin: origin, text: text, words: words, at: at)
        utterance.sourceRevisions.append(revision)
        try utterance.validate()
        utterances[id] = utterance
        return .sourceRevised(revision)
    }

    public mutating func addTranslation(_ id: UUID, text: String, origin: RevisionOrigin = .mt, provider: String? = nil, sourceRev: Int? = nil, at: Date = Date()) throws -> JournalEvent.Payload {
        guard var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
        let translation = Translation(rev: utterance.translations.count + 1, sourceRev: sourceRev ?? utterance.currentSourceRevision,
                                      origin: origin, provider: provider, text: text, at: at)
        utterance.translations.append(translation)
        try utterance.validate()
        utterances[id] = utterance
        return .translationAdded(translation)
    }

    /// Status order: queued → generating → one terminal state. A terminal state never changes.
    private static func rank(_ status: SynthesisStatus) -> Int {
        switch status { case .queued: return 0; case .generating: return 1; default: return 2 }
    }

    /// Appends a new attempt, or advances the status of an existing attempt number. An attempt never
    /// changes which translation it spoke, its voice, or its route.
    public mutating func recordSynthesis(_ id: UUID, _ attempt: SynthesisAttempt) throws -> JournalEvent.Payload {
        guard var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
        if let index = utterance.synthesis.firstIndex(where: { $0.attempt == attempt.attempt }) {
            let existing = utterance.synthesis[index]
            guard existing.translationRev == attempt.translationRev else { throw TranslateProblem("A synthesis attempt cannot change which translation it spoke.") }
            guard existing.voice == attempt.voice, existing.route == attempt.route else { throw TranslateProblem("A synthesis attempt cannot change its voice or route.") }
            guard Self.rank(attempt.status) >= Self.rank(existing.status), Self.rank(existing.status) < 2 || existing.status == attempt.status else {
                throw TranslateProblem("Synthesis status cannot move backwards.")
            }
            utterance.synthesis[index] = attempt
        } else {
            guard attempt.attempt == utterance.synthesis.count + 1 else { throw TranslateProblem("Synthesis attempts must be numbered in order.") }
            utterance.synthesis.append(attempt)
        }
        try utterance.validate()
        utterances[id] = utterance
        return .synthesisStatus(attempt)
    }

    /// Speaker-label corrections never change the utterance ID.
    public mutating func reviseSpeaker(_ id: UUID, speaker: Speaker, label: String?) throws -> JournalEvent.Payload {
        guard var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
        utterance.speaker = speaker
        utterance.speakerLabel = label
        utterance.review = .reviewed
        try utterance.validate()
        utterances[id] = utterance
        return .speakerRevised(SpeakerRevision(speaker: speaker, label: label))
    }

    public mutating func markSpan(_ id: UUID, _ span: Span) throws -> JournalEvent.Payload {
        guard var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
        utterance.spans.append(span)
        try utterance.validate()
        utterances[id] = utterance
        return .spanMarked(span)
    }

    // MARK: Replay

    /// Applies one journaled payload. Non-transcript payloads are ignored here.
    public mutating func apply(_ payload: JournalEvent.Payload, utterance id: UUID?) throws {
        switch payload {
        case .committed(let utterance):
            guard utterance.id == id else { throw TranslateProblem("Committed utterance ID does not match the event.") }
            _ = try commit(utterance)
        case .sourceRevised(let revision):
            guard let id, var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
            guard revision.rev == utterance.currentSourceRevision + 1 else { throw TranslateProblem("Source revision out of order.") }
            utterance.sourceRevisions.append(revision); try utterance.validate(); utterances[id] = utterance
        case .translationAdded(let translation):
            guard let id, var utterance = utterances[id] else { throw TranslateProblem("Unknown utterance.") }
            guard translation.rev == utterance.translations.count + 1 else { throw TranslateProblem("Translation revision out of order.") }
            utterance.translations.append(translation); try utterance.validate(); utterances[id] = utterance
        case .synthesisStatus(let attempt):
            guard let id else { throw TranslateProblem("Unknown utterance.") }
            _ = try recordSynthesis(id, attempt)
        case .speakerRevised(let revision):
            guard let id else { throw TranslateProblem("Unknown utterance.") }
            _ = try reviseSpeaker(id, speaker: revision.speaker, label: revision.label)
        case .spanMarked(let span):
            guard let id else { throw TranslateProblem("Unknown utterance.") }
            _ = try markSpan(id, span)
        default:
            break
        }
    }

    public struct ReplaySummary: Equatable, Sendable {
        public var lastSeq: UInt64 = 0
        /// Set when an event could not apply; everything before it was replayed.
        public var stoppedAtSeq: UInt64?
        public var sessionState: SessionState?
        public var recordingPaused = false
        public var consent: Consent?
        public var gaps: [Gap] = []
        public var voicesReady: [VoiceReady] = []
        public init() {}
    }

    /// Rebuilds a transcript from recovered events. Stops at the first event that cannot apply and
    /// keeps the prefix, so a fault in the middle of a journal still recovers everything before it.
    public static func replay(_ events: [JournalEvent]) -> (Transcript, ReplaySummary) {
        var transcript = Transcript()
        var summary = ReplaySummary()
        for event in events {
            do { try transcript.apply(event.payload, utterance: event.utterance) } catch {
                summary.stoppedAtSeq = event.seq
                break
            }
            switch event.payload {
            case .gap(let gap): summary.gaps.append(gap)
            case .consentChanged(let consent): summary.consent = consent
            case .voiceReady(let ready): summary.voicesReady.append(ready)
            case .recordingPaused: summary.recordingPaused = true
            case .recordingResumed: summary.recordingPaused = false
            case .sessionState(let change): summary.sessionState = change.state
            default: break
            }
            summary.lastSeq = event.seq
        }
        return (transcript, summary)
    }
}
