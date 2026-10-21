import AVFoundation

/// Plays mono Float32 chunks on the default output through an `AVAudioPlayerNode`, converting them to the output
/// device's sample rate. Chunks play back to back in the order given.
///
/// The player is connected to the main mixer as mono at the device rate; the mixer spreads it over the output
/// channels. If the output device or its format changes, the engine stops itself: queued audio is discarded
/// (`drain()` returns), the player is reconnected at the new rate and the engine restarts, so later chunks play.
@MainActor public final class SpeechPlayback {
    /// RMS level of what the player is rendering now, 0…1 (linear), from a tap on the player node; 0 when idle.
    public private(set) var level: Float = 0
    /// Called on the main actor with each new `level` while audio plays, and once with 0 when it ends.
    public var onLevel: ((Float) -> Void)?
    /// Whether scheduled audio has not finished playing yet.
    public var isPlaying: Bool { outstanding > 0 }

    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    /// Mono Float32 at the output device's rate; nil until `start()` connects the player.
    private var format: AVAudioFormat?
    /// One streaming converter per input sample rate.
    private var converters: [Double: AVAudioConverter] = [:]
    private var configurationObservation: NotificationObservation?
    private var levelTapInstalled = false
    /// Buffers scheduled whose `.dataPlayedBack` completion has not arrived.
    private var outstanding = 0
    /// Where the last scheduled buffer ends on the player's timeline (player sample time, `format` rate).
    private var scheduledEnd: AVAudioFramePosition = 0
    /// Bumped by `stop()` so completions of discarded buffers are ignored.
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates nothing that touches audio hardware; `start()` does.
    public init() {}

    /// Builds the engine on first use, connects the player at the output device's rate and starts the engine.
    /// Idempotent. Throws `AudioProblem` when there is no output device or the engine cannot start.
    public func start() throws {
        let engine = self.engine ?? makeEngine()
        if format == nil { try connect(engine) }
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioProblem("Audio output could not start: \(error.localizedDescription)")
        }
    }

    /// Converts `samples` (mono Float32 at `sampleRate`) to the output rate and schedules them after everything
    /// already scheduled. Throws `AudioProblem` if playback is not started or the rate cannot be converted.
    ///
    /// The sample-rate converter for each input rate is kept between calls, so consecutive chunks of one stream join
    /// without clicks; it holds back a few frames, which `drain()` pushes out.
    public func enqueue(_ samples: [Float], sampleRate: Double) throws {
        guard let engine, engine.isRunning, let format else { throw AudioProblem("Speech playback is not started.") }
        guard !samples.isEmpty else { return }
        guard let chunk = PCMBuffers.buffer(samples, sampleRate: sampleRate) else {
            throw AudioProblem("Cannot play audio at \(sampleRate) Hz.")
        }
        if sampleRate == format.sampleRate {
            schedule(chunk)
        } else {
            schedule(try PCMBuffers.convert(chunk, to: format, with: converter(from: sampleRate, to: format)))
        }
    }

    /// Audio scheduled but not yet played, in seconds: from the scheduled durations and the player's render position.
    /// An estimate; it does not include the output device's latency.
    public var pendingSeconds: Double {
        guard let format, outstanding > 0 else { return 0 }
        let rendered = renderedFrames() ?? 0
        return Double(max(0, scheduledEnd - rendered)) / format.sampleRate
    }

    /// Returns when everything scheduled has finished playing, or when `stop()` is called. First pushes out the
    /// frames the converters still hold (so the end of the last chunk is heard) and resets them for the next stream.
    /// Not cancellable: call `stop()` to end it early.
    public func drain() async {
        flushConverters()
        guard outstanding > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Stops the player and discards queued audio; `drain()` callers resume. The engine stays running, so
    /// `enqueue` works again right away.
    public func stop() {
        generation += 1
        if engine != nil { player.stop() }
        outstanding = 0
        scheduledEnd = 0
        for converter in converters.values { converter.reset() }
        setLevel(0)
        resumeWaiters()
    }

    // MARK: - Private

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.attach(player)
        self.engine = engine
        configurationObservation = NotificationObservation(.AVAudioEngineConfigurationChange, object: engine) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        return engine
    }

    /// Connects the player to the main mixer as mono at the output device's rate, with the level tap on it.
    private func connect(_ engine: AVAudioEngine) throws {
        let deviceRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard let mono = PCMBuffers.monoFloatFormat(sampleRate: deviceRate) else {
            throw AudioProblem("No audio output device is available.")
        }
        if levelTapInstalled {
            player.removeTap(onBus: 0)
            levelTapInstalled = false
        }
        engine.connect(player, to: engine.mainMixerNode, format: mono)
        player.installTap(onBus: 0, bufferSize: 1024, format: mono) { [weak self] buffer, _ in
            let value = Levels.rms(PCMBuffers.samples(buffer))
            Task { @MainActor in self?.publish(level: value) }
        }
        levelTapInstalled = true
        format = mono
        converters.removeAll()
    }

    /// The engine stopped itself because the output hardware changed: discard, reconnect at the new rate, restart.
    /// If that fails, playback stays stopped; `enqueue` throws until `start()` succeeds.
    private func outputChanged() {
        guard engine != nil, format != nil else { return }
        stop()
        format = nil
        try? start()
    }

    private func converter(from rate: Double, to format: AVAudioFormat) throws -> AVAudioConverter {
        if let existing = converters[rate] { return existing }
        guard let source = PCMBuffers.monoFloatFormat(sampleRate: rate),
              let made = AVAudioConverter(from: source, to: format)
        else { throw AudioProblem("Cannot convert \(rate) Hz audio for playback.") }
        converters[rate] = made
        return made
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if !player.isPlaying {
            scheduledEnd = 0
            player.play()
        }
        // A buffer scheduled while the player is starved starts about now, not where the previous one ended.
        let start = max(scheduledEnd, renderedFrames() ?? 0)
        scheduledEnd = start + AVAudioFramePosition(buffer.frameLength)
        outstanding += 1
        let generation = self.generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(generation: generation) }
        }
    }

    private func flushConverters() {
        guard let engine, engine.isRunning, format != nil else {
            for converter in converters.values { converter.reset() }
            return
        }
        for converter in converters.values {
            if let tail = try? PCMBuffers.flush(converter) { schedule(tail) }
        }
    }

    /// The player's render position in frames since it was last started, if it is playing.
    private func renderedFrames() -> AVAudioFramePosition? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return playerTime.sampleTime
    }

    private func played(generation: Int) {
        guard generation == self.generation, outstanding > 0 else { return }
        outstanding -= 1
        guard outstanding == 0 else { return }
        setLevel(0)
        resumeWaiters()
    }

    private func publish(level value: Float) {
        guard isPlaying else { return }
        setLevel(value)
    }

    private func setLevel(_ value: Float) {
        if value == 0 && level == 0 { return }
        level = value
        onLevel?(value)
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}
