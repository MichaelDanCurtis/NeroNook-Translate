import Foundation

/// One check the scoring looks for in a transcript: any accepted form counts. `display` is the form a
/// names list should carry (proper casing and accents), when the accepted forms are scoring spellings.
public struct Check: Codable, Sendable {
    public let category: String
    public let sentence: Int?
    public let accept: [String]
    public var display: String?
    public init(category: String, sentence: Int?, accept: [String], display: String? = nil) { self.category = category; self.sentence = sentence; self.accept = accept; self.display = display }
}

/// One recording with its reference text and checks.
public struct CorpusItem: Sendable {
    public let id: String
    public let language: String          // "en", "es", "zh"
    public let audio: URL
    public let reference: String         // full reference text; scripted items have one sentence per line
    public let checks: [Check]
    public let kind: String              // "scripted", "natural", "fixture"

    public var referenceLines: [String] { reference.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

public enum CorpusLoader {
    public static let audioExtensions: Set<String> = ["wav", "m4a", "caf", "aiff", "aif", "mp3", "flac"]

    /// Fixtures/Corpus layout: raw/<lang>/<name>.<audio> with gold/<lang>/<name>.txt (+ .checks.json), and
    /// the call-codec copy codec/<lang>/<name>.wav (scripts/corpus-codec.sh) sharing the same gold files.
    /// Codec items are "<lang>/<name>@codec" with kind "codec".
    public static func load(corpus root: URL, languages: Set<String>) throws -> [CorpusItem] {
        var items: [CorpusItem] = []
        for (subfolder, codec) in [("raw", false), ("codec", true)] {
            for language in languages.sorted() {
                let folder = root.appendingPathComponent(subfolder).appendingPathComponent(language)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
                for name in names.sorted() {
                    let url = folder.appendingPathComponent(name)
                    guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let base = url.deletingPathExtension().lastPathComponent
                    guard !base.hasPrefix("reference") else { continue }   // a reference take is a listening-set voice, not a corpus item
                    let gold = root.appendingPathComponent("gold/\(language)")
                    guard let reference = try? String(contentsOf: gold.appendingPathComponent(base + ".txt"), encoding: .utf8) else {
                        FileHandle.standardError.write(Data("skipping \(subfolder)/\(language)/\(name): no gold/\(language)/\(base).txt\n".utf8)); continue
                    }
                    var checks: [Check] = []
                    if let data = try? Data(contentsOf: gold.appendingPathComponent(base + ".checks.json")),
                       let file = try? JSONDecoder().decode(ChecksFile.self, from: data) { checks = file.checks }
                    items.append(CorpusItem(id: "\(language)/\(base)" + (codec ? "@codec" : ""), language: language, audio: url, reference: reference, checks: checks,
                                            kind: codec ? "codec" : base.hasPrefix("scripted") ? "scripted" : "natural"))
                }
            }
        }
        return items
    }

    /// Fixtures/Voices layout: <name>-<lang>.wav with <name>-<lang>.txt. Plumbing checks only; synthetic voices.
    public static func loadFixtures(_ folder: URL, languages: Set<String>) throws -> [CorpusItem] {
        var items: [CorpusItem] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".wav") {
            let base = String(name.dropLast(4))
            guard let dash = base.lastIndex(of: "-") else { continue }
            let language = String(base[base.index(after: dash)...])
            guard languages.contains(language), let reference = try? String(contentsOf: folder.appendingPathComponent(base + ".txt"), encoding: .utf8) else { continue }
            items.append(CorpusItem(id: "fixture/\(base)", language: language, audio: folder.appendingPathComponent(name), reference: reference.trimmingCharacters(in: .whitespacesAndNewlines), checks: [], kind: "fixture"))
        }
        return items
    }

    struct ChecksFile: Codable { let checks: [Check] }
}
