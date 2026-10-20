import Darwin
import Foundation

/// Owns one helper process (TranslateEngine or TranslateASR): spawns it under sandbox-exec, speaks the
/// framed protocol on its stdin and stdout, and routes replies by request id. Replies are consumed by
/// one ordered task, so frames of one request arrive in order. A dead helper surfaces as an error on
/// every outstanding request, never as a signal: the write side ignores SIGPIPE.
public actor HelperClient {
    nonisolated public let ready: EngineFrame.Message
    nonisolated public let startupMs: Int

    private let process: Process
    private let input: FileHandle
    private var pending: [String: CheckedContinuation<EngineFrame.Message, Error>] = [:]
    private var subscriptions: [String: AsyncThrowingStream<EngineFrame.Message, Error>.Continuation] = [:]
    private var exited = false
    private var consumer: Task<Void, Never>?

    /// No network, microphone or camera; no writes under the home folder except caches, so a helper can
    /// read checkpoints and voices but never alter them. The temporary folder stays writable for Metal.
    public static var sandboxProfile: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let temporary = FileManager.default.temporaryDirectory.path
        return "(version 1)(allow default)(deny network*)(deny device-microphone)(deny device-camera)"
            + "(deny file-write* (subpath \"\(home)\"))(allow file-write* (subpath \"\(home)/Library/Caches\") (subpath \"\(temporary)\"))"
    }

    /// Spawns the helper and waits for its first frame, which must be `ready`. On any failure the helper is terminated.
    public static func launch(helper: URL, arguments: [String], log: URL? = nil, timeout: TimeInterval = 120) async throws -> HelperClient {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandboxProfile, helper.path] + arguments
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
                               "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8",
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if let log {
            // Append, so helpers sharing a log or relaunching never overwrite each other's lines.
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { throw EngineClientProblem("Cannot open the helper log at \(log.path).") }
            process.standardError = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

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
            continuation.finish(throwing: EngineClientProblem("The helper did not become ready in time."))
        }
        var iterator = frames.makeAsyncIterator()
        let first: EngineFrame.Message?
        do { first = try await iterator.next() } catch { deadline.cancel(); process.terminate(); throw error }
        deadline.cancel()
        guard let first, first.type == "ready" else {
            process.terminate()
            throw EngineClientProblem(first?.string("message") ?? "The helper exited before reporting ready.")
        }
        let client = HelperClient(process: process, input: stdin.fileHandleForWriting, ready: first,
                                  startupMs: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()))
        await client.startConsuming(iterator)
        process.terminationHandler = { _ in Task { await client.processExited() } }
        if !process.isRunning { await client.processExited() }
        return client
    }

    private init(process: Process, input: FileHandle, ready: EngineFrame.Message, startupMs: Int) {
        self.process = process; self.input = input; self.ready = ready; self.startupMs = startupMs
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
                await self?.failAll(EngineClientProblem("The helper closed its output."))
            } catch {
                await self?.failAll(error)
            }
        }
    }

    // MARK: Requests

    /// Writes one frame with no reply expected (for example `cancel`). A frame that cannot be encoded is
    /// the caller's error and leaves the helper untouched; a failed write means the helper is gone.
    public func send(_ header: [String: Any], payload: Data = Data()) throws {
        guard !exited else { throw EngineClientProblem("The helper has exited.") }
        try write(try EngineFrame.encode(header, payload: payload))
    }

    private func write(_ frame: Data) throws {
        do { try input.write(contentsOf: frame) } catch {
            failAll(EngineClientProblem("The helper stopped accepting requests."))
            throw EngineClientProblem("The helper stopped accepting requests.")
        }
    }

    /// One request, one reply (routed by id). An `error` reply with the id throws. With `timeout`, a reply
    /// that does not arrive in time fails this request alone; a late reply is then dropped.
    public func request(_ header: [String: Any], payload: Data = Data(), timeout: TimeInterval? = nil) async throws -> EngineFrame.Message {
        var header = header
        let id = header["id"] as? String ?? UUID().uuidString
        header["id"] = id
        guard !exited else { throw EngineClientProblem("The helper has exited.") }
        let frame = try EngineFrame.encode(header, payload: payload)
        let deadline: Task<Void, Never>? = timeout.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expire(id, after: seconds)
            }
        }
        defer { deadline?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(frame) } catch {
                // `write` has already failed every pending request, this one included; only resume it here if it is still waiting.
                if let waiter = pending.removeValue(forKey: id) { waiter.resume(throwing: error) }
            }
        }
    }

    private func expire(_ id: String, after seconds: TimeInterval) {
        if let waiter = pending.removeValue(forKey: id) { waiter.resume(throwing: EngineClientProblem("No reply within \(Int(seconds)) s.")) }
    }

    /// A request with many replies: every frame carrying `id` is delivered until `finish(id)` or an error.
    public func subscribe(_ id: String, header: [String: Any], payload: Data = Data()) -> AsyncThrowingStream<EngineFrame.Message, Error> {
        let (stream, continuation) = AsyncThrowingStream<EngineFrame.Message, Error>.makeStream(bufferingPolicy: .unbounded)
        var header = header
        header["id"] = id
        let frame: Data
        do { frame = try EngineFrame.encode(header, payload: payload) } catch { continuation.finish(throwing: error); return stream }
        guard !exited else { continuation.finish(throwing: EngineClientProblem("The helper has exited.")); return stream }
        subscriptions[id] = continuation
        do { try write(frame) } catch { subscriptions.removeValue(forKey: id)?.finish(throwing: error) }
        return stream
    }

    public func finish(_ id: String) {
        subscriptions.removeValue(forKey: id)?.finish()
    }

    /// Asks the helper to exit and waits briefly for it; terminates it if it lingers.
    public func shutdown() async {
        try? send(["type": "shutdown"])
        try? input.close()
        exited = true
        var waited = 0
        while process.isRunning, waited < 250 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        if process.isRunning { process.terminate() }
    }

    public func terminate() { process.terminate(); exited = true }

    // MARK: Replies

    private func receive(_ message: EngineFrame.Message) {
        let id = message.id ?? ""
        if message.type == "error" {
            let error = EngineClientProblem(message.string("message") ?? "Helper error.")
            if id.isEmpty { failAll(error); return }
            if let subscription = subscriptions.removeValue(forKey: id) { subscription.finish(throwing: error) }
            else if let waiter = pending.removeValue(forKey: id) { waiter.resume(throwing: error) }
            return
        }
        if let subscription = subscriptions[id] { subscription.yield(message); return }
        if let waiter = pending.removeValue(forKey: id) { waiter.resume(returning: message) }
    }

    private func processExited() { failAll(EngineClientProblem("The helper exited.")) }

    private func failAll(_ error: Error) {
        exited = true
        for (_, waiter) in pending { waiter.resume(throwing: error) }
        pending = [:]
        for (_, subscription) in subscriptions { subscription.finish(throwing: error) }
        subscriptions = [:]
    }
}
