import CoreAudio
import Foundation

/// One audio input device as CoreAudio reports it.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// The device UID (`kAudioDevicePropertyDeviceUID`): stable across launches and reconnects, unlike `AudioDeviceID`.
    public let id: String
    /// The name to show (`kAudioObjectPropertyName`); the UID when the device reports no name.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Device lists from the CoreAudio HAL. These functions read properties only; they never open a device.
public enum AudioDevices {
    /// Input devices with at least one input channel on the input scope: the default input first, the rest by name.
    /// Hidden devices (such as private aggregates) are left out.
    public static func inputs() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []
        for deviceID in allDeviceIDs() where inputChannelCount(deviceID) > 0 && !isHidden(deviceID) {
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID), !uid.isEmpty else { continue }
            let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? ""
            devices.append(AudioInputDevice(id: uid, name: name.isEmpty ? uid : name))
        }
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let defaultUID = defaultInputUID(), let index = devices.firstIndex(where: { $0.id == defaultUID }) {
            devices.insert(devices.remove(at: index), at: 0)
        }
        return devices
    }

    /// The UID of the system default input device, or nil when there is none.
    public static func defaultInputUID() -> String? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    /// The current `AudioDeviceID` of the device with this UID, or nil when it is not connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    // MARK: - CoreAudio property reads

    /// Every device the HAL lists (`kAudioHardwarePropertyDevices`).
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: Int(size) / stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        // The list can shrink between the two calls; `size` now holds what was written.
        return Array(ids.prefix(Int(size) / stride))
    }

    /// Total channels across the device's input streams (`kAudioDevicePropertyStreamConfiguration`, input scope).
    static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Whether CoreAudio still reports the device as alive (false once it is unplugged or the read fails).
    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        uint32Property(kAudioDevicePropertyDeviceIsAlive, of: deviceID).map { $0 != 0 } ?? false
    }

    static func isHidden(_ deviceID: AudioDeviceID) -> Bool {
        uint32Property(kAudioDevicePropertyIsHidden, of: deviceID).map { $0 != 0 } ?? false
    }

    static func uint32Property(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// A CFString property; CoreAudio hands back a retained reference that we take ownership of.
    static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Watches one CoreAudio device and calls `onGone` on the main queue when it stops being alive (unplugged, removed).
/// The listener is removed when the watch is released.
final class DeviceAliveWatch {
    private let deviceID: AudioDeviceID
    private let listener: AudioObjectPropertyListenerBlock
    private var registered = false

    init(deviceID: AudioDeviceID, onGone: @escaping @MainActor @Sendable () -> Void) {
        self.deviceID = deviceID
        listener = { _, _ in
            // Registered on the main queue below.
            MainActor.assumeIsolated {
                if !AudioDevices.isAlive(deviceID) { onGone() }
            }
        }
        var address = AudioDevices.globalAddress(kAudioDevicePropertyDeviceIsAlive)
        registered = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener) == noErr
    }

    deinit {
        guard registered else { return }
        var address = AudioDevices.globalAddress(kAudioDevicePropertyDeviceIsAlive)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
    }
}
