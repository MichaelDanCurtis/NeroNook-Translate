import Darwin
import Foundation

/// CPU time and memory footprint of one process, from `proc_pid_rusage` (no privileges needed). CPU time
/// is user plus system, converted from Mach time units; footprint is the physical footprint the kernel
/// charges the process (what Activity Monitor calls Memory), with its lifetime peak.
public struct ProcessUsage: Codable, Sendable, Equatable {
    public var cpuSeconds: Double
    public var footprintBytes: UInt64
    public var peakFootprintBytes: UInt64

    public static func read(pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return ProcessUsage(cpuSeconds: Double(info.ri_user_time + info.ri_system_time) * scale,
                            footprintBytes: info.ri_phys_footprint, peakFootprintBytes: info.ri_lifetime_max_phys_footprint)
    }

    public static func current() -> ProcessUsage? { read(pid: getpid()) }
}
