/// Cuts a stream of samples into chunks of exactly `chunkSize` samples, in order, with no gaps or overlap.
/// Used by `MicrophoneCapture`; a pure value type so it can be tested without audio.
public struct ChunkAccumulator: Sendable {
    /// Samples per chunk; at least 1 (smaller values given to `init` are raised to 1).
    public let chunkSize: Int
    private var pending: [Float] = []

    public init(chunkSize: Int) {
        self.chunkSize = max(1, chunkSize)
    }

    /// Adds `samples` and returns every chunk that is now complete, oldest first.
    /// Samples that do not fill a chunk yet are kept for the next call.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        guard pending.count >= chunkSize else { return [] }
        var chunks: [[Float]] = []
        var start = 0
        while pending.count - start >= chunkSize {
            chunks.append(Array(pending[start ..< start + chunkSize]))
            start += chunkSize
        }
        pending.removeFirst(start)
        return chunks
    }

    /// Returns the kept remainder (shorter than a chunk), if any, and empties the accumulator.
    public mutating func flush() -> [Float]? {
        guard !pending.isEmpty else { return nil }
        let rest = pending
        pending.removeAll(keepingCapacity: true)
        return rest
    }
}
