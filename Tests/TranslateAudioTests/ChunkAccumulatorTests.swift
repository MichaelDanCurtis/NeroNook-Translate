import XCTest
@testable import TranslateAudio

final class ChunkAccumulatorTests: XCTestCase {
    func testCutsExactChunksAndKeepsTheRemainder() {
        var accumulator = ChunkAccumulator(chunkSize: 4)
        XCTAssertEqual(accumulator.append((0 ..< 10).map(Float.init)), [[0, 1, 2, 3], [4, 5, 6, 7]])
        XCTAssertEqual(accumulator.append([10, 11]), [[8, 9, 10, 11]])
        XCTAssertNil(accumulator.flush())
    }

    func testSmallAppendsWaitForAFullChunk() {
        var accumulator = ChunkAccumulator(chunkSize: 3)
        XCTAssertEqual(accumulator.append([1]), [])
        XCTAssertEqual(accumulator.append([2]), [])
        XCTAssertEqual(accumulator.append([3, 4]), [[1, 2, 3]])
        XCTAssertEqual(accumulator.flush(), [4])
    }

    func testFlushReturnsTheRemainderOnceAndTheAccumulatorStaysUsable() {
        var accumulator = ChunkAccumulator(chunkSize: 5)
        XCTAssertEqual(accumulator.append([1, 2, 3, 4, 5, 6, 7]), [[1, 2, 3, 4, 5]])
        XCTAssertEqual(accumulator.flush(), [6, 7])
        XCTAssertNil(accumulator.flush())
        XCTAssertEqual(accumulator.append([8, 9, 10, 11, 12]), [[8, 9, 10, 11, 12]])
        XCTAssertNil(accumulator.flush())
    }

    func testEmptyAppendReturnsNothing() {
        var accumulator = ChunkAccumulator(chunkSize: 2)
        XCTAssertEqual(accumulator.append([]), [])
        XCTAssertNil(accumulator.flush())
    }

    func testChunksAndFlushReassembleTheInputExactly() {
        var accumulator = ChunkAccumulator(chunkSize: 160)
        let input = (0 ..< 1_000).map { Float($0) }
        var output: [Float] = []
        var start = 0
        var step = 1
        while start < input.count {
            let end = min(input.count, start + step)
            for chunk in accumulator.append(Array(input[start ..< end])) {
                XCTAssertEqual(chunk.count, 160)
                output += chunk
            }
            start = end
            step = step * 3 % 97 + 1 // varied piece sizes, including ones larger than a chunk
        }
        XCTAssertEqual(output.count, 960)
        output += accumulator.flush() ?? []
        XCTAssertEqual(output, input)
    }

    func testNonPositiveChunkSizeIsTreatedAsOne() {
        var accumulator = ChunkAccumulator(chunkSize: 0)
        XCTAssertEqual(accumulator.chunkSize, 1)
        XCTAssertEqual(accumulator.append([1, 2]), [[1], [2]])
        XCTAssertEqual(ChunkAccumulator(chunkSize: -3).chunkSize, 1)
    }

    func testRMSLevel() {
        XCTAssertEqual(Levels.rms([]), 0)
        XCTAssertEqual(Levels.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Levels.rms([3, -3]), 1) // clamped
    }
}
