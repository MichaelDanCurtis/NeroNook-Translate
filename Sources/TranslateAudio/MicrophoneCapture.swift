import AVFoundation
import AudioToolbox
import CoreAudio

/// Mono Float32 chunks from one input device, resampled to the requested rate.
///
/// The app is responsible for microphone permission (`AVCaptureDevice.requestAccess(for: .audio)`); without it
/// macOS delivers silence rather than an error.
@MainActor public final class MicrophoneCapture {
    /// RMS level of the latest chunk, 0…1 (linear). Computed on the tap thread, published on the main actor;
    /// 0 when stopped.
    public private(set) var level: Float = 0
    /// Called on the main actor with each new `level`.
    public var onLevel: ((Float) -> Void)?
    /// Called on the main actor when capture dies on its own (the engine reported a configuration change, the
    /// device was unplugged, or conversion failed). Capture is already stopped and the stream finished by then.
    public var onFailure: ((String) -> Void)?
    /// Whether a capture started by `start` is still running.
    public var isRunning: Bool { session != nil }

    private var session: CaptureSession?
    private var sessionCount = 0

    public init() {}

    /// Starts capture and returns its chunks.
    ///
    /// - Parameters:
    ///   - deviceUID: an `AudioInputDevice.id`, or nil for the system default input.
    ///   - sampleRate: the rate of the delivered samples (16 kHz for the recognizer).
    ///   - chunkSeconds: the length of each chunk; chunks hold `round(sampleRate × chunkSeconds)` samples.
    /// - Returns: chunks of mono Float32 at `sampleRate`, in order, with no gaps or overlap. The hardware format is
    ///   converted with an `AVAudioConverter` (multichannel input is downmixed). The stream finishes when `stop()` is
    ///   called or capture fails; the last chunk before it finishes may be shorter (the remainder is not dropped).
    ///   The stream buffers without limit (about 64 KB per second at 16 kHz), so a slow reader never causes a gap.
    ///   If the reader cancels or drops the stream, capture stops.
    /// - Throws: `AudioProblem` if the arguments are invalid, the device is not connected, or the engine cannot start.
    ///
    /// Calling `start` while running stops the previous capture first (its stream finishes).
    public func start(deviceUID: String?, sampleRate: Double = 16_000, chunkSeconds: Double = 0.1) throws -> AsyncStream<[Float]> {
        stop()
        guard let targetFormat = PCMBuffers.monoFloatFormat(sampleRate: sampleRate) else {
            throw AudioProblem("The capture sample rate \(sampleRate) Hz is not valid.")
        }
        guard chunkSeconds > 0, chunkSeconds.isFinite else {
            throw AudioProblem("The capture chunk length \(chunkSeconds) s is not valid.")
        }
        let chunkSize = max(1, Int((sampleRate * chunkSeconds).rounded()))

        var selectedDevice: AudioDeviceID?
        if let deviceUID {
            guard let found = AudioDevices.deviceID(forUID: deviceUID) else {
                throw AudioProblem("The selected microphone is not connected.")
            }
            selectedDevice = found
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let selectedDevice {
            guard let unit = input.audioUnit else { throw AudioProblem("The microphone input cannot be configured.") }
            var device = selectedDevice
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioProblem("Could not select the microphone (CoreAudio error \(status)).") }
        }
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioProblem("The microphone reports no usable input format.")
        }

