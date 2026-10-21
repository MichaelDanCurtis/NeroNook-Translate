import Foundation
import TranslateAudio
import TranslateCore
import TranslateEngineClient

/// One lane's spoken output: translated phrases are split into bounded units (Core's UnitSplitter),
/// synthesized in order on the engine and streamed to playback as they arrive. `stop` drops the queue
/// and cancels the unit in flight; the engine finishes that unit and discards it (D‑8).
public actor SynthesisQueue {
    public struct Progress: Sendable, Equatable {
        public var queued: Int
        public var speaking: Bool
        public var lastFirstAudioMs: Int?
        public var lastRealTimeFactor: Double?
        public var lastError: String?
    }

    private struct Unit { let id: String; let text: String; let slot: String }
    private let engine: EngineClient
    private let playback: SpeechPlayback
    private var queue: [Unit] = []
    private var running = false
    private var currentID: String?
    private var epoch = 0
    private var progress = Progress(queued: 0, speaking: false)
    private var onProgress: (@Sendable (Progress) -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(engine: EngineClient, playback: SpeechPlayback) { self.engine = engine; self.playback = playback }

    /// Returns once nothing is queued or in flight.
    public func waitUntilIdle() async {
        guard running || !queue.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func setProgressHandler(_ handler: @escaping @Sendable (Progress) -> Void) { onProgress = handler }

    public func speak(_ text: String, slot: String) {
        for unit in UnitSplitter.split(text) where !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queue.append(Unit(id: UUID().uuidString, text: unit, slot: slot))
        }
        report()
        pump()
    }

    public func stop() async {
        epoch += 1
        queue.removeAll()
        if let id = currentID { try? await engine.cancel(id: id) }
        await MainActor.run { playback.stop() }
        report()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        let unit = queue.removeFirst()
        running = true
        currentID = unit.id
        let epoch = self.epoch
        report()
        Task { await self.run(unit, epoch: epoch) }
    }

    private func run(_ unit: Unit, epoch: Int) async {
        do {
            for try await event in await engine.synthesize(id: unit.id, slot: unit.slot, text: unit.text) {
                guard epoch == self.epoch else { break }   // stopped meanwhile: the rest of this unit is discarded
                switch event {
                case .audio(let data, let sampleRate):
                    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    let playback = self.playback
                    await MainActor.run { try? playback.enqueue(samples, sampleRate: Double(sampleRate)) }
                case .done(let done):
                    progress.lastFirstAudioMs = done.firstAudioMs
                    progress.lastRealTimeFactor = (done.realTimeFactor * 100).rounded() / 100
                }
            }
            progress.lastError = nil
        } catch {
            progress.lastError = "\(error)"
        }
        running = false
        currentID = nil
        report()
        if epoch == self.epoch { pump() }
    }

    private func report() {
        progress.queued = queue.count
        progress.speaking = running
        onProgress?(progress)
        if !running, queue.isEmpty { for waiter in idleWaiters { waiter.resume() }; idleWaiters.removeAll() }
    }
}
