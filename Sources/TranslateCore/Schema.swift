import Foundation

// Session schema v1. See docs/ARCHITECTURE-PLAN.md §5. Every new field must be optional
// so older files keep decoding; originals and the journal are never rewritten in place.

public enum Direction: String, Codable, Sendable, CaseIterable, Hashable { case incoming, outgoing }
public enum Speaker: String, Codable, Sendable { case me, other, unknown }
public enum Track: String, Codable, Sendable { case mic, call }
public enum SavingMode: String, Codable, Sendable {
    case audioAndTranscript = "audio+transcript"
    case transcript
    case none
}
public enum SessionState: String, Codable, Sendable { case live, saved, interrupted, discarded }
public enum ReviewState: String, Codable, Sendable { case unreviewed, reviewed, uncertain }
public enum SynthesisStatus: String, Codable, Sendable { case queued, generating, played, cancelled, failed, omitted }
public enum Route: String, Codable, Sendable { case headphones, virtualMicrophone }
public enum GapReason: String, Codable, Sendable { case paused, muted, deviceLost, captureFailure, overflow, engineRestart }
public enum SpanKind: String, Codable, Sendable { case interrupted, omitted }
public enum RevisionOrigin: String, Codable, Sendable { case asr, mt, user }
public enum VoiceSlot: String, Codable, Sendable { case local, remote, generic }

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
    public func validate() throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= Bounds.maxSessionSeconds else {
            throw TranslateProblem("Invalid time range.")
        }
    }
}

public struct Grant: Codable, Equatable, Sendable {
    public var granted: Bool
    public var at: Date?
    public init(granted: Bool, at: Date? = nil) { self.granted = granted; self.at = at }
    public static let none = Grant(granted: false)
}

/// Separate confirmations. Neither implies the other (PRD).
public struct Consent: Codable, Equatable, Sendable {
    public var voiceMatching: Grant
    public var recording: Grant
    public init(voiceMatching: Grant = .none, recording: Grant = .none) {
        self.voiceMatching = voiceMatching; self.recording = recording
    }
}

public struct Languages: Codable, Equatable, Sendable {
    public var me: String
    public var other: String
    public init(me: String, other: String) { self.me = me; self.other = other }
    public func validate() throws {
        for tag in [me, other] {
            guard tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                throw TranslateProblem("Invalid language tag.")
            }
        }
        guard me.lowercased() != other.lowercased() else { throw TranslateProblem("Choose two different languages.") }
    }
}

public struct Names: Codable, Equatable, Sendable {
    public var me: String?
    public var other: String?
    public init(me: String? = nil, other: String? = nil) { self.me = me; self.other = other }
}

public struct DeviceRecord: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public init(uid: String, name: String) { self.uid = uid; self.name = name }
}

public struct Devices: Codable, Equatable, Sendable {
    public var microphone: DeviceRecord?
    public var output: DeviceRecord?
    public var conferencingBundleID: String?
    public init(microphone: DeviceRecord? = nil, output: DeviceRecord? = nil, conferencingBundleID: String? = nil) {
        self.microphone = microphone; self.output = output; self.conferencingBundleID = conferencingBundleID
    }
}

public struct ProviderRecord: Codable, Equatable, Sendable {
    public var id: String
    public var model: String?
    public var revision: String?
    public var runtime: String?
    public init(id: String, model: String? = nil, revision: String? = nil, runtime: String? = nil) {
        self.id = id; self.model = model; self.revision = revision; self.runtime = runtime
    }
}

public struct VoiceRecord: Codable, Equatable, Sendable {
    public var profileID: String?
    public var revision: Int
    public var sha256: String?
    public var temporary: Bool
    public var readyAt: Double?
    public init(profileID: String? = nil, revision: Int = 1, sha256: String? = nil, temporary: Bool = false, readyAt: Double? = nil) {
        self.profileID = profileID; self.revision = revision; self.sha256 = sha256; self.temporary = temporary; self.readyAt = readyAt
    }
}

public struct Clock: Codable, Equatable, Sendable {
    public var epochHostTime: UInt64
    public var timebase: String
    public var sampleRates: [String: Int]
    public init(epochHostTime: UInt64, timebase: String = "mach_absolute_time", sampleRates: [String: Int] = [:]) {
        self.epochHostTime = epochHostTime; self.timebase = timebase; self.sampleRates = sampleRates
    }
}

public struct AudioChunk: Codable, Equatable, Sendable {
    public var file: String
    public var track: Track
    public var start: Double
    public var frames: Int
    public var rate: Int
    public var codec: String
    public init(file: String, track: Track, start: Double, frames: Int, rate: Int = 48_000, codec: String = "alac") {
        self.file = file; self.track = track; self.start = start; self.frames = frames; self.rate = rate; self.codec = codec
    }
}

/// An explicit record of time with no usable audio. Overflow records a gap; it never fails the recording.
public struct Gap: Codable, Equatable, Sendable {
    public var track: Track
    public var start: Double
    public var end: Double
    public var reason: GapReason
    public init(track: Track, start: Double, end: Double, reason: GapReason) {
        self.track = track; self.start = start; self.end = end; self.reason = reason
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var state: SessionState
    public var languages: Languages
    public var names: Names
    public var devices: Devices?
    public var providers: [String: ProviderRecord]?
    public var saving: SavingMode
    public var consent: Consent
    public var voices: [String: VoiceRecord]?
    public var clock: Clock?
    public var audioChunks: [AudioChunk]
    public var gaps: [Gap]

    public init(id: UUID = UUID(), createdAt: Date = Date(), languages: Languages, saving: SavingMode, consent: Consent = Consent()) {
        self.schemaVersion = Bounds.schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.state = .live
        self.languages = languages
        self.names = Names()
        self.saving = saving
        self.consent = consent
        self.audioChunks = []
        self.gaps = []
    }

    public func validate() throws {
        guard schemaVersion == Bounds.schemaVersion else { throw TranslateProblem("Unsupported session schema version.") }
        try languages.validate()
        for label in [names.me, names.other].compactMap({ $0 }) {
            guard !label.isEmpty, label.utf8Count <= Bounds.maxLabelBytes else { throw TranslateProblem("Invalid name label.") }
        }
        for gap in gaps {
            guard gap.start.isFinite, gap.end.isFinite, gap.start >= 0, gap.end >= gap.start else { throw TranslateProblem("Invalid gap.") }
        }
        for chunk in audioChunks {
            guard chunk.frames >= 0, chunk.rate > 0, chunk.start.isFinite, chunk.start >= 0,
                  chunk.file.hasPrefix("audio/"), !chunk.file.contains(".."), !chunk.file.contains("//") else {
                throw TranslateProblem("Invalid audio chunk.")
            }
        }
    }
}
