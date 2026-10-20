import Foundation
import MachO

/// The SDK version stamped into this process's main executable (LC_BUILD_VERSION).
///
/// Apple Translation answers `supported` and `notInstalled` to a binary stamped below SDK 27.0 even when
/// the language pack is installed. SwiftPM 6.4's Swift Build system stamps the deployment target instead
/// of the SDK (the link step never gets `-target-sdk-version`), so Package.swift gives TranslateCheck an
/// explicit `-platform_version`. This check makes a wrongly stamped binary say so instead of reporting a
/// missing language pack.
public enum BuildStamp {
    public static func programSDKVersion() -> String? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<Int(header.pointee.ncmds) {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_BUILD_VERSION) {
                let version = cursor.loadUnaligned(as: build_version_command.self).sdk
                return "\(version >> 16).\((version >> 8) & 0xff)"
            }
            cursor += Int(command.cmdsize)
        }
        return nil
    }

    /// True when the stamp is at least `major.minor`.
    public static func programSDK(atLeast major: Int, _ minor: Int = 0) -> Bool {
        guard let stamp = programSDKVersion() else { return false }
        let parts = stamp.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return parts[0] > major || (parts[0] == major && parts[1] >= minor)
    }
}