        sessionCount += 1
        let id = sessionCount
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        let processor = CaptureProcessor(
            target: targetFormat,
            chunkSize: chunkSize,
            continuation: continuation,
            reportLevel: { [weak self] value in
                Task { @MainActor in self?.publish(level: value, session: id) }
            },
            reportFailure: { [weak self] message in
                Task { @MainActor in self?.fail(message, session: id) }
            }
        )
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.stop(session: id) }
        }

        // Tap in the node's own format (nil): asking for an explicit format fails hard if it does not match the
        // hardware rate, which can lag behind a device change. The processor converts whatever arrives.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            processor.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            processor.finish()
            throw AudioProblem("The microphone could not start: \(error.localizedDescription)")
        }

        let session = CaptureSession(id: id, engine: engine, processor: processor)
        session.configurationObservation = NotificationObservation(.AVAudioEngineConfigurationChange, object: engine) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fail("The audio input changed (device or format), so capture stopped.", session: id)
            }
        }
        if let deviceInUse = Self.currentDevice(of: input) ?? selectedDevice {
            session.deviceWatch = DeviceAliveWatch(deviceID: deviceInUse) { [weak self] in
                self?.fail("The microphone was disconnected.", session: id)
            }
        }
        self.session = session
        return stream
    }

    /// Stops capture: removes the tap, stops the engine, delivers what is still held and finishes the stream.
    /// Does nothing when not running.
    public func stop() {
        guard let session else { return }
        self.session = nil
        session.close()
        level = 0
        onLevel?(0)
    }

    // MARK: - Private

    private func stop(session id: Int) {
        guard session?.id == id else { return }
        stop()
    }

    private func fail(_ message: String, session id: Int) {
        guard session?.id == id else { return }
        stop()
        onFailure?(message)
    }

    private func publish(level value: Float, session id: Int) {
        guard session?.id == id else { return }
        level = value
        onLevel?(value)
    }

    /// The device the input unit is actually using (the default input when none was selected).
    private static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}

/// One running capture: the engine with its tap, the observers that end it, and the processor feeding the stream.
private final class CaptureSession {
    let id: Int
    let engine: AVAudioEngine
    let processor: CaptureProcessor
    var configurationObservation: NotificationObservation?
    var deviceWatch: DeviceAliveWatch?
    private var closed = false

    init(id: Int, engine: AVAudioEngine, processor: CaptureProcessor) {
        self.id = id
        self.engine = engine
        self.processor = processor
    }

    /// Idempotent. Also runs if the owner is released while capturing.
    func close() {
        guard !closed else { return }
        closed = true
        configurationObservation = nil
        deviceWatch = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor.finish()
    }

    deinit { close() }
}

/// Runs on the tap thread: converts each tap buffer to the target format, cuts chunks, yields them and reports
/// levels. `finish()` comes from the main actor; the lock keeps the two apart.
final class CaptureProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var accumulator: ChunkAccumulator
    private let continuation: AsyncStream<[Float]>.Continuation
    private let reportLevel: @Sendable (Float) -> Void
    private let reportFailure: @Sendable (String) -> Void
    private var finished = false
    private var failed = false

    init(
        target: AVAudioFormat,
        chunkSize: Int,
        continuation: AsyncStream<[Float]>.Continuation,
        reportLevel: @escaping @Sendable (Float) -> Void,
        reportFailure: @escaping @Sendable (String) -> Void
    ) {
        self.target = target
        self.accumulator = ChunkAccumulator(chunkSize: chunkSize)
        self.continuation = continuation
        self.reportLevel = reportLevel
        self.reportFailure = reportFailure
    }

    /// One tap buffer in the input node's format.
    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed else { return }
        do {
            let converted = try PCMBuffers.convert(buffer, to: target, with: converter(for: buffer.format))
            deliver(PCMBuffers.samples(converted))
        } catch {
            failed = true
            reportFailure("Microphone audio could not be converted: \(error)")
        }
    }

    /// Delivers what is still held (the converter's last frames, a partial chunk) and finishes the stream. Idempotent.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if !failed, let converter, let tail = try? PCMBuffers.flush(converter) {
            deliver(PCMBuffers.samples(tail))
        }
        if let rest = accumulator.flush() { continuation.yield(rest) }
        continuation.finish()
    }

    /// Created from the first buffer's format, and again only if the format changes (the stream continues).
    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, PCMBuffers.sameLayout(converter.inputFormat, format) { return converter }
        guard let made = AVAudioConverter(from: format, to: target) else {
            throw AudioProblem("no converter from \(Int(format.sampleRate)) Hz, \(format.channelCount) channels")
        }
        made.downmix = true
        converter = made
        return made
    }

    private func deliver(_ samples: [Float]) {
        let chunks = accumulator.append(samples)
        for chunk in chunks { continuation.yield(chunk) }
        if let last = chunks.last { reportLevel(Levels.rms(last)) }
    }
}
