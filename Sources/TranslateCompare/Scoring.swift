import Foundation

/// Text normalization for scoring: lowercase, Unicode-compatible, punctuation removed, number words
/// folded into digits for English and Spanish, Chinese numerals folded for Mandarin, and then **every
/// digit scored as its own token**, so "ten thirty", "10:30" and "1030" meet in the same form, as do
/// "nineteen eighty" and "1980" or "zero seven five five" and "0755". Number words only combine where
/// the grammar allows ("forty five", "two hundred and five", "fourteen thousand"); two numbers in a row
/// stay separate. Percent, currency and a leading minus are kept as tokens. This is a scoring aid, not a
/// linguistic normalizer; its rules are listed in the receipt.
public enum Normalizer {
    static let englishUnits: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let englishOrdinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30]
    static let spanishUnits: [String: Int] = ["cero": 0, "uno": 1, "una": 1, "un": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
        "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciséis": 16, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
        "veinte": 20, "veintiuno": 21, "veintiún": 21, "veintidós": 22, "veintidos": 22, "veintitrés": 23, "veintitres": 23, "veinticuatro": 24, "veinticinco": 25,
        "veintiséis": 26, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
        "setenta": 70, "ochenta": 80, "noventa": 90, "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200, "trescientos": 300, "cuatrocientos": 400,
        "quinientos": 500, "seiscientos": 600, "setecientos": 700, "ochocientos": 800, "novecientos": 900]

    struct Grammar {
        let units: [String: Int]            // 0–19, tens, and (Spanish) hundreds words with their value
        let hundred: String?                // the multiplier word ("hundred"); Spanish has none
        let scales: [String: Int]           // thousand, million
        let point: String
        let joiner: String                  // "and" / "y"
        let ordinals: [String: Int]
        let percent: [String]               // token sequence meaning percent
        let symbolWords: [Character: String]
        let minus: String
    }
    static let english = Grammar(units: englishUnits, hundred: "hundred", scales: ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000],
                                 point: "point", joiner: "and", ordinals: englishOrdinals, percent: ["percent"],
                                 symbolWords: ["$": "dollars", "€": "euros", "£": "pounds"], minus: "minus")
    static let spanish = Grammar(units: spanishUnits, hundred: nil, scales: ["mil": 1_000, "millón": 1_000_000, "millones": 1_000_000],
                                 point: "punto", joiner: "y", ordinals: [:], percent: ["por", "ciento"],
                                 symbolWords: ["$": "dólares", "€": "euros", "£": "libras"], minus: "menos")

    public static func normalize(_ text: String, language: String) -> String {
        let grammar: Grammar? = language == "en" ? english : language == "es" ? spanish : nil
        var s = text.precomposedStringWithCompatibilityMapping.lowercased()
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        if language == "zh" { s = foldChineseNumerals(s) }
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            let previous = i > 0 ? chars[i - 1] : " ", next = i + 1 < chars.count ? chars[i + 1] : " "
            if c.isLetter || c.isNumber || c.isWhitespace { out.append(c); continue }
            if c == "'", previous.isLetter, next.isLetter { out.append(c); continue }
            if c == ".", previous.isNumber, next.isNumber { out.append(c); continue }                   // decimal point
            if c == ":" || c == ",", previous.isNumber, next.isNumber { continue }                        // 10:30 → 1030; 1,500 → 1500
            if c == "%", previous.isNumber { out.append("%"); continue }
            if let grammar {
                if grammar.symbolWords[c] != nil, next.isNumber { out.append(" \(c) "); continue }           // own token, resolved after the number
                if c == "-", next.isNumber, !previous.isNumber, !previous.isLetter { out.append(" \(grammar.minus) "); continue }
                _ = grammar
            }
            out.append(" ")
        }
        var tokens = out.split(whereSeparator: \.isWhitespace).map(String.init)
        if let grammar {
            tokens = markPercent(tokens, grammar: grammar)
            tokens = foldNumbers(tokens, grammar: grammar)
            tokens = resolveSymbols(tokens, grammar: grammar)
        }
        return tokens.flatMap(explodeDigits).joined(separator: " ")
    }

    enum Kind { case none, unit, tens, hundred, scale }

    /// Folds runs of number words into digits where the grammar allows and nowhere else.
    static func foldNumbers(_ tokens: [String], grammar: Grammar) -> [String] {
        var result: [String] = []
        var i = 0
        func unit(_ t: String) -> Int? { grammar.units[t] }
        while i < tokens.count {
            let t = tokens[i]
            // A digit number before a scale word ("1.5 million", "2 thousand") folds to the same figure as the spoken form.
            if let numeric = Double(t), t.first?.isNumber == true, i + 1 < tokens.count, let scale = grammar.scales[tokens[i + 1]] {
                let product = numeric * Double(scale)
                result.append(product == product.rounded() ? String(Int(product)) : String(product))
                i += 2; continue
            }
            if let ordinal = grammar.ordinals[t] {
                // "twenty third" → 23rd; a bare ordinal keeps its own number
                if let last = result.last, let tens = Int(last), tens % 10 == 0, tens >= 20, tens < 100, ordinal < 10, i > 0, grammar.units[tokens[i - 1]] == tens {
                    result[result.count - 1] = ordinalString(tens + ordinal)
                } else { result.append(ordinalString(ordinal)) }
                i += 1; continue
            }
            guard unit(t) != nil || t == grammar.hundred || grammar.scales[t] != nil else { result.append(t); i += 1; continue }
            var total = 0, group = 0, j = i, consumed = false
            var last = Kind.none
            scan: while j < tokens.count {
                let w = tokens[j]
                if let u = unit(w) {
                    if u >= 100 {                                   // Spanish hundreds words carry their value
                        guard last == .none || last == .scale else { break scan }
                        group += u; last = .hundred
                    } else if u >= 20 {
                        guard last == .none || last == .hundred || last == .scale else { break scan }
                        group += u; last = .tens
                    } else {
                        if last == .tens { guard u >= 1, u <= 9 else { break scan } }
                        else { guard last == .none || last == .hundred || last == .scale else { break scan } }
                        group += u; last = .unit
                    }
                } else if w == grammar.hundred {
                    guard last == .unit || last == .none else { break scan }
                    group = (group == 0 ? 1 : group) * 100; last = .hundred
                } else if let scale = grammar.scales[w] {
                    guard last != .scale else { break scan }
                    total += (group == 0 ? 1 : group) * scale; group = 0; last = .scale
                } else if w == grammar.joiner, consumed, j + 1 < tokens.count, let u = unit(tokens[j + 1]), u < 100,
                          (last == .hundred || (grammar.hundred == nil && last == .tens && u < 10)) {
                    // "two hundred and five", "cuarenta y cinco"
                } else { break scan }
                consumed = true
                j += 1
            }
            guard consumed else { result.append(t); i += 1; continue }
            var value = String(total + group)
            if j < tokens.count, tokens[j] == grammar.point {
                var k = j + 1, decimals = ""
                while k < tokens.count, let d = unit(tokens[k]), d < 10 { decimals += String(d); k += 1 }
                if !decimals.isEmpty {
                    value += "." + decimals; j = k
                    // "one point five million" is 1500000, the form an engine that writes digits produces.
                    if j < tokens.count, let scale = grammar.scales[tokens[j]], let decimal = Double(value) {
                        let product = decimal * Double(scale)
                        value = product == product.rounded() ? String(Int(product)) : String(product); j += 1
                    }
                }
            }
            result.append(value)
            i = j
        }
        return result
    }

    static func ordinalString(_ n: Int) -> String {
        let suffix = (n % 100 >= 11 && n % 100 <= 13) ? "th" : n % 10 == 1 ? "st" : n % 10 == 2 ? "nd" : n % 10 == 3 ? "rd" : "th"
        return "\(n)\(suffix)"
    }

    /// "percent" / "por ciento" become a "%" token before number folding ("ciento" would otherwise fold as 100).
    static func markPercent(_ tokens: [String], grammar: Grammar) -> [String] {
        var result: [String] = []
        var i = 0
        while i < tokens.count {
            if Array(tokens[i..<min(tokens.count, i + grammar.percent.count)]) == grammar.percent { result.append("%"); i += grammar.percent.count }
            else { result.append(tokens[i]); i += 1 }
        }
        return result
    }

    /// "$ 12" → "12 dollars"; "45 %" → "45%".
    static func resolveSymbols(_ tokens: [String], grammar: Grammar) -> [String] {
        var result: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.count == 1, let word = grammar.symbolWords[t.first!], i + 1 < tokens.count, tokens[i + 1].first?.isNumber == true {
                result.append(tokens[i + 1]); result.append(word); i += 2; continue
            }
            if t == "%", let last = result.last, last.first?.isNumber == true, !last.hasSuffix("%") {
                result[result.count - 1] = last + "%"; i += 1; continue
            }
            result.append(t); i += 1
        }
        return result
    }

    /// "1030" → "1 0 3 0"; "3.5" → "3 . 5"; "23rd" → "2 3 rd"; "45%" → "4 5 %"; words pass through.
    static func explodeDigits(_ token: String) -> [String] {
        guard token.contains(where: \.isNumber) else { return [token] }
        var parts: [String] = []
        var run = ""
        for c in token {
            if c.isNumber || c == "." || c == "%" {
                if !run.isEmpty { parts.append(run); run = "" }
                parts.append(String(c))
            } else { run.append(c) }
        }
        if !run.isEmpty { parts.append(run) }
        return parts
    }

    static let chineseDigits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let chineseUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "万": 10_000, "亿": 100_000_000]

    /// Runs of Chinese numerals become digits: 十点半 → 10点半, 一万四千 → 14000, 三月十二日 → 3月12日.
    /// A run of bare digits (一二一, a number read out) stays digit by digit.
    static func foldChineseNumerals(_ text: String) -> String {
        var out = ""
        var run: [Character] = []
        func flush() {
            guard !run.isEmpty else { return }
            out += chineseNumber(run)
            run = []
        }
        for c in text {
            if chineseDigits[c] != nil || chineseUnits[c] != nil { run.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return out
    }

    static func chineseNumber(_ run: [Character]) -> String {
        guard run.contains(where: { chineseUnits[$0] != nil }) else { return run.map { String(chineseDigits[$0] ?? 0) }.joined() }
        var total = 0, section = 0, number = 0
        for c in run {
            if let d = chineseDigits[c] { number = d; continue }
            switch chineseUnits[c] ?? 0 {
            case 10: section += (number == 0 ? 1 : number) * 10; number = 0
            case 100: section += (number == 0 ? 1 : number) * 100; number = 0
            case 1_000: section += (number == 0 ? 1 : number) * 1_000; number = 0
            case 10_000: total += (section + number) * 10_000; section = 0; number = 0
            case 100_000_000: total += (section + number) * 100_000_000; section = 0; number = 0
            default: break
            }
        }
        return String(total + section + number)
    }

    public static func stripDiacritics(_ s: String) -> String { s.folding(options: .diacriticInsensitive, locale: nil) }

    /// Scoring tokens: words and single digits for English and Spanish; characters for Mandarin.
    public static func tokens(_ text: String, language: String) -> [String] {
        let normalized = normalize(text, language: language)
        if language == "zh" { return normalized.filter { !$0.isWhitespace }.map(String.init) }
        return normalized.split(separator: " ").map(String.init)
    }
}

public struct ErrorRate: Codable, Sendable {
    public let errors: Int
    public let total: Int
    public init(errors: Int, total: Int) { self.errors = errors; self.total = total }
    public var rate: Double { total > 0 ? Double(errors) / Double(total) : 0 }
}

public enum Scoring {
    /// Levenshtein distance between two sequences.
    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// For every reference token, the hypothesis index it aligns with (match or substitution), or nil when
    /// the alignment deletes it. Full edit-distance backtrace; sized for one recording, not a corpus.
    static func align<T: Equatable>(_ a: [T], _ b: [T]) -> [Int?] {
        let n = a.count, m = b.count
        guard n > 0 else { return [] }
        guard m > 0 else { return [Int?](repeating: nil, count: n) }
        var d = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        for i in 0...n { d[at(i, 0)] = Int32(i) }
        for j in 0...m { d[at(0, j)] = Int32(j) }
        for i in 1...n {
            for j in 1...m {
                let substitution = d[at(i - 1, j - 1)] + (a[i - 1] == b[j - 1] ? 0 : 1)
                d[at(i, j)] = min(d[at(i - 1, j)] + 1, d[at(i, j - 1)] + 1, substitution)
            }
        }
        var mapping = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let here = d[at(i, j)]
            if here == d[at(i - 1, j - 1)] + (a[i - 1] == b[j - 1] ? 0 : 1) { mapping[i - 1] = j - 1; i -= 1; j -= 1 }
            else if here == d[at(i - 1, j)] + 1 { i -= 1 }
            else { j -= 1 }
        }
        return mapping
    }

    /// Token error rate on normalized tokens (words and single digits for English and Spanish);
    /// character error rate for Mandarin.
    public static func errorRate(reference: String, hypothesis: String, language: String) -> ErrorRate {
        let r = Normalizer.tokens(reference, language: language)
        let h = Normalizer.tokens(hypothesis, language: language)
        return ErrorRate(errors: distance(r, h), total: r.count)
    }

    public struct CheckOutcome: Codable, Sendable { public let category: String; public let sentence: Int?; public let passed: Bool; public let matched: String? }

    /// A check passes when any accepted form appears in the normalized transcript, with or without
    /// diacritics. A check with a sentence number must match inside the stretch of the transcript that
    /// aligns with that reference sentence (plus a few tokens of slack), so a form that occurs elsewhere
    /// in the recording cannot satisfy it; a sentence the transcript dropped entirely fails its checks.
    public static func runChecks(_ checks: [Check], reference: String, hypothesis: String, language: String) -> [CheckOutcome] {
        let hypothesisTokens = Normalizer.tokens(hypothesis, language: language)
        let lines = reference.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lineTokens = lines.map { Normalizer.tokens($0, language: language) }
        let referenceTokens = lineTokens.flatMap { $0 }
        let mapping = checks.contains { $0.sentence != nil } ? align(referenceTokens, hypothesisTokens) : []
        var lineStart: [Int] = []
        var offset = 0
        for tokens in lineTokens { lineStart.append(offset); offset += tokens.count }
        let slack = language == "zh" ? 6 : 3
        let separator = language == "zh" ? "" : " "

        func window(forSentence sentence: Int) -> String? {
            guard sentence >= 1, sentence <= lineTokens.count, !mapping.isEmpty else { return nil }
            let start = lineStart[sentence - 1], end = start + lineTokens[sentence - 1].count
            let mapped = mapping[start..<end].compactMap { $0 }
            guard let low = mapped.min(), let high = mapped.max() else { return nil }
            return hypothesisTokens[max(0, low - slack)...min(hypothesisTokens.count - 1, high + slack)].joined(separator: separator)
        }
        func matches(_ form: String, in text: String) -> Bool {
            let candidate = separator + Normalizer.tokens(form, language: language).joined(separator: separator) + separator
            guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let padded = separator + text + separator
            return padded.contains(candidate) || Normalizer.stripDiacritics(padded).contains(Normalizer.stripDiacritics(candidate))
        }
        let whole = hypothesisTokens.joined(separator: separator)
        return checks.map { check in
            let text: String?
            if let sentence = check.sentence { text = window(forSentence: sentence) } else { text = whole }
            guard let text else { return CheckOutcome(category: check.category, sentence: check.sentence, passed: false, matched: nil) }
            for form in check.accept where matches(form, in: text) {
                return CheckOutcome(category: check.category, sentence: check.sentence, passed: true, matched: form)
            }
            return CheckOutcome(category: check.category, sentence: check.sentence, passed: false, matched: nil)
        }
    }
}
