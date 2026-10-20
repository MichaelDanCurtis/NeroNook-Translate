import Foundation

/// Decides what may be written durably. Mirrors the control table in plan §2.2:
/// a session that saves nothing writes nothing; while recording is paused, or after the other
/// person's agreement to recording is withdrawn, only gap and state events are kept; otherwise everything.
public struct PersistencePolicy: Equatable, Sendable {
    public var saving: SavingMode
    public var recordingConsent: Bool
    public var recordingPaused: Bool

    public init(saving: SavingMode, recordingConsent: Bool, recordingPaused: Bool = false) {
        self.saving = saving; self.recordingConsent = recordingConsent; self.recordingPaused = recordingPaused
    }

    /// Any saved meeting, audio or transcript only, is a record of the other person; starting one needs their agreement.
    public static func validateStart(saving: SavingMode, consent: Consent) throws {
        if saving != .none, !consent.recording.granted {
            throw TranslateProblem("Saving this call needs the other person's agreement to being recorded.")
        }
    }

    /// Whether a durable record exists at all. The saving choice is made before Start and does not change mid-session.
    public var persistsAnything: Bool { saving != .none }
    /// Content (text, translations, speech status) is kept only while agreed and not paused.
    public var persistsContent: Bool { saving != .none && recordingConsent && !recordingPaused }
    public var persistsText: Bool { persistsContent }
    public var persistsAudio: Bool { saving == .audioAndTranscript && recordingConsent && !recordingPaused }

    /// Events that describe the record itself rather than its content. They are kept while paused and
    /// after agreement is withdrawn, so the record shows why and when content stops.
    public static let stateEvents: Set<JournalEventType> = [.gap, .recordingPaused, .recordingResumed, .sessionState, .consentChanged, .voiceReady]

    public func allows(_ type: JournalEventType) -> Bool {
        guard persistsAnything else { return false }
        guard persistsContent else { return Self.stateEvents.contains(type) }
        return true
    }
}

/// Learning the remote voice is separate from recording and needs its own agreement.
public struct LearningPolicy: Equatable, Sendable {
    public var consent: Consent
    public init(consent: Consent) { self.consent = consent }
    public var mayLearnRemoteVoice: Bool { consent.voiceMatching.granted }
}

/// What happens to the learned remote reference when the session ends.
public enum RemoteVoiceRetention: Equatable, Sendable {
    case discard
    case keep(profileID: String)

    /// Keeping a voice needs its own confirmation; agreement to matching during the call does not cover it.
    public static func atSessionEnd(saveRequested: Bool, keepConfirmed: Bool, profileID: String) -> RemoteVoiceRetention {
        (saveRequested && keepConfirmed) ? .keep(profileID: profileID) : .discard
    }
}

/// Consent transitions produce journal payloads so the record shows when each agreement changed.
/// The timestamp records the change in either direction.
public struct ConsentState: Equatable, Sendable {
    public private(set) var consent: Consent
    public init(_ consent: Consent) { self.consent = consent }

    public mutating func setVoiceMatching(_ granted: Bool, at: Date = Date()) -> JournalEvent.Payload {
        consent.voiceMatching = Grant(granted: granted, at: at)
        return .consentChanged(consent)
    }
    public mutating func setRecording(_ granted: Bool, at: Date = Date()) -> JournalEvent.Payload {
        consent.recording = Grant(granted: granted, at: at)
        return .consentChanged(consent)
    }
}
