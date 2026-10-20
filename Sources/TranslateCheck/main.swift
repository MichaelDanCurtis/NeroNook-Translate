import Foundation
import NookPluginSDK
import TranslateCore

// Host-free checks. Uses the real SDK validators for the manifest and Core replay for journals.
// Never echoes payloads: output is counts and OK/FAIL only.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

let arguments = CommandLine.arguments.dropFirst()
do {
    if arguments.contains("--manifest") {
        let data: Data
        if let path = argument(after: "--manifest") , !path.hasPrefix("--") {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = try FileHandle.standardInput.readToEnd() ?? Data()
        }
        guard data.count <= 8192 else { throw ModuleProblem("Manifest exceeds its limit.") }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        guard manifest.launchMode == "application" else { throw ModuleProblem("Translate must run in application launch mode.") }
        print("OK manifest \(manifest.id) \(manifest.version)")
    } else if let path = argument(after: "--replay") {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 256 * 1024 * 1024 else { throw TranslateProblem("Journal exceeds the check limit.") }
        let recovery = JournalReader.recover(data)
        let (transcript, summary) = Transcript.replay(recovery.events)
        print("OK replay events=\(recovery.events.count) utterances=\(transcript.count) lastSeq=\(summary.lastSeq) validBytes=\(recovery.validBytes) ignoredTail=\(recovery.ignoredTail) stoppedAtLine=\(recovery.stoppedAtLine.map(String.init) ?? "none") stoppedAtSeq=\(summary.stoppedAtSeq.map(String.init) ?? "none")")
    } else {
        print("Usage: TranslateCheck --manifest [path] | --replay <journal.jsonl>")
        exit(2)
    }
} catch {
    fail("FAIL: \(error)")
}
