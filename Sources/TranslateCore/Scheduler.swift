import Foundation

/// Splits translated text into synthesis units no larger than `maxBytes`, preferring sentence
/// boundaries, then clauses, then words. Only a single oversized word is cut mid-word.
/// Punctuation inside a token ("1.5", "10:30", "1,000", "e.g.") never splits: a Latin ender breaks
/// only when whitespace or the end of the text follows it; full-width CJK punctuation always breaks.
/// Units rejoined with single spaces equal the whitespace-normalized input.
public enum UnitSplitter {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let clauseEnders: Set<Character> = [",", ";", ":", "，", "；", "：", "、"]
    private static let fullWidth: Set<Character> = ["。", "！", "？", "，", "；", "：", "、"]

    public static func split(_ text: String, maxBytes: Int = Bounds.maxSynthesisUnitBytes) -> [String] {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return [] }
        guard normalized.utf8Count > maxBytes else { return [normalized] }
        return pack(pieces(normalized, breakingAfter: sentenceEnders), maxBytes: maxBytes) { sentence in
            pack(pieces(sentence, breakingAfter: clauseEnders), maxBytes: maxBytes) { clause in
                pack(clause.split(separator: " ").map(String.init), maxBytes: maxBytes) { word in
                    hardSplit(word, maxBytes: maxBytes)
                }
            }
        }
    }

    /// Breaks after an ender that is followed by whitespace or the end, or after any full-width ender.
    private static func pieces(_ text: String, breakingAfter enders: Set<Character>) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard enders.contains(character) else { continue }
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next!.isWhitespace || fullWidth.contains(character) {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Greedily joins pieces into units within the bound; an oversized piece is handed to `oversized`.
    private static func pack(_ pieces: [String], maxBytes: Int, oversized: (String) -> [String]) -> [String] {
        var units: [String] = []
        var current = ""
        for piece in pieces {
            if piece.utf8Count > maxBytes {
                if !current.isEmpty { units.append(current); current = "" }
                units.append(contentsOf: oversized(piece))
                continue
            }
            let candidate = current.isEmpty ? piece : current + " " + piece
            if candidate.utf8Count <= maxBytes { current = candidate } else { units.append(current); current = piece }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// Last resort for one oversized word. A single grapheme wider than the bound is kept whole.
    private static func hardSplit(_ word: String, maxBytes: Int) -> [String] {
        var units: [String] = []
        var current = ""
        for character in word {
            if (current + String(character)).utf8Count > maxBytes, !current.isEmpty { units.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { units.append(current) }
        return units
    }
}

/// One phrase piece waiting for, or occupying, the single synthesis executor.
public struct SynthesisUnit: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let utteranceID: UUID
    public let lane: Direction
    public let index: Int            // position within the phrase
    public let total: Int            // units in the phrase
    public let text: String
    public let committedAt: Double   // session clock when the phrase committed
    public let sourceSeconds: Double // this unit's share of the phrase's spoken length, by text size
    public let epoch: UInt64         // lane epoch at enqueue; a bumped epoch means "discard output"
}

public enum BacklogLevel: String, Equatable, Sendable { case ok, behind, over }

/// Backlog counts what is still waiting. The unit being spoken is reported separately in `runningSeconds`.
public struct Backlog: Equatable, Sendable {
    public var phrases: Int
    public var queuedSeconds: Double
    public var oldestAge: Double
    public var runningSeconds: Double
    public var level: BacklogLevel
}

/// Two lanes, one executor. The unit of work is one sentence-sized unit (§2.3). Across lanes the
/// oldest committed phrase goes first, so between two units of my phrase an older phrase from the
/// other lane may take its turn: the lanes play to different listeners, and unit-level interleaving
/// bounds each person's lag without garbling either. A running unit is never pre-empted; Stop/Mute
/// bump the lane epoch so its output is discarded while it finishes (plan §2.4, D‑8).
/// Not thread-safe: the owner serializes calls.
public final class SynthesisScheduler {
    public struct Lane: Equatable, Sendable {
        public var epoch: UInt64 = 0
        public var queue: [SynthesisUnit] = []
        public var running: SynthesisUnit?
    }
    public struct StopResult: Equatable, Sendable {
        public var dropped: [SynthesisUnit]
        public var discarded: SynthesisUnit?
    }

    public private(set) var lanes: [Direction: Lane] = [.incoming: Lane(), .outgoing: Lane()]
    private let maxUnitBytes: Int

    public init(maxUnitBytes: Int = Bounds.maxSynthesisUnitBytes) { self.maxUnitBytes = maxUnitBytes }

    public var running: SynthesisUnit? { lanes.values.compactMap(\.running).first }
    public var executorBusy: Bool { running != nil }
    public func epoch(_ lane: Direction) -> UInt64 { lanes[lane]!.epoch }
    public func queued(_ lane: Direction) -> [SynthesisUnit] { lanes[lane]!.queue }

    /// Splits a committed phrase into bounded units and queues them, sharing the phrase's spoken
    /// seconds across units in proportion to their text so backlog accounting stays right as units drain.
    @discardableResult
    public func enqueue(utteranceID: UUID, lane: Direction, text: String, committedAt: Double, sourceSeconds: Double) -> [SynthesisUnit] {
        let parts = UnitSplitter.split(text, maxBytes: maxUnitBytes)
        let totalBytes = max(parts.reduce(0) { $0 + $1.utf8Count }, 1)
        let epoch = lanes[lane]!.epoch
        let units = parts.enumerated().map { index, part in
            SynthesisUnit(id: UUID(), utteranceID: utteranceID, lane: lane, index: index, total: parts.count, text: part,
                          committedAt: committedAt, sourceSeconds: sourceSeconds * Double(part.utf8Count) / Double(totalBytes), epoch: epoch)
        }
        // Keep the lane ordered by commit time so "oldest first" holds even if phrases arrive out of order;
        // units of one phrase share a commit time and stay in index order.
        let position = lanes[lane]!.queue.firstIndex { $0.committedAt > committedAt } ?? lanes[lane]!.queue.endIndex
        lanes[lane]!.queue.insert(contentsOf: units, at: position)
        return units
    }

    /// The next unit for the executor: the oldest committed phrase across lanes, incoming first on ties.
    /// Returns nil while a unit is running, including a discarded one that has not finished.
    public func next() -> SynthesisUnit? {
        guard !executorBusy else { return nil }
        var best: (Direction, SynthesisUnit)?
        for lane in Direction.allCases {
            guard let head = lanes[lane]!.queue.first else { continue }
            if let current = best, current.1.committedAt <= head.committedAt { continue }
            best = (lane, head)
        }
        guard let (lane, unit) = best else { return nil }
        lanes[lane]!.queue.removeFirst()
        lanes[lane]!.running = unit
        return unit
    }

    /// The executor finished (played, failed, or finished-and-discarded) the running unit.
    @discardableResult
    public func finish(_ unitID: UUID) -> SynthesisUnit? {
        for lane in Direction.allCases where lanes[lane]!.running?.id == unitID {
            let unit = lanes[lane]!.running
            lanes[lane]!.running = nil
            return unit
        }
        return nil
    }

    /// True when the unit's output may still be played; false once its lane epoch moved on.
    public func isCurrent(_ unit: SynthesisUnit) -> Bool { unit.epoch == lanes[unit.lane]!.epoch }

    /// Stop or Mute for one lane: queued units are dropped at once; the running unit, if any,
    /// keeps the executor until it finishes but its output is discarded.
    public func stop(_ lane: Direction) -> StopResult {
        lanes[lane]!.epoch += 1
        let dropped = lanes[lane]!.queue
        lanes[lane]!.queue = []
        return StopResult(dropped: dropped, discarded: lanes[lane]!.running)
    }

    public func stopAll() -> [Direction: StopResult] {
        var results: [Direction: StopResult] = [:]
        for lane in Direction.allCases { results[lane] = stop(lane) }
        return results
    }

    /// "Skip speech to live": drops queued units without touching the running one or the epoch.
    /// The caller marks the returned units `omitted` in captions and in the record.
    public func skipToLive(_ lane: Direction) -> [SynthesisUnit] {
        let dropped = lanes[lane]!.queue
        lanes[lane]!.queue = []
        return dropped
    }

    public func backlog(_ lane: Direction, now: Double) -> Backlog {
        let queue = lanes[lane]!.queue
        let phrases = Set(queue.map(\.utteranceID)).count
        let seconds = queue.reduce(0) { $0 + $1.sourceSeconds }
        let oldest = queue.map { now - $0.committedAt }.max() ?? 0
        let running = lanes[lane]!.running?.sourceSeconds ?? 0
        let level: BacklogLevel
        if seconds >= Bounds.hardBacklogSeconds || oldest >= Bounds.hardBacklogSeconds { level = .over }
        else if phrases >= Bounds.softBacklogPhrases || seconds >= Bounds.softBacklogSeconds || oldest >= Bounds.softBacklogSeconds { level = .behind }
        else { level = .ok }
        return Backlog(phrases: phrases, queuedSeconds: seconds, oldestAge: oldest, runningSeconds: running, level: level)
    }
}
