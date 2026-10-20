import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Statistics the engine reports for one prepared voice.
public struct VoicePrepared: Sendable {
    public let slot: String
    public let seconds: Double
    public let prepareMs: Int
    public let language: String
    public let residentBytes: UInt64
    public let referenceSHA256: String
}

/// What the engine reports when a synthesis finishes, discarded or not.
public struct SynthesisDone: Sendable {
    public let frames: Int
    public let forwardedFrames: Int
    public let sampleRate: Int
    public let firstAudioMs: Int
    public let generationMs: Int
    public let discarded: Bool
    public let wastedMs: Int?
    public var audioSeconds: Double { Double(frames) / Double(sampleRate) }
    /// Generation time divided by audio produced: below 1 means faster than real time.
    public var realTimeFactor: Double { audioSeconds > 0 ? Double(generationMs) / 1000 / audioSeconds : .infinity }
}

public enum SynthesisEvent: Sendable {
    case audio(Data, sampleRate: Int)
    case done(SynthesisDone)
}

public struct EngineStats: Sendable {
    public let residentBytes: UInt64
    public let activeBytes: UInt64
    public let peakBytes: UInt64
    public let cacheBytes: UInt64
}

/// Owns one engine process: spawns it under sandbox-exec, speaks the framed protocol on its stdin and
/// stdout, and routes replies to the waiting request. Replies are consumed by one ordered task, so audio
/// chunks arrive in sequence and `done` can never overtake them. A dead engine surfaces as an error on
/// every outstanding request, never as a signal: the write side ignores SIGPIPE.
public actor EngineClient {
    nonisolated public let sampleRate: Int
    nonisolated public let loadMs: Int
    nonisolated public let startupMs: Int
    nonisolated public let readyResidentBytes: UInt64

    private let process: Process
    private let input: FileHandle
    private var pending: [String: CheckedContinuation<EngineFrame.Message, Error>] = [:]
    private var streams: [String: Stream] = [:]
    private var exited = false
    private var consumer: Task<Void, Never>?

    private struct Stream {
        let continuation: AsyncThrowingStream<SynthesisEvent, Error>.Continuation
        var expectedSeq = 0
    }

    /// No network, microphone or camera; no writes under the home folder except caches, so the engine can
    /// read the checkpoint and voices but never alter them. The temporary folder stays writable for Metal.
    public static var sandboxProfile: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let temporary = FileManager.default.temporaryDirectory.path
        return "(version 1)(allow default)(deny network*)(deny device-microphone)(deny device-camera)"
            + "(deny file-write* (subpath \"\(home)\"))(allow file-write* (subpath \"\(home)/Library/Caches\") (subpath \"\(temporary)\"))"
    }

    /// Spawns the engine and waits for `ready`. On any failure the helper is terminated, never leaked.
    public static func launch(engine: URL, model: URL, log: URL? = nil, timeout: TimeInterval = 120) async throws -> EngineClient {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandboxProfile, engine.path, "--model", model.path]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
                               "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8",
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            process.standardError = try FileHandle(forWritingTo: log)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // One ordered stream of frames: the pipe reader yields, a single consumer delivers.
        let (frames, continuation) = AsyncThrowingStream<EngineFrame.Message, Error>.makeStream()
        let reader = EngineFrame.Reader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish(); handle.readabilityHandler = nil; return }
            do { for message in try reader.feed(data) { continuation.yield(message) } } catch {
                continuation.finish(throwing: error); handle.readabilityHandler = nil
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            continuation.finish(throwing: EngineClientProblem("The engine did not become ready in time."))
        }
        var iterator = frames.makeAsyncIterator()
        let first: EngineFrame.Message?
        do { first = try await iterator.next() } catch {
            deadline.cancel(); process.terminate(); throw error
        }
        deadline.cancel()
        guard let first, first.type == "ready", let sampleRate = first.int("sampleRate") else {
            process.terminate()
            throw EngineClientProblem(first?.string("message") ?? "The engine exited before reporting ready.")
        }
        let client = EngineClient(process: process, input: stdin.fileHandleForWriting, sampleRate: sampleRate, loadMs: first.int("loadMs") ?? -1,
                                  startupMs: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()),
                                  readyResidentBytes: UInt64(first.int("residentBytes") ?? 0))
        await client.startConsuming(iterator)
        process.terminationHandler = { _ in Task { await client.processExited() } }
        if !process.isRunning { await client.processExited() }
        return client
    }

    private init(process: Process, input: FileHandle, sampleRate: Int, loadMs: Int, startupMs: Int, readyResidentBytes: UInt64) {
        self.process = process; self.input = input; self.sampleRate = sampleRate; self.loadMs = loadMs
        self.startupMs = startupMs; self.readyResidentBytes = readyResidentBytes
    }

    deinit {
        consumer?.cancel()
        if process.isRunning { process.terminate() }
    }

    private func startConsuming(_ iterator: AsyncThrowingStream<EngineFrame.Message, Error>.Iterator) {
        var iterator = iterator
        consumer = Task { [weak self] in
            do {
                while let message = try await iterator.next() {
                    guard let self else { return }
                    await self.receive(message)
                }
                await self?.failAll(EngineClientProblem("The engine closed its output."))
            } catch {
                await self?.failAll(error)
            }
        }
    }

    // MARK: Requests

    private func write(_ header: [String: Any], payload: Data = Data()) throws {
        guard !exited else { throw EngineClientProblem("The engine has exited.") }
        do { try input.write(contentsOf: try EngineFrame.encode(header, payload: payload)) } catch {
            // EPIPE instead of SIGPIPE: the engine is gone.
            failAll(EngineClientProblem("The engine stopped accepting requests."))
            throw EngineClientProblem("The engine stopped accepting requests.")
        }
    }

    private func request(_ header: [String: Any], payload: Data = Data()) async throws -> EngineFrame.Message {
        let id = header["id"] as? String ?? UUID().uuidString
        var header = header
        header["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(header, payload: payload) } catch { pending[id] = nil; continuation.resume(throwing: error) }
        }
    }

    /// Decodes a reference recording to the engine's rate (off the actor, so a slow decode never delays
    /// a cancel) and asks the engine to prepare the slot's conditioning.
    public nonisolated func prepareVoice(slot: String, reference: URL, transcript: String, language: String) async throws -> VoicePrepared {
        let bytes = try Data(contentsOf: reference)
        guard bytes.count <= 64 * 1024 * 1024 else { throw EngineClientProblem("Reference file is too large.") }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let samples = try Self.decode(reference, sampleRate: Double(sampleRate))
        let payload = samples.withUnsafeBytes { Data($0) }
        let reply = try await request(["type": "prepareVoice", "slot": slot, "transcript": transcript, "language": language, "sampleRate": sampleRate], payload: payload)
        guard reply.type == "voiceReady" else { throw EngineClientProblem(reply.string("message") ?? "prepareVoice failed.") }
        return VoicePrepared(slot: slot, seconds: reply.double("seconds") ?? 0, prepareMs: reply.int("prepareMs") ?? -1,
                             language: reply.string("language") ?? language, residentBytes: UInt64(reply.int("residentBytes") ?? 0), referenceSHA256: digest)
    }

    /// Streams one synthesis. Audio payloads are Float32 little-endian mono at `sampleRate`, delivered in order.
    public func synthesize(id: String = UUID().uuidString, slot: String, text: String, streamingInterval: Double = 0.32) -> AsyncThrowingStream<SynthesisEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        streams[id] = Stream(continuation: continuation)
        do { try write(["type": "synthesize", "id": id, "slot": slot, "text": text, "streamingInterval": streamingInterval]) } catch {
            streams[id] = nil; continuation.finish(throwing: error)
        }
        return stream
    }

    /// Out of band: the engine stops forwarding this request's audio and lets the generation finish.
    public func cancel(id: String) throws { try write(["type": "cancel", "id": id]) }

    public func stats() async throws -> EngineStats {
        let reply = try await request(["type": "stats"])
        return EngineStats(residentBytes: UInt64(reply.int("residentBytes") ?? 0), activeBytes: UInt64(reply.int("activeBytes") ?? 0),
                           peakBytes: UInt64(reply.int("peakBytes") ?? 0), cacheBytes: UInt64(reply.int("cacheBytes") ?? 0))
    }

    public func ping() async throws { _ = try await request(["type": "ping"]) }

    /// Asks the engine to exit and waits briefly for it; terminates it if it lingers.
    public func shutdown() async {
        try? write(["type": "shutdown"])
        try? input.close()
        exited = true
        var waited = 0
        while process.isRunning, waited < 250 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        if process.isRunning { process.terminate() }
    }

    public func terminate() { process.terminate(); exited = true }

    // MARK: Replies

    private func receive(_ message: EngineFrame.Message) {
        switch message.type {
        case "audio":
            guard let id = message.id, var stream = streams[id] else { return }
            let seq = message.int("seq") ?? -1
            guard seq == stream.expectedSeq else {
                streams[id] = nil
                stream.continuation.finish(throwing: EngineClientProblem("Audio arrived out of order (\(seq) after \(stream.expectedSeq - 1))."))
                return
            }
            stream.expectedSeq += 1
            streams[id] = stream
            stream.continuation.yield(.audio(message.payload, sampleRate: message.int("sampleRate") ?? sampleRate))
        case "done":
            guard let id = message.id, let stream = streams.removeValue(forKey: id) else { return }
            stream.continuation.yield(.done(SynthesisDone(frames: message.int("frames") ?? 0, forwardedFrames: message.int("forwardedFrames") ?? 0,
                                                           sampleRate: message.int("sampleRate") ?? sampleRate, firstAudioMs: message.int("firstAudioMs") ?? -1,
                                                           generationMs: message.int("generationMs") ?? -1, discarded: message.bool("discarded") ?? false,
                                                           wastedMs: message.int("wastedMs"))))
            stream.continuation.finish()
        case "error":
            let error = EngineClientProblem(message.string("message") ?? "Engine error.")
            if let id = message.id, !id.isEmpty {
                if let stream = streams.removeValue(forKey: id) { stream.continuation.finish(throwing: error) }
                else if let waiter = pending.removeValue(forKey: id) { waiter.resume(throwing: error) }
            } else {
                failAll(error)
            }
        default:
            guard let id = message.id, let waiter = pending.removeValue(forKey: id) else { return }
            waiter.resume(returning: message)
        }
    }

    private func processExited() {
        failAll(EngineClientProblem("The engine exited."))
    }

    private func failAll(_ error: Error) {
        exited = true
        for (_, waiter) in pending { waiter.resume(throwing: error) }
        pending = [:]
        for (_, stream) in streams { stream.continuation.finish(throwing: error) }
        streams = [:]
    }

    // MARK: Audio decoding

    /// Any file AVAudioFile reads, converted to mono Float32 at `sampleRate`.
    nonisolated static func decode(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw EngineClientProblem("Unsupported reference format.") }
        let sourceFrames = AVAudioFrameCount(file.length)
        guard sourceFrames > 0, let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceFrames) else { throw EngineClientProblem("Empty reference.") }
        try file.read(into: sourceBuffer)
        let ratio = sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(sourceFrames) * ratio) + 4096) else { throw EngineClientProblem("Could not allocate audio.") }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true; outStatus.pointee = .haveData; return sourceBuffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData else { throw EngineClientProblem("Reference conversion failed.") }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
