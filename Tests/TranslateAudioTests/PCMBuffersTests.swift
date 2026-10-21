import AVFoundation
import XCTest
@testable import TranslateAudio

final class PCMBuffersTests: XCTestCase {
    func testMonoFloatFormat() throws {
        let format = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 16_000))
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertNil(PCMBuffers.monoFloatFormat(sampleRate: 0))
        XCTAssertNil(PCMBuffers.monoFloatFormat(sampleRate: -16_000))
        XCTAssertNil(PCMBuffers.monoFloatFormat(sampleRate: .infinity))
    }

    func testBufferRoundTrip() throws {
        let samples = (0 ..< 1_234).map { sin(Float($0) * 0.01) * 0.8 }
        let buffer = try XCTUnwrap(PCMBuffers.buffer(samples, sampleRate: 24_000))
        XCTAssertEqual(buffer.frameLength, 1_234)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(PCMBuffers.samples(buffer), samples)
    }

    func testEmptyBufferRoundTrip() throws {
        let buffer = try XCTUnwrap(PCMBuffers.buffer([], sampleRate: 16_000))
        XCTAssertEqual(buffer.frameLength, 0)
        XCTAssertEqual(PCMBuffers.samples(buffer), [])
        XCTAssertNil(PCMBuffers.buffer([1, 2], sampleRate: 0))
    }

    func testSamplesReadsChannelZeroOfAnInterleavedBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0 ..< 4 {
            data[frame * 2] = Float(frame)
            data[frame * 2 + 1] = -Float(frame) - 10
        }
        buffer.frameLength = 4
        XCTAssertEqual(PCMBuffers.samples(buffer), [0, 1, 2, 3])
    }

    func testConvert48kTo16kGivesAThirdOfTheFramesAndKeepsTheSine() throws {
        let input = sine(hertz: 440, sampleRate: 48_000, count: 48_000)
        let converter = try makeConverter(from: 48_000, to: 16_000)
        let target = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 16_000))
        let output = try PCMBuffers.convert(try XCTUnwrap(PCMBuffers.buffer(input, sampleRate: 48_000)), to: target, with: converter)
        let samples = PCMBuffers.samples(output)

        XCTAssertEqual(output.format.sampleRate, 16_000)
        // About a third; the converter holds back a few frames for its filter until more input or a flush.
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 160)
        let expectedCrossings = 2 * 440 * Double(samples.count) / 16_000
        XCTAssertEqual(Double(zeroCrossings(samples)), expectedCrossings, accuracy: expectedCrossings * 0.03)
        XCTAssertEqual(Double(samples.map(abs).max() ?? 0), 0.5, accuracy: 0.03)
    }

    func testStreamingConversionJoinsUpAcrossCallsAndFlushes() throws {
        let input = sine(hertz: 440, sampleRate: 48_000, count: 48_000)
        let converter = try makeConverter(from: 48_000, to: 16_000)
        let target = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 16_000))
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1_000) {
            let piece = try XCTUnwrap(PCMBuffers.buffer(Array(input[start ..< start + 1_000]), sampleRate: 48_000))
            output += PCMBuffers.samples(try PCMBuffers.convert(piece, to: target, with: converter))
        }
        output += PCMBuffers.samples(try PCMBuffers.flush(converter))

        XCTAssertEqual(Double(output.count), 16_000, accuracy: 2)
        XCTAssertEqual(Double(zeroCrossings(output)), 880, accuracy: 880 * 0.03)
        // No gap or repeat at the piece boundaries: a 440 Hz sine of amplitude 0.5 at 16 kHz moves at most
        // 0.5 × 2π × 440 / 16000 ≈ 0.086 per sample; a dropped or doubled sample would jump further.
        let steps = zip(output.dropFirst(), output).map { abs($0 - $1) }.dropFirst(32)
        XCTAssertLessThan(steps.max() ?? 0, 0.11)
    }

    func testFlushResetsTheConverterForANewStream() throws {
        let converter = try makeConverter(from: 24_000, to: 48_000)
        let target = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 48_000))
        for _ in 0 ..< 2 {
            let chunk = try XCTUnwrap(PCMBuffers.buffer(sine(hertz: 300, sampleRate: 24_000, count: 2_400), sampleRate: 24_000))
            let body = try PCMBuffers.convert(chunk, to: target, with: converter).frameLength
            let tail = try PCMBuffers.flush(converter).frameLength
            XCTAssertEqual(Double(body + tail), 4_800, accuracy: 2)
        }
    }

    func testOutputThatFillsUpContinuesAndThePiecesJoinExactly() throws {
        let input = try XCTUnwrap(PCMBuffers.buffer(sine(hertz: 440, sampleRate: 48_000, count: 48_000), sampleRate: 48_000))
        let whole = try PCMBuffers.run(makeConverter(from: 48_000, to: 16_000), input: input, endOfStream: true)
        let pieces = try PCMBuffers.run(makeConverter(from: 48_000, to: 16_000), input: input, endOfStream: true, maxFramesPerPass: 100)
        XCTAssertEqual(pieces.frameLength, 16_000)
        XCTAssertEqual(PCMBuffers.samples(pieces), PCMBuffers.samples(whole))
    }

    func testConvertRejectsABufferThatDoesNotMatchTheConverter() throws {
        let converter = try makeConverter(from: 48_000, to: 16_000)
        let target = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 16_000))
        let wrongRate = try XCTUnwrap(PCMBuffers.buffer([0, 0.1, 0.2], sampleRate: 16_000))
        XCTAssertThrowsError(try PCMBuffers.convert(wrongRate, to: target, with: converter)) { error in
            XCTAssertTrue(error is AudioProblem)
        }
        let rightRate = try XCTUnwrap(PCMBuffers.buffer([0, 0.1, 0.2], sampleRate: 48_000))
        let wrongTarget = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: 24_000))
        XCTAssertThrowsError(try PCMBuffers.convert(rightRate, to: wrongTarget, with: converter))
    }

    // MARK: - Helpers

    private func sine(hertz: Double, sampleRate: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
        (0 ..< count).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / sampleRate)) }
    }

    private func makeConverter(from source: Double, to target: Double) throws -> AVAudioConverter {
        let input = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: source))
        let output = try XCTUnwrap(PCMBuffers.monoFloatFormat(sampleRate: target))
        return try XCTUnwrap(AVAudioConverter(from: input, to: output))
    }

    private func zeroCrossings(_ samples: [Float]) -> Int {
        zip(samples.dropFirst(), samples).filter { ($0 < 0) != ($1 < 0) }.count
    }
}
