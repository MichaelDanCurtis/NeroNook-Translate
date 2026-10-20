import Foundation

public enum CaptionDisplay: String, Codable, Sendable { case original, translated, both }
public enum CaptionError: String, Codable, Sendable { case recognition, translation, speech }

/// One caption line as the compact view shows it. Provisional entries are replaced in place.
public struct CaptionEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { utteranceID }
    public var utteranceID: UUID
    public var lane: Direction
    public var speaker: Speaker
    public var label: String?
    public var sourceLanguage: String
    public var targetLanguage: String
    public var sourceStart: Double
    public var original: String
    public var originalRev: Int
    public var translated: String?
    public var translatedRev: Int?
    public var provisional: Bool
    public var synthesis: SynthesisStatus?
    public var error: CaptionError?

    public init(utteranceID: UUID, lane: Direction, speaker: Speaker, label: String? = nil, sourceLanguage: String, targetLanguage: String,
                sourceStart: Double, original: String, originalRev: Int = 1, translated: String? = nil, translatedRev: Int? = nil,
                provisional: Bool, synthesis: SynthesisStatus? = nil, error: CaptionError? = nil) {
        self.utteranceID = utteranceID; self.lane = lane; self.speaker = speaker; self.label = label
        self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage; self.sourceStart = sourceStart
        self.original = original; self.originalRev = originalRev; self.translated = translated; self.translatedRev = translatedRev
        self.provisional = provisional; self.synthesis = synthesis; self.error = error
    }
}

/// The bounded live window the compact Nook view renders. Its serialized state must fit the
/// custom-view state limit; oldest entries fall off first.
public struct CaptionWindow: Equatable, Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var display: CaptionDisplay
        public var lanes: [String: [CaptionEntry]]
    }

    public private(set) var entries: [Direction: [CaptionEntry]] = [.incoming: [], .outgoing: []]
    public var display: CaptionDisplay
    public var visible: Bool
    private let perLane: Int

    public init(display: CaptionDisplay = .both, visible: Bool = true, perLane: Int = Bounds.liveWindowUtterances) {
        self.display = display; self.visible = visible; self.perLane = perLane
    }

    /// Inserts or replaces by utterance ID. A final entry replaces its provisional predecessor.
    public mutating func upsert(_ entry: CaptionEntry) {
        var lane = entries[entry.lane]!
        if let index = lane.firstIndex(where: { $0.utteranceID == entry.utteranceID }) { lane[index] = entry } else { lane.append(entry) }
        if lane.count > perLane { lane.removeFirst(lane.count - perLane) }
        entries[entry.lane] = lane
    }

    public func entry(_ id: UUID) -> CaptionEntry? {
        for lane in entries.values { if let found = lane.first(where: { $0.utteranceID == id }) { return found } }
        return nil
    }

    /// Serialized view state, trimmed from the oldest entries until it fits `maxBytes`.
    public func state(maxBytes: Int = Bounds.captionStateBytes) throws -> Data {
        var working = entries
        let encoder = SessionJSON.encoder()
        while true {
            let state = State(display: display, lanes: Dictionary(uniqueKeysWithValues: working.map { ($0.key.rawValue, $0.value) }))
            let data = try encoder.encode(state)
            if data.count <= maxBytes { return data }
            // Drop the oldest entry from the lane that takes the most bytes; give up only when both lanes are empty.
            var heaviest: (Direction, Int)?
            for (lane, list) in working where !list.isEmpty {
                let bytes = try encoder.encode(list).count
                if heaviest == nil || bytes > heaviest!.1 { heaviest = (lane, bytes) }
            }
            guard let lane = heaviest?.0 else { throw TranslateProblem("Caption state cannot fit its limit.") }
            working[lane]!.removeFirst()
        }
    }
}
