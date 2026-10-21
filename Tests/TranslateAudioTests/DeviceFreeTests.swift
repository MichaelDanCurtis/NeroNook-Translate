import XCTest
@testable import TranslateAudio

/// Device listing reads CoreAudio properties only; the capture and playback checks fail before any engine exists.
/// Nothing here opens a device, captures audio or plays sound.
final class DeviceFreeTests: XCTestCase {
    func testInputDevicesAreWellFormed() throws {
        let inputs = AudioDevices.inputs()
        guard !inputs.isEmpty else { throw XCTSkip("This machine reports no audio input devices.") }
        for device in inputs {
            XCTAssertFalse(device.id.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertNotNil(AudioDevices.deviceID(forUID: device.id), device.name)
        }
        XCTAssertEqual(Set(inputs.map(\.id)).count, inputs.count, "UIDs are unique")
        if let defaultUID = AudioDevices.defaultInputUID(), inputs.contains(where: { $0.id == defaultUID }) {
            XCTAssertEqual(inputs.first?.id, defaultUID, "the default input comes first")
        }
    }

    func testUnknownUIDHasNoDevice() {
        XCTAssertNil(AudioDevices.deviceID(forUID: "no-such-device-\(UUID().uuidString)"))
    }

    @MainActor
    func testCaptureRejectsBadArgumentsAndAMissingDevice() {
        let capture = MicrophoneCapture()
        XCTAssertThrowsError(try capture.start(deviceUID: nil, sampleRate: 0))
        XCTAssertThrowsError(try capture.start(deviceUID: nil, chunkSeconds: 0))
        XCTAssertThrowsError(try capture.start(deviceUID: "no-such-device-\(UUID().uuidString)")) { error in
            XCTAssertTrue(error is AudioProblem)
        }
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(capture.level, 0)
        capture.stop()
    }

    @MainActor
    func testPlaybackRefusesAudioBeforeStart() async {
        let playback = SpeechPlayback()
        XCTAssertThrowsError(try playback.enqueue([0, 0.1, 0.2], sampleRate: 24_000)) { error in
            XCTAssertEqual((error as? AudioProblem)?.message, "Speech playback is not started.")
        }
        XCTAssertEqual(playback.pendingSeconds, 0)
        XCTAssertFalse(playback.isPlaying)
        await playback.drain() // nothing scheduled: returns at once
        playback.stop()
        XCTAssertEqual(playback.level, 0)
    }

    func testAudioProblemDescribesItself() {
        let problem = AudioProblem("The microphone was disconnected.")
        XCTAssertEqual(problem.description, "The microphone was disconnected.")
        XCTAssertEqual(problem.localizedDescription, "The microphone was disconnected.")
    }
}
