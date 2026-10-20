import Darwin
import Foundation
import IOKit
import TranslateEngineClient

// Resource sampling for a pass (plan §6.1 footprint; §7 resources): per process, CPU time and physical
// footprint from the kernel plus the MLX counters a helper reports; for the GPU, the device utilization
// the graphics driver publishes through IOKit, polled while the pass runs. Needs no privileges. The GPU
// figure covers everything on the GPU (every helper, and any other app), so it is a load figure for the
// pass, not a per-model cost.

/// The graphics driver's performance statistics (AGXAccelerator, class IOAccelerator).
public enum GPUStatistics {
    public struct Reading: Sendable, Equatable {
        public var devicePercent: Int
        public var rendererPercent: Int
        public var tilerPercent: Int
        public var inUseBytes: UInt64
    }

    public static func read() -> Reading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let statistics = raw as? [String: Any] else { return nil }
        func int(_ key: String) -> Int? { (statistics[key] as? NSNumber)?.intValue }
        guard let device = int("Device Utilization %") else { return nil }
        return Reading(devicePercent: device, rendererPercent: int("Renderer Utilization %") ?? 0, tilerPercent: int("Tiler Utilization %") ?? 0,
                       inUseBytes: (statistics["In use system memory"] as? NSNumber)?.uint64Value ?? 0)
    }
}

/// One process to watch during a pass: its pid, and for helpers the `stats` request that returns MLX counters.
public struct ResourceMonitor: Sendable {
    public let name: String
    public let pid: Int32
    public let stats: (@Sendable () async throws -> EngineStats)?
    public init(name: String, pid: Int32, stats: (@Sendable () async throws -> EngineStats)? = nil) { self.name = name; self.pid = pid; self.stats = stats }
}

public struct ProcessSample: Codable, Sendable {
    public var process: String
    public var cpuSeconds: Double        // during the pass
    public var cpuPercent: Int           // cpuSeconds / wall; 100 is one core
    public var footprintMB: Double       // at the end of the pass
    public var peakFootprintMB: Double   // lifetime peak of the process
    public var mlxActiveMB: Double?
    public var mlxPeakMB: Double?
    public var mlxCacheMB: Double?
}

public struct GPUSample: Codable, Sendable {
    public var meanDevicePercent: Int
    public var maxDevicePercent: Int
    public var meanRendererPercent: Int
    public var samples: Int
    public var inUseMemoryMB: Double     // at the end of the pass
}

public struct PassResources: Codable, Sendable {
    public var wallSeconds: Double
    public var processes: [ProcessSample]
    public var gpu: GPUSample?
}

/// Brackets one pass: `begin()` snapshots every process and starts polling the GPU; `end()` returns the deltas.
public actor ResourceSampler {
    let monitors: [ResourceMonitor]
    let interval: Double
    private var started = 0.0
    private var before: [String: ProcessUsage] = [:]
    private var polling: Task<Void, Never>?
    private var deviceSum = 0, deviceMax = 0, rendererSum = 0, samples = 0
    private var last: GPUStatistics.Reading?

    public init(monitors: [ResourceMonitor], interval: Double = 0.25) { self.monitors = monitors; self.interval = interval }

    public func begin() {
        started = uptime()
        before = [:]
        for monitor in monitors { before[monitor.name] = ProcessUsage.read(pid: monitor.pid) }
        deviceSum = 0; deviceMax = 0; rendererSum = 0; samples = 0; last = nil
        polling = Task { [interval] in
            while !Task.isCancelled {
                self.record(GPUStatistics.read())
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func record(_ reading: GPUStatistics.Reading?) {
        guard let reading else { return }
        deviceSum += reading.devicePercent; deviceMax = max(deviceMax, reading.devicePercent); rendererSum += reading.rendererPercent
        samples += 1; last = reading
    }

    public func end() async -> PassResources {
        polling?.cancel()
        await polling?.value
        polling = nil
        let wall = max(0.001, uptime() - started)
        var processes: [ProcessSample] = []
        for monitor in monitors {
            guard let now = ProcessUsage.read(pid: monitor.pid) else { continue }
            let cpu = max(0, now.cpuSeconds - (before[monitor.name]?.cpuSeconds ?? now.cpuSeconds))
            var sample = ProcessSample(process: monitor.name, cpuSeconds: (cpu * 100).rounded() / 100, cpuPercent: Int((cpu / wall * 100).rounded()),
                                       footprintMB: megabytes(now.footprintBytes), peakFootprintMB: megabytes(now.peakFootprintBytes), mlxActiveMB: nil, mlxPeakMB: nil, mlxCacheMB: nil)
            if let stats = monitor.stats, let counters = try? await stats() {
                sample.mlxActiveMB = megabytes(counters.activeBytes); sample.mlxPeakMB = megabytes(counters.peakBytes); sample.mlxCacheMB = megabytes(counters.cacheBytes)
            }
            processes.append(sample)
        }
        let gpu = samples > 0 ? GPUSample(meanDevicePercent: deviceSum / samples, maxDevicePercent: deviceMax, meanRendererPercent: rendererSum / samples, samples: samples,
                                          inUseMemoryMB: megabytes(last?.inUseBytes ?? 0)) : nil
        return PassResources(wallSeconds: (wall * 10).rounded() / 10, processes: processes, gpu: gpu)
    }

    func megabytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

    /// Markdown rows for one pass (the pass name goes in the first column of each row).
    public static func rows(_ pass: String, _ resources: PassResources) -> String {
        let gpu = resources.gpu.map { "\($0.meanDevicePercent)% / \($0.maxDevicePercent)% (\($0.samples) samples)" } ?? "–"
        var md = ""
        for process in resources.processes {
            let mlx = process.mlxActiveMB.map { "\($0) / \(process.mlxPeakMB ?? 0)" } ?? "–"
            md += "| \(pass) | \(resources.wallSeconds) | \(gpu) | \(process.process) | \(process.cpuSeconds) | \(process.cpuPercent) | \(process.footprintMB) | \(process.peakFootprintMB) | \(mlx) |\n"
        }
        return md
    }
    public static let tableHeader = "| Pass | Wall s | GPU device % mean / max | Process | CPU s | CPU % | Footprint MB | Peak footprint MB | MLX active / peak MB |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
}
