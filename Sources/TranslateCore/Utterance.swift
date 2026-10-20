import Foundation

public struct Word: Codable, Equatable, Sendable {
    public var t: String
    public var s: Double
    public var e: Double
    public init(_ text: String, start: Double, end: Double) { t = text; s = start; e = end }
}

/// Source text as recognized or later corrected. Revisions are append-only.
public struct SourceRevision: Codable, Equatable, Sendable {
    public var rev: Int
    public var origin: RevisionOrigin
    public var text: String
    public var words: [Word]?
    public var at: Date
    public init(rev: Int, origin: RevisionOrigin, text: String, words: [Word]? = nil, at: Date = Date()) {
        self.rev = rev; self.origin = origin; self.text = text; self.words = words; self.at = at
    }
}

/// A translation of one specific source revision. Also append-only.
public struct Translation: Codable, Equatable, Sendable {
    public var rev: Int
    public var sourceRev: Int
    public var origin: RevisionOrigin
    public var provider: String?
    public var text: String
    public var at: Date
    public init(rev: Int, sourceRev: Int, origin: RevisionOrigin, provider: String? = nil, text: String, at: Date = Date()) {
        self.rev = rev; self.sourceRev = sourceRev; self.origin = origin; self.provider = provider; self.text = text; self.at = at
    }
}

public struct VoiceSelection: Codable, Equatable, Sendable {
    public var slot: VoiceSlot
    public var revision: Int
    public var blend: Double?
    public init(slot: VoiceSlot, revision: Int = 1, blend: Double? = nil) { self.slot = slot; self.revision = revision; self.blend = blend }
}

/// What the system actually did with one translation revision. Once `played`, the
/// translation revision it names is the historical record of what was spoken.
public struct SynthesisAttempt: Codable, Equatable, Sendable {
    public var attempt: Int
    public var translationRev: Int
    public var voice: VoiceSelection
    public var status: SynthesisStatus
    public var route: Route
    public var playback: TimeRange?
    public var generatedAudio: String?
    public init(attempt: Int, translationRev: Int, voice: VoiceSelection, status: SynthesisStatus, route: Route, playback: TimeRange? = nil, generatedAudio: String? = nil) {
        self.attempt = attempt; self.translationRev = translationRev; self.voice = voice; self.status = status; self.route = route
        self.playback = playback; self.generatedAudio = generatedAudio
    }
}

public struct Span: Codable, Equatable, Sendable {
    public var kind: SpanKind
    public var from: Double
    public var to: Double
    public init(kind: SpanKind, from: Double, to: Double) { self.kind = kind; self.from = from; self.to = to }
}

public struct Utterance: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID                       // stable for life; never re-minted
    public var direction: Direction
    public var speaker: Speaker
    public var speakerLabel: String?
    public var track: Track
    public var sourceLanguage: String
    public var targetLanguage: String
    public var source: TimeRange              // session clock, source audio time
    public var sourceRevisions: [SourceRevision]
    public var translations: [Translation]
    public var synthesis: [SynthesisAttempt]
    public var review: ReviewState
    public var spans: [Span]

    public init(id: UUID = UUID(), direction: Direction, speaker: Speaker, track: Track, sourceLanguage: String, targetLanguage: String,
                source: TimeRange, text: String, words: [Word]? = nil, at: Date = Date()) {
        self.id = id
        self.direction = direction
        self.speaker = speaker
        self.track = track
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.source = source
        self.sourceRevisions = [SourceRevision(rev: 1, origin: .asr, text: text, words: words, at: at)]
        self.translations = []
        self.synthesis = []
        self.review = .unreviewed
        self.spans = []
    }

    public var currentSourceRevision: Int { sourceRevisions.count }
    public var currentSourceText: String { sourceRevisions.last?.text ?? "" }
    public var currentTranslation: Translation? { translations.last }
    /// True when the translation was made from the current source revision.
    public func translationIsCurrent(_ rev: Int) -> Bool {
        translations.first(where: { $0.rev == rev })?.sourceRev == currentSourceRevision
    }
    public func translation(rev: Int) -> Translation? { translations.first { $0.rev == rev } }
    /// The exact text that reached playback, if any attempt played. Later corrections never change it.
    public var spokenText: String? {
        guard let played = synthesis.last(where: { $0.status == .played }) else { return nil }
        return translation(rev: played.translationRev)?.text
    }

    public func validate() throws {
        try source.validate()
        guard !sourceRevisions.isEmpty else { throw TranslateProblem("An utterance needs a source revision.") }
        for (index, revision) in sourceRevisions.enumerated() {
            guard revision.rev == index + 1 else { throw TranslateProblem("Source revisions must be numbered from 1 without gaps.") }
            guard revision.text.utf8Count <= Bounds.maxTextBytes else { throw TranslateProblem("Source text is too long.") }
        }
        for (index, translation) in translations.enumerated() {
            guard translation.rev == index + 1 else { throw TranslateProblem("Translation revisions must be numbered from 1 without gaps.") }
            guard (1...sourceRevisions.count).contains(translation.sourceRev) else { throw TranslateProblem("Translation cites a missing source revision.") }
            guard translation.text.utf8Count <= Bounds.maxTextBytes else { throw TranslateProblem("Translated text is too long.") }
        }
        for (index, attempt) in synthesis.enumerated() {
            guard attempt.attempt == index + 1 else { throw TranslateProblem("Synthesis attempts must be numbered from 1 without gaps.") }
            guard (1...max(translations.count, 1)).contains(attempt.translationRev), !translations.isEmpty else {
                throw TranslateProblem("Synthesis cites a missing translation revision.")
            }
            try attempt.playback?.validate()
            if let blend = attempt.voice.blend { guard blend.isFinite, (0...1).contains(blend) else { throw TranslateProblem("Invalid voice blend.") } }
        }
        if let label = speakerLabel { guard !label.isEmpty, label.utf8Count <= Bounds.maxLabelBytes else { throw TranslateProblem("Invalid speaker label.") } }
        for span in spans { guard span.from.isFinite, span.to.isFinite, span.from <= span.to else { throw TranslateProblem("Invalid span.") } }
    }
}
