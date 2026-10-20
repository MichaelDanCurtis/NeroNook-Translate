import Foundation
import TranslateEngineClient

/// Milestone 1b receipts: spawn-to-ready, per-voice preparation, first audio and real-time factor per
/// slot, switching overhead under alternation, discard-to-idle, an overlapped stop-then-start-other-lane
/// stress test, and memory. Writes a JSON receipt and a Markdown summary; prints the summary.
enum EngineBench {
    struct Voice { let slot: String; let reference: URL; let transcript: String; let language: String; let text: String }

    struct Run: Codable {
        var slot: String
        var firstAudioMs: Int
        var generationMs: Int
        var audioSeconds: Double
        var realTimeFactor: Double
        var discarded: Bool
        var wastedMs: Int?
        var framesForwardedAfterCancel: Int
    }

    struct Receipt: Codable {
        var machine: String
        var date: String
        var engine: String
        var model: String
        var diskCache: String
        var spawnToReadyMs: Int
        var loadMs: Int
        var readyResidentMB: Double
        var voices: [String: VoiceReceipt]
        var warmup: [Run]
        var sameSlot: [Run]
        var alternating: [Run]
        var switchOverheadFirstAudioMs: Double
        var discard: DiscardReceipt
        var stress: StressReceipt
        var finalStats: StatsReceipt
    }
    struct VoiceReceipt: Codable { var seconds: Double; var prepareMs: Int; var language: String; var referenceSHA256: String; var residentMBAfter: Double }
    struct DiscardReceipt: Codable { var cancelAfterFirstAudioMs: Int; var wastedMs: Int; var discardedGenerationMs: Int; var nextLaneFirstAudioMsAfterCancel: Int; var framesForwardedAfterCancel: Int }
    struct StressReceipt: Codable {
        var rounds: Int; var errors: Int; var totalSeconds: Double; var maxWastedMs: Int
        var meanNextLaneFirstAudioMsAfterCancel: Double; var maxNextLaneFirstAudioMsAfterCancel: Int
        var roundsWithAudioAfterCancel: Int; var maxFramesForwardedAfterCancel: Int
        var note: String
    }
    struct StatsReceipt: Codable { var residentMB: Double; var activeMB: Double; var peakMB: Double; var cacheMB: Double }

    static func megabytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// One synthesis to completion. With `cancelAfterFirstAudio`, cancels after the first chunk and counts
    /// any frames that still arrive afterwards (at most one chunk can be in flight when the cancel lands).
    static func run(_ client: EngineClient, slot: String, text: String, cancelAfterFirstAudio: Bool = false) async throws -> (Run, cancelledAt: Double?) {
        let id = UUID().uuidString
        var cancelledAt: Double?
        var forwardedAfterCancel = 0
        for try await event in await client.synthesize(id: id, slot: slot, text: text) {
            switch event {
            case .audio(let data, _):
                if cancelAfterFirstAudio, cancelledAt == nil { cancelledAt = uptime(); try await client.cancel(id: id) }
                else if cancelledAt != nil { forwardedAfterCancel += data.count / 4 }
            case .done(let done):
                return (Run(slot: slot, firstAudioMs: done.firstAudioMs, generationMs: done.generationMs, audioSeconds: done.audioSeconds,
                            realTimeFactor: (done.realTimeFactor * 1000).rounded() / 1000, discarded: done.discarded, wastedMs: done.wastedMs,
                            framesForwardedAfterCancel: forwardedAfterCancel), cancelledAt)
            }
        }
        throw EngineClientProblem("Synthesis ended without a done frame.")
    }

    /// The app's real path: cancel the running unit at its first chunk and queue the other lane's unit
    /// immediately, while the discarded generation is still finishing. Returns the discarded run, the
    /// other lane's run, and the wall-clock delay from the cancel to the other lane's first audio.
    static func overlappedRound(_ client: EngineClient, first: Voice, second: Voice) async throws -> (cancelled: Run, next: Run, nextFirstAudioAfterCancelMs: Int) {
        let idA = UUID().uuidString, idB = UUID().uuidString
        var iteratorA = await client.synthesize(id: idA, slot: first.slot, text: first.text).makeAsyncIterator()
        var cancelledAt = uptime()
        while let event = try await iteratorA.next() {
            if case .audio = event { cancelledAt = uptime(); try await client.cancel(id: idA); break }
        }
        let streamB = await client.synthesize(id: idB, slot: second.slot, text: second.text)
        var forwardedAfterCancel = 0
        var doneA: SynthesisDone?
        while let event = try await iteratorA.next() {
            switch event {
            case .audio(let data, _): forwardedAfterCancel += data.count / 4
            case .done(let done): doneA = done
            }
        }
        var firstAudioB: Double?
        var doneB: SynthesisDone?
        for try await event in streamB {
            switch event {
            case .audio: if firstAudioB == nil { firstAudioB = uptime() }
            case .done(let done): doneB = done
            }
        }
        guard let doneA, let doneB, let firstAudioB else { throw EngineClientProblem("A round ended without both done frames.") }
        let cancelled = Run(slot: first.slot, firstAudioMs: doneA.firstAudioMs, generationMs: doneA.generationMs, audioSeconds: doneA.audioSeconds,
                            realTimeFactor: (doneA.realTimeFactor * 1000).rounded() / 1000, discarded: doneA.discarded, wastedMs: doneA.wastedMs,
                            framesForwardedAfterCancel: forwardedAfterCancel)
        let next = Run(slot: second.slot, firstAudioMs: doneB.firstAudioMs, generationMs: doneB.generationMs, audioSeconds: doneB.audioSeconds,
                       realTimeFactor: (doneB.realTimeFactor * 1000).rounded() / 1000, discarded: doneB.discarded, wastedMs: doneB.wastedMs,
                       framesForwardedAfterCancel: 0)
        return (cancelled, next, Int(((firstAudioB - cancelledAt) * 1000).rounded()))
    }

