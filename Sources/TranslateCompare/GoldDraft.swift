import Foundation

/// Sentence splitting for drafted transcripts: one sentence per line, so the translation rows and the
/// checks' sentence windows line up with what the speaker corrects.
public enum GoldDraft {
    public static func sentences(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let latinStop = ".?!".contains(character) && (next.isWhitespace || index + 1 == characters.count)
            let cjkStop = "。？！".contains(character)
            if latinStop || cjkStop {
                let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lines.append(tail) }
        return lines
    }
}
