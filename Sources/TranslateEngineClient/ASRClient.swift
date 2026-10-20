import Foundation

/// One recognizer result, batch or final.
public struct Recognition: Sendable {
    public struct Segment: Sendable { public let text: String; public let start: Double; public let end: Double }
    public let text: String
    public let language: String?
    public let ms: Int
    public let segments: [Segment]
}

public struct Alignment: Sendable {
    public struct Item: Sendable { public let text: String; public let start: Double; public let end: Double }
    public let items: [Item]
    public let ms: Int
}

/// The TranslateASR client: loads backends, recognizes complete clips, runs Nemotron streaming sessions,
/// and aligns known text. Audio is Float32 mono at `sampleRate` (16 kHz).
public actor ASRClient {
    nonisolated public let sampleRate: Int
    nonisolated public let startupMs: Int
    private let helper: HelperClient

    public static func launch(helper url: URL, log: URL? = nil, timeout: TimeInterval = 60) async throws -> ASRClient {
        let helper = try await HelperClient.launch(helper: url, arguments: [], log: log, timeout: timeout)
        guard let rate = helper.ready.int("sampleRate") else { await helper.terminate(); throw EngineClientProblem("The recognizer reported no sample rate.") }
        return ASRClient(helper: helper, sampleRate: rate)
    }

    private init(helper: HelperClient, sampleRate: Int) { self.helper = helper; self.sampleRate = sampleRate; self.startupMs = helper.startupMs }

    public func load(backend: String, model: URL) async throws -> Int {
        let reply = try await helper.request(["type": "load", "backend": backend, "model": model.path], timeout: 600)
        return reply.int("loadMs") ?? -1
    }

    /// Whole-number times decode as Int (the frame reader keeps 0 and 1 integers); read either.
    static func seconds(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let integer = value as? Int { return Double(integer) }
        return -1
    }

    private static func segments(_ message: EngineFrame.Message, key: String = "segments") -> [Recognition.Segment] {
        guard let raw = message.header[key] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            return Recognition.Segment(text: text, start: seconds(item["start"]), end: seconds(item["end"]))
        }
    }

    /// Generous deadlines: a model that stalls fails one row instead of the whole run.
    static func deadline(forAudio samples: Int, rate: Int) -> TimeInterval { max(60, 4 * Double(samples) / Double(rate)) }

    /// Phrase mode: a complete clip in, text out.
    public func transcribe(backend: String, samples: [Float], language: String?, context: String? = nil) async throws -> Recognition {
        var header: [String: Any] = ["type": "transcribe", "backend": backend]
        if let language { header["language"] = language }
        if let context, !context.isEmpty { header["context"] = context }
        let reply = try await helper.request(header, payload: samples.withUnsafeBytes { Data($0) }, timeout: Self.deadline(forAudio: samples.count, rate: sampleRate))
        return Recognition(text: reply.string("text") ?? "", language: reply.string("language"), ms: reply.int("ms") ?? -1, segments: Self.segments(reply))
    }

    /// Nemotron incremental session.
    public func startStream(language: String? = nil, chunkMs: Int = 560) async throws -> String {
        let id = UUID().uuidString
        var header: [String: Any] = ["type": "streamStart", "id": id, "chunkMs": chunkMs]
        if let language { header["language"] = language }
        _ = try await helper.request(header, timeout: 30)
        return id
    }

    public func feed(stream id: String, samples: [Float]) async throws -> (text: String, ms: Int) {
        let reply = try await helper.request(["type": "streamAudio", "id": id], payload: samples.withUnsafeBytes { Data($0) }, timeout: 30)
        return (reply.string("text") ?? "", reply.int("ms") ?? -1)
    }

    public func finish(stream id: String) async throws -> Recognition {
        let reply = try await helper.request(["type": "streamFinish", "id": id], timeout: 60)
        return Recognition(text: reply.string("text") ?? "", language: nil, ms: reply.int("ms") ?? -1, segments: Self.segments(reply))
    }

    public func align(text: String, samples: [Float], language: String) async throws -> Alignment {
        let reply = try await helper.request(["type": "align", "text": text, "language": language], payload: samples.withUnsafeBytes { Data($0) }, timeout: Self.deadline(forAudio: samples.count, rate: sampleRate))
        let items = (reply.header["items"] as? [[String: Any]] ?? []).compactMap { item -> Alignment.Item? in
            guard let text = item["text"] as? String else { return nil }
            return Alignment.Item(text: text, start: Self.seconds(item["start"]), end: Self.seconds(item["end"]))
        }
        return Alignment(items: items, ms: reply.int("ms") ?? -1)
    }

    public func stats() async throws -> EngineStats {
        let reply = try await helper.request(["type": "stats"], timeout: 30)
        return EngineStats(residentBytes: UInt64(reply.int("residentBytes") ?? 0), activeBytes: UInt64(reply.int("activeBytes") ?? 0),
                           peakBytes: UInt64(reply.int("peakBytes") ?? 0), cacheBytes: UInt64(reply.int("cacheBytes") ?? 0))
    }

    public func shutdown() async { await helper.shutdown() }
}
