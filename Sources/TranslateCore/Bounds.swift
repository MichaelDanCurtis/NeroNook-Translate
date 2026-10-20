import Foundation

/// Fixed limits for session data and scheduling. Numbers marked "proposal" in the
/// architecture plan live here so tests and the app share one source of truth.
public enum Bounds {
    public static let schemaVersion = 1

    // Session data (matches Voice's validation ceilings).
    public static let maxUtterances = 40_000
    public static let maxSessionSeconds: Double = 4.5 * 3600
    public static let maxTextBytes = 2048
    public static let maxJournalLineBytes = 16 * 1024
    public static let maxQuoteBytes = 512
    public static let maxLabelBytes = 80

    // Live presentation.
    public static let liveWindowUtterances = 200
    public static let captionStateBytes = 32 * 1024

    // Synthesis scheduling (plan §2.3–2.4, proposals until measured).
    public static let maxSynthesisUnitBytes = 300
    public static let phraseCapSeconds: Double = 8
    public static let softBacklogPhrases = 2
    public static let softBacklogSeconds: Double = 6
    public static let hardBacklogSeconds: Double = 20
}

/// A problem in session data or a disallowed transition. The message is safe to show.
public struct TranslateProblem: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// JSON settings shared by every file this package writes, so output is deterministic.
/// Wall-clock dates use Swift's own `Date` encoding: the exact seconds-since-2001 interval as a
/// double, which round-trips bit for bit (replay equality depends on that). Exports format them for people.
public enum SessionJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

extension String {
    var utf8Count: Int { utf8.count }
}