    static func execute(engine: URL, model: URL, voices: [Voice], out: URL, stressRounds: Int) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let client = try await EngineClient.launch(engine: engine, model: model, log: out.appendingPathComponent("engine-stderr.log"))
        defer { Task { await client.shutdown() } }
        print("ready: spawn to ready \(client.startupMs) ms (warm disk cache), model load \(client.loadMs) ms, resident \(megabytes(client.readyResidentBytes)) MB")

        var voiceReceipts: [String: VoiceReceipt] = [:]
        for voice in voices {
            let prepared = try await client.prepareVoice(slot: voice.slot, reference: voice.reference, transcript: voice.transcript, language: voice.language)
            voiceReceipts[voice.slot] = VoiceReceipt(seconds: (prepared.seconds * 100).rounded() / 100, prepareMs: prepared.prepareMs, language: prepared.language,
                                                     referenceSHA256: prepared.referenceSHA256, residentMBAfter: megabytes(prepared.residentBytes))
            print("prepared \(voice.slot): \(String(format: "%.1f", prepared.seconds)) s reference → \(prepared.prepareMs) ms, language \(prepared.language)")
        }

        // Warm-up: the first generation pays one-time costs that are not switching overhead.
        var warmup: [Run] = []
        for voice in voices { warmup.append(try await run(client, slot: voice.slot, text: voice.text).0) }

        // Same slot repeated: the baseline with no reference switching.
        var sameSlot: [Run] = []
        for voice in voices { for _ in 0..<3 { sameSlot.append(try await run(client, slot: voice.slot, text: voice.text).0) } }

        // Alternating slots: any difference in first audio is the switching overhead. (The generation path
        // keeps no reference-keyed state, so a result near zero shows that the switch is just a pointer.)
        var alternating: [Run] = []
        for index in 0..<12 { let voice = voices[index % voices.count]; alternating.append(try await run(client, slot: voice.slot, text: voice.text).0) }
        let meanSame = Double(sameSlot.map(\.firstAudioMs).reduce(0, +)) / Double(max(sameSlot.count, 1))
        let meanAlternating = Double(alternating.map(\.firstAudioMs).reduce(0, +)) / Double(max(alternating.count, 1))
        let overhead = ((meanAlternating - meanSame) * 10).rounded() / 10
        print("first audio: same slot \(String(format: "%.0f", meanSame)) ms, alternating \(String(format: "%.0f", meanAlternating)) ms → switch overhead \(overhead) ms")

        // Discard-to-idle, overlapped like the app: cancel after the first frame and queue the other lane at once.
        let (discardedRun, nextRun, nextAfterCancel) = try await overlappedRound(client, first: voices[0], second: voices[min(1, voices.count - 1)])
        let discard = DiscardReceipt(cancelAfterFirstAudioMs: discardedRun.firstAudioMs, wastedMs: discardedRun.wastedMs ?? -1,
                                     discardedGenerationMs: discardedRun.generationMs, nextLaneFirstAudioMsAfterCancel: nextAfterCancel,
                                     framesForwardedAfterCancel: discardedRun.framesForwardedAfterCancel)
        print("discard: cancelled at \(discard.cancelAfterFirstAudioMs) ms; generation ran \(discard.discardedGenerationMs) ms, \(discard.wastedMs) ms of it after the cancel; \(discard.framesForwardedAfterCancel) frames arrived after the cancel; the other lane's first audio came \(nextAfterCancel) ms after the cancel (its own first audio \(nextRun.firstAudioMs) ms)")

