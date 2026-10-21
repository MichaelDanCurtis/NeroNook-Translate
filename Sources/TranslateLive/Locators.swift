import Foundation

/// Finds the engine helper: inside the app bundle when packaged, next to the package when run from `.build`.
public enum HelperLocator {
    public static func engine(executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) throws -> URL {
        let bundle = Bundle.main.bundleURL
        let packageRoot = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // .build/<config>/TranslateApp → package
        let candidates = [bundle.appendingPathComponent("Contents/Helpers/TranslateEngine"),
                          packageRoot.appendingPathComponent("Engine/.build/release/TranslateEngine")]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        throw LiveProblem("TranslateEngine is missing: build it with `swift build -c release --package-path Engine` (looked in \(candidates.map(\.path).joined(separator: ", "))).")
    }
}

/// Finds imported checkpoints under the plugin's Models folder (`<repository tail>-<commit>`).
public enum ModelLocator {
    public static func models(in storage: URL) -> URL { storage.appendingPathComponent("Models") }

    public static func checkpoint(prefix: String, in storage: URL) throws -> URL {
        let root = models(in: storage)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(prefix + "-") }.sorted()
        guard let name = names.first else { throw LiveProblem("The \(prefix) model is not prepared yet (nothing under \(root.path)).") }
        guard names.count == 1 else { throw LiveProblem("Several revisions of \(prefix) are under \(root.path); keep one.") }
        return root.appendingPathComponent(name)
    }

    public static func qwenBase(in storage: URL) throws -> URL { try checkpoint(prefix: "Qwen3-TTS-12Hz-1.7B-Base-8bit", in: storage) }
}
