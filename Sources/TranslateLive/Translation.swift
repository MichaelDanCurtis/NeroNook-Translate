import Foundation
import Translation

/// Apple Translation with one prepared session per language pair, on the main actor. The executable must
/// be stamped with SDK 27 or later or installed packs report `supported` (Package.swift linker flag).
@MainActor public final class AppleTranslation {
    private var sessions: [String: TranslationSession] = [:]
    public init() {}

    public static func status(from: String, to: String) async -> String {
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        switch status {
        case .installed: return "installed"
        case .supported: return "supported"
        default: return "unsupported"
        }
    }

    public func prepare(from: String, to: String) async throws {
        let key = from + ">" + to
        guard sessions[key] == nil else { return }
        guard await Self.status(from: from, to: to) == "installed" else {
            throw LiveProblem("Apple Translation \(Languages.name(from)) → \(Languages.name(to)) is not installed on this Mac (System Settings → General → Language & Region → Translation Languages).")
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        try await session.prepareTranslation()
        sessions[key] = session
    }

    public func translate(_ text: String, from: String, to: String) async throws -> String {
        try await prepare(from: from, to: to)
        guard let session = sessions[from + ">" + to] else { throw LiveProblem("No translation session.") }
        return try await session.translate(text).targetText
    }
}
