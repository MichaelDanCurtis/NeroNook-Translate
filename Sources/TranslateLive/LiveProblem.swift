import Foundation

public struct LiveProblem: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Language codes the session uses, and their spellings for each engine.
public enum Languages {
    public static let supported = ["en", "es", "zh"]
    public static func name(_ code: String) -> String { ["en": "English", "es": "Spanish", "zh": "Mandarin"][code] ?? code }
    /// Apple speech locale: Mexican Spanish is the owner's choice (October 20, 2026).
    public static func speechLocale(_ code: String) -> String { ["en": "en-US", "es": "es-MX", "zh": "zh-CN"][code] ?? code }
    /// Qwen's language names, which the engine wants for voice preparation.
    public static func qwenName(_ code: String) -> String? { ["en": "English", "es": "Spanish", "zh": "Chinese"][code] }
}
