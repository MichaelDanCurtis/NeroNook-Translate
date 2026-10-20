import Foundation
@testable import TranslateCore

enum Fixtures {
    static let languages = Languages(me: "en-US", other: "es-ES")

    static func utterance(direction: Direction = .incoming, start: Double = 10, end: Double = 13, text: String = "Hola, me llamo Ana.") -> Utterance {
        let incoming = direction == .incoming
        return Utterance(direction: direction, speaker: incoming ? .other : .me, track: incoming ? .call : .mic,
                         sourceLanguage: incoming ? languages.other : languages.me, targetLanguage: incoming ? languages.me : languages.other,
                         source: TimeRange(start: start, end: end), text: text, at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func manifest(saving: SavingMode = .none, consent: Consent = Consent()) -> SessionManifest {
        SessionManifest(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), languages: languages, saving: saving, consent: consent)
    }

    static let fullConsent = Consent(voiceMatching: Grant(granted: true, at: Date(timeIntervalSince1970: 1_800_000_000)),
                                     recording: Grant(granted: true, at: Date(timeIntervalSince1970: 1_800_000_000)))
}
