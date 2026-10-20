import CryptoKit
import Foundation

/// One citation. Field-compatible with the shared evidence-item contract Voice's agent‑3 plans
/// (meeting/utterance/source revision, bounded quote, track and time, correction state, unknown speaker).
public struct EvidenceItem: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var utteranceID: UUID
    public var sourceRevision: Int
    public var quote: String                 // original language, bounded
    public var track: Track
    public var start: Double
    public var end: Double
    public var correctionState: ReviewState
    public var speaker: Speaker
    public var language: String
    public var translationRevision: Int?

    /// The default quote is the current source text, cut on a character boundary to the quote bound.
    /// `speaker` and `correctionState` are snapshots; a later speaker correction does not make the item
    /// stale, because the hash covers only (utterance, source revision).
    public init(meetingID: UUID, utterance: Utterance, quote: String? = nil, translationRevision: Int? = nil) {
        self.meetingID = meetingID
        self.utteranceID = utterance.id
        self.sourceRevision = utterance.currentSourceRevision
        self.quote = quote ?? Self.bounded(utterance.currentSourceText, maxBytes: Bounds.maxQuoteBytes)
        self.track = utterance.track
        self.start = utterance.source.start
        self.end = utterance.source.end
        self.correctionState = utterance.review
        self.speaker = utterance.speaker
        self.language = utterance.sourceLanguage
        self.translationRevision = translationRevision
    }

    static func bounded(_ text: String, maxBytes: Int) -> String {
        guard text.utf8Count > maxBytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8Count + String(character).utf8Count <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    public func validate() throws {
        guard !quote.isEmpty, quote.utf8Count <= Bounds.maxQuoteBytes else { throw TranslateProblem("Evidence quote is empty or too long.") }
        guard sourceRevision >= 1, start.isFinite, end.isFinite, start <= end else { throw TranslateProblem("Invalid evidence item.") }
    }

    /// True while the cited revision is still the utterance's current one.
    public func isCurrent(in transcript: Transcript) -> Bool {
        transcript[utteranceID]?.currentSourceRevision == sourceRevision
    }
}

public enum NoteKind: String, Codable, Sendable { case summary, topic, decision, action, question }
public enum NoteStatus: String, Codable, Sendable { case proposed, agreed }

/// A generated note. Every factual item cites evidence; staleness is per item, never per transcript.
public struct NoteItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: NoteKind
    public var text: String
    public var status: NoteStatus
    public var owner: String?
    public var due: String?
    public var uncertain: Bool
    public var evidence: [EvidenceItem]
    public var evidenceHash: String
    public var stale: Bool

    public init(id: UUID = UUID(), kind: NoteKind, text: String, status: NoteStatus = .proposed, owner: String? = nil, due: String? = nil,
                uncertain: Bool = false, evidence: [EvidenceItem]) {
        self.id = id; self.kind = kind; self.text = text; self.status = status; self.owner = owner; self.due = due
        self.uncertain = uncertain; self.evidence = evidence
        self.evidenceHash = Self.hash(evidence)
        self.stale = false
    }

    /// SHA-256 over the sorted (utterance, sourceRevision) pairs, so the hash changes only when a cited revision does.
    public static func hash(_ evidence: [EvidenceItem]) -> String {
        let pairs = evidence.map { "\($0.utteranceID.uuidString.lowercased()):\($0.sourceRevision)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(pairs.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        guard !text.isEmpty, text.utf8Count <= Bounds.maxTextBytes else { throw TranslateProblem("Note text is empty or too long.") }
        guard evidenceHash == Self.hash(evidence) else { throw TranslateProblem("Note evidence hash does not match its citations.") }
        guard kind == .summary || !evidence.isEmpty else { throw TranslateProblem("A factual note needs evidence.") }
        try evidence.forEach { try $0.validate() }
    }

    /// Stale when any cited utterance is missing or has moved past the cited source revision.
    public func isStale(in transcript: Transcript) -> Bool {
        evidence.contains { !$0.isCurrent(in: transcript) }
    }
}

public struct GeneratedNotes: Codable, Equatable, Sendable {
    public var provider: ProviderRecord
    public var generatedAt: Date
    public var items: [NoteItem]
    public init(provider: ProviderRecord, generatedAt: Date = Date(), items: [NoteItem]) {
        self.provider = provider; self.generatedAt = generatedAt; self.items = items
    }
}

/// `notes.json`. "My thoughts" stay separate from generated content and survive regeneration.
public struct Notebook: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var thoughts: String
    public var generated: GeneratedNotes?

    public init(thoughts: String = "", generated: GeneratedNotes? = nil) {
        self.schemaVersion = Bounds.schemaVersion; self.thoughts = thoughts; self.generated = generated
    }

    public func validate() throws {
        guard schemaVersion == Bounds.schemaVersion else { throw TranslateProblem("Unsupported notes schema version.") }
        guard thoughts.utf8Count <= 64 * 1024 else { throw TranslateProblem("Thoughts are too long.") }
        try generated?.items.forEach { try $0.validate() }
    }

    /// Marks each item stale or current against the transcript as it is now. Nothing else changes.
    public mutating func refreshStaleness(against transcript: Transcript) {
        guard var generated else { return }
        for index in generated.items.indices { generated.items[index].stale = generated.items[index].isStale(in: transcript) }
        self.generated = generated
    }

    /// Regeneration may only replace generated notes when every citation names a current revision.
    /// Personal thoughts are preserved by construction: they are not part of `generated`.
    public mutating func replaceGenerated(with notes: GeneratedNotes, against transcript: Transcript) throws {
        for item in notes.items {
            try item.validate()
            guard !item.isStale(in: transcript) else { throw TranslateProblem("Generated notes cite a source revision that has changed. Review and regenerate.") }
        }
        generated = notes
    }
}
