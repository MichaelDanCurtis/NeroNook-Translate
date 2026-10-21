import AppKit
import Foundation
import NookPluginSDK
import SwiftUI
import TranslateLive

/// The host side of the app: the loopback channel, the hello/ready handshake, snapshots and the heartbeat,
/// host actions, and the session window. Modelled on Voice's ModuleApp pattern (docs/PROVENANCE.md).
@MainActor final class TranslatePlugin: ObservableObject {
    static let id = "cafe.nero.plugin.translate"
    static let features = ["appearance-v1", "panels-v1", "actions-v1"]

    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    let test = CommandLine.arguments.contains("--protocol-test")
    /// `--self-test <recording> [--hear]`: feed a recording through the pipeline headlessly, print the captions, exit.
    let selfTest: URL? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }()
    let session: LiveSession
    let windows = PluginWindows()
    private let output: PluginOutput
    private let channel: PluginApplicationChannel?
    private var hostSession: UUID?
    private var lines = PluginLines()
    private var publishTimer: Timer?
    private var activity: NSObjectProtocol?
    private var lastSnapshot: PluginSnapshot?

    init() {
        let storage = (try? PluginStorage.directory(id: Self.id))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NeroNookPlugins/\(Self.id)")
        session = LiveSession(storage: storage)
        channel = hosted ? PluginApplicationChannel() : nil
        output = PluginOutput(pluginID: Self.id, channel: channel, test: test)
        if let selfTest {
            NSApplication.shared.setActivationPolicy(.accessory)
            session.configuration.hear = CommandLine.arguments.contains("--hear")
            Task { @MainActor in
                let started = Date()
                let captions = await session.run(file: selfTest)
                var lines = ["self-test: \(captions.count) phrase(s) from \(selfTest.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; \(session.engineStatus)"]
                for caption in captions { lines.append("  " + caption.original); lines.append("    → " + (caption.translated ?? caption.error ?? "(no translation)")) }
                if case .failed(let message) = session.state { lines.append("FAILED: " + message) }
                FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                exit(captions.isEmpty ? 1 : 0)
            }
            return
        }
        guard hosted || test else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Serve Translate")
        if let channel {
            channel.start { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    guard let message else { self.shutdown(); exit(0) }
                    self.receive(message)
                }
            }
        } else if test {
            readStandardInput()
        } else {
            // Launched with --neronook-plugin but without the host's environment: nothing to talk to.
            exit(2)
        }
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.publish() } }
    }

    private func readStandardInput() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self else { return }
                if data.isEmpty { handle.readabilityHandler = nil; self.shutdown(); exit(0) }
                do { for message in try self.lines.append(data) { self.receive(message) } }
                catch { self.shutdown(); exit(1) }
            }
        }
    }

    private func receive(_ message: PluginMessage) {
        guard message.pluginID == Self.id else { shutdown(); exit(1) }
        guard let hostSession else {
            guard message.type == "hello" else { shutdown(); exit(1) }
            self.hostSession = message.session
            output.begin(message.session)
            let offered = Set(message.features ?? [])
            emit("ready", features: Self.features.filter { offered.contains($0) })
            publish(force: true)
            return
        }
        guard message.session == hostSession else { shutdown(); exit(1) }
        switch message.type {
        case "action":
            switch message.action {
            case "configure", "open": showWindow()
            case "start": showWindow(); Task { await session.start() }
            case "stop": Task { await session.stop() }
            default: break
            }
        default:
            break   // appearance, visibility and view events are not used yet
        }
    }

    func showWindow() {
        windows.show("session", title: "Translate", size: CGSize(width: 920, height: 640)) { SessionView(session: session) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func snapshot() -> PluginSnapshot {
        let status: String
        let activity: String
        var actions: [PluginAction] = [PluginAction("open", "Open Translate", symbol: "waveform.and.mic")]
        switch session.state {
        case .idle: status = "Ready"; activity = ""; actions.append(PluginAction("start", "Start listening", symbol: "mic"))
        case .preparing(let step): status = "Preparing"; activity = step
        case .listening:
            status = "Listening · \(Languages.name(session.configuration.sourceLanguage)) → \(Languages.name(session.configuration.targetLanguage))"
            activity = session.partial.isEmpty ? (session.captions.last?.original ?? "") : session.partial
            actions.append(PluginAction("stop", "Stop", symbol: "stop.circle"))
        case .stopping: status = "Stopping"; activity = ""
        case .failed(let message): status = "Stopped: \(String(message.prefix(400)))"; activity = ""; actions.append(PluginAction("start", "Try again", symbol: "mic"))
        }
        let fields = [PluginField("Languages", "\(Languages.name(session.configuration.sourceLanguage)) → \(Languages.name(session.configuration.targetLanguage))"),
                      PluginField("Voice", session.configuration.reference == nil ? "no reference clip" : "prepared from your clip"),
                      PluginField("Engine", session.engineStatus)]
        return PluginSnapshot(title: "Translate", status: status, activity: String(activity.prefix(100)), fields: fields, actions: actions)
    }

    /// Once a second, unconditionally: the host treats a timed snapshot as liveness (as Voice does), and the
    /// protocol test expects several within its window.
    private func publish(force: Bool = false) {
        guard hostSession != nil else { return }
        let next = snapshot()
        output.noteMainProgress()
        do { try next.validate() } catch {
            emit("snapshot", snapshot: PluginSnapshot(title: "Translate", status: "Snapshot invalid: \(error)"))
            return
        }
        lastSnapshot = next
        emit("snapshot", snapshot: next)
    }

    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil) {
        do { try output.emit(type, features: features, snapshot: snapshot) } catch { shutdown(); exit(0) }
    }

    func shutdown() {
        publishTimer?.invalidate(); publishTimer = nil
        session.terminateNow()
        windows.closeAll()
        output.stop()
        channel?.stop()
    }
}