        // Stress: overlapped stop-then-start-other-lane, many times.
        var errors = 0, maxWasted = 0, maxForwarded = 0, roundsWithAudioAfterCancel = 0
        var nextFirst: [Int] = []
        let stressStarted = uptime()
        for round in 0..<stressRounds {
            let first = voices[round % voices.count], second = voices[(round + 1) % voices.count]
            do {
                let (cancelled, next, after) = try await overlappedRound(client, first: first, second: second)
                guard cancelled.discarded else { throw EngineClientProblem("Round \(round): the cancelled run was not marked discarded.") }
                guard !next.discarded, next.audioSeconds > 0.3, next.realTimeFactor < 1 else { throw EngineClientProblem("Round \(round): the next lane's run looks wrong (\(next.audioSeconds) s, RTF \(next.realTimeFactor)).") }
                maxWasted = max(maxWasted, cancelled.wastedMs ?? 0)
                maxForwarded = max(maxForwarded, cancelled.framesForwardedAfterCancel)
                if cancelled.framesForwardedAfterCancel > 0 { roundsWithAudioAfterCancel += 1 }
                nextFirst.append(after)
            } catch {
                errors += 1
                print("stress round \(round) failed: \(error)")
                if errors > 3 { break }
            }
        }
        let stress = StressReceipt(rounds: stressRounds, errors: errors, totalSeconds: ((uptime() - stressStarted) * 10).rounded() / 10, maxWastedMs: maxWasted,
                                   meanNextLaneFirstAudioMsAfterCancel: nextFirst.isEmpty ? -1 : (Double(nextFirst.reduce(0, +)) / Double(nextFirst.count) * 10).rounded() / 10,
                                   maxNextLaneFirstAudioMsAfterCancel: nextFirst.max() ?? -1, roundsWithAudioAfterCancel: roundsWithAudioAfterCancel,
                                   maxFramesForwardedAfterCancel: maxForwarded,
                                   note: "Each round cancels lane A at its first chunk and queues lane B before A finishes. Frames after cancel count only chunks already in flight when the cancel landed. Audio is checked for presence, duration and RTF, not listened to.")
        print("stress: \(stressRounds) rounds, \(errors) errors, \(stress.totalSeconds) s; max wasted \(maxWasted) ms; other lane's first audio after cancel mean \(stress.meanNextLaneFirstAudioMsAfterCancel) ms, max \(stress.maxNextLaneFirstAudioMsAfterCancel) ms; rounds with any audio after cancel \(roundsWithAudioAfterCancel) (max \(maxForwarded) frames)")

        let stats = try await client.stats()
        let finalStats = StatsReceipt(residentMB: megabytes(stats.residentBytes), activeMB: megabytes(stats.activeBytes), peakMB: megabytes(stats.peakBytes), cacheMB: megabytes(stats.cacheBytes))
        print("memory: resident \(finalStats.residentMB) MB, MLX active \(finalStats.activeMB) MB, peak \(finalStats.peakMB) MB, cache \(finalStats.cacheMB) MB")

        var machine = "unknown"
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 { var buffer = [CChar](repeating: 0, count: size); if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { machine = String(cString: buffer) } }
        let receipt = Receipt(machine: machine, date: ISO8601DateFormatter().string(from: Date()), engine: engine.lastPathComponent, model: model.lastPathComponent,
                              diskCache: "warm (the checkpoint was read recently); cold-cache start is not measured here",
                              spawnToReadyMs: client.startupMs, loadMs: client.loadMs, readyResidentMB: megabytes(client.readyResidentBytes),
                              voices: voiceReceipts, warmup: warmup, sameSlot: sameSlot, alternating: alternating, switchOverheadFirstAudioMs: overhead,
                              discard: discard, stress: stress, finalStats: finalStats)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: out.appendingPathComponent("engine-receipt.json"))

        var summary = "| Measure | Result |\n| --- | --- |\n"
        summary += "| Spawn to ready (warm disk cache) | \(receipt.spawnToReadyMs) ms (model load \(receipt.loadMs) ms) |\n"
        for (slot, v) in voiceReceipts.sorted(by: { $0.key < $1.key }) { summary += "| Prepare `\(slot)` (\(v.seconds) s reference) | \(v.prepareMs) ms |\n" }
        for voice in voices {
            let runs = sameSlot.filter { $0.slot == voice.slot }
            let fa = runs.map(\.firstAudioMs); let rtf = runs.map(\.realTimeFactor)
            summary += "| `\(voice.slot)` first audio / RTF (3 warm runs) | \(fa.map(String.init).joined(separator: ", ")) ms / \(rtf.map { String(format: "%.2f", $0) }.joined(separator: ", ")) |\n"
        }
        summary += "| Switch overhead (alternating − same slot, mean first audio) | \(overhead) ms |\n"
        summary += "| Discard-to-idle (overlapped) | cancel at \(discard.cancelAfterFirstAudioMs) ms; generation ran \(discard.discardedGenerationMs) ms, \(discard.wastedMs) ms after the cancel; \(discard.framesForwardedAfterCancel) frames after cancel; other lane's first audio \(nextAfterCancel) ms after cancel |\n"
        summary += "| Stress \(stressRounds)× overlapped stop then start other lane | \(errors) errors in \(stress.totalSeconds) s; max wasted \(maxWasted) ms; other lane first audio after cancel mean \(stress.meanNextLaneFirstAudioMsAfterCancel) ms, max \(stress.maxNextLaneFirstAudioMsAfterCancel) ms; audio after cancel in \(roundsWithAudioAfterCancel) rounds (max \(maxForwarded) frames) |\n"
        summary += "| Memory at end | resident \(finalStats.residentMB) MB; MLX active \(finalStats.activeMB) MB, peak \(finalStats.peakMB) MB |\n"
        try summary.write(to: out.appendingPathComponent("engine-summary.md"), atomically: true, encoding: .utf8)
        print(summary)
    }
}
