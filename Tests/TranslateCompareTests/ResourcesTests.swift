import XCTest
import TranslateEngineClient
@testable import TranslateCompare

final class ResourcesTests: XCTestCase {
    func testProcessUsageCountsCPUTimeAndFootprint() throws {
        let before = try XCTUnwrap(ProcessUsage.current())
        let started = ProcessInfo.processInfo.systemUptime
        var x = 0.0
        while ProcessInfo.processInfo.systemUptime - started < 0.2 { x += sin(x + 1) }
        let after = try XCTUnwrap(ProcessUsage.current())
        XCTAssertGreaterThan(x, -1e9)
        XCTAssertGreaterThan(after.cpuSeconds - before.cpuSeconds, 0.1, "a 0.2 s busy loop is at least 0.1 s of CPU")
        XCTAssertLessThan(after.cpuSeconds - before.cpuSeconds, 1.0, "and not an order of magnitude more: the Mach time unit is converted")
        XCTAssertGreaterThan(after.footprintBytes, 1_000_000)
        XCTAssertGreaterThanOrEqual(after.peakFootprintBytes, after.footprintBytes)
        XCTAssertNil(ProcessUsage.read(pid: 2_147_483_000))
    }

    func testGPUStatisticsAreWithinRangeWhenAvailable() {
        guard let reading = GPUStatistics.read() else { return }   // no accelerator on this machine
        XCTAssert((0...100).contains(reading.devicePercent))
        XCTAssert((0...100).contains(reading.rendererPercent))
        XCTAssert((0...100).contains(reading.tilerPercent))
    }

    func testSamplerBracketsAPass() async throws {
        let sampler = ResourceSampler(monitors: [ResourceMonitor(name: "self", pid: getpid())], interval: 0.05)
        await sampler.begin()
        let started = ProcessInfo.processInfo.systemUptime
        var x = 0.0
        while ProcessInfo.processInfo.systemUptime - started < 0.3 { x += sin(x + 1) }
        let resources = await sampler.end()
        XCTAssertGreaterThan(x, -1e9)
        XCTAssertGreaterThanOrEqual(resources.wallSeconds, 0.3)
        XCTAssertEqual(resources.processes.count, 1)
        XCTAssertEqual(resources.processes[0].process, "self")
        XCTAssertGreaterThan(resources.processes[0].cpuPercent, 30)
        XCTAssertLessThan(resources.processes[0].cpuPercent, 400)
        if let gpu = resources.gpu { XCTAssertGreaterThan(gpu.samples, 2); XCTAssert((0...100).contains(gpu.meanDevicePercent)) }
        let rows = ResourceSampler.rows("test", resources)
        XCTAssert(rows.hasPrefix("| test | "), rows)
    }
}