/// Serializes outgoing messages and keeps the heartbeat going while the main thread is alive (the host drops a
/// plugin after 15 s of silence; the heartbeat stops after 30 s without a main-thread publish so a stuck app is
/// still detected). Modelled on Voice's emitter; written for Translate.
final class PluginOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let pluginID: String
    private let channel: PluginApplicationChannel?
    private let test: Bool
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var lastMainProgress = Date()
    private var stopped = false
    private var heartbeat: DispatchSourceTimer?

    init(pluginID: String, channel: PluginApplicationChannel?, test: Bool) { self.pluginID = pluginID; self.channel = channel; self.test = test }

    func begin(_ session: UUID) {
        lock.lock(); self.session = session; sequence = 0; lastMainProgress = Date(); lock.unlock()
        guard channel != nil || test else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Translate.heartbeat"))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.heartbeatIfResponsive() }
        lock.lock()
        if stopped { lock.unlock(); timer.resume(); timer.cancel(); return }
        heartbeat = timer
        lock.unlock()
        timer.resume()
    }

    func noteMainProgress() { lock.lock(); lastMainProgress = Date(); lock.unlock() }

    private func heartbeatIfResponsive() {
        lock.lock(); let recent = !stopped && Date().timeIntervalSince(lastMainProgress) < 30; lock.unlock()
        if recent { try? emit("heartbeat") }
    }

    func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let session else { throw LiveProblem("The plugin connection has ended.") }
        if type != "ready" { sequence += 1 }
        let message = PluginMessage(type: type, pluginID: pluginID, session: session, sequence: sequence, snapshot: snapshot, features: features)
        if let channel { try channel.send(message) } else if test { try FileHandle.standardOutput.write(contentsOf: message.encoded()) }
    }

    func stop() {
        lock.lock(); stopped = true; let timer = heartbeat; heartbeat = nil; lock.unlock()
        timer?.cancel()
    }
}
