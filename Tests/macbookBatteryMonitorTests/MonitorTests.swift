import Foundation

final class MonitorTests {
    func testCPUUsageFromTickDeltas() {
        let old = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let new = CPUTicks(user: 160, system: 70, idle: 1070, nice: 0)
        let usage = CPUMath.usage(from: old, to: new)!
        XCTAssertTrue(abs(usage.user - 0.2) < 1e-9)
        XCTAssertTrue(abs(usage.system - 0.0666667) < 1e-6)
        XCTAssertTrue(abs(usage.total - 0.2666667) < 1e-6)
    }

    func testCPUCounterWrapReturnsNil() {
        let old = CPUTicks(user: 4_000_000_000, system: 10, idle: 10, nice: 0)
        let new = CPUTicks(user: 5, system: 20, idle: 20, nice: 0)
        XCTAssertNil(CPUMath.usage(from: old, to: new))
    }

    func testPerCoreAndTotal() {
        let old = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let new = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let result = CPUMath.usages(from: old, to: new)!
        XCTAssertEqual(result.cores.map(\.total), [1, 0])
        XCTAssertEqual(result.total.total, 0.5)
    }

    func testMemoryCategoriesMatchActivityMonitor() {
        let usage = MemoryMath.usage(pageSize: 16384, internalPages: 200_000, purgeablePages: 10_000, wiredPages: 80_000,
                                     compressedPages: 140_000, externalPages: 90_000, total: 8 * 1024 * 1024 * 1024,
                                     swapUsed: 0, swapTotal: 0, pressure: .normal)
        XCTAssertEqual(usage.app, 190_000 * 16384)
        XCTAssertEqual(usage.cached, 100_000 * 16384)
        XCTAssertEqual(usage.used, (190_000 + 80_000 + 140_000) * 16384)
        XCTAssertEqual(usage.free, 8 * 1024 * 1024 * 1024 - usage.used - usage.cached)
    }

    func testRateHandlesResetAndInterval() {
        XCTAssertEqual(RateMath.perSecond(old: 1000, new: 3000, interval: 2), 1000)
        XCTAssertEqual(RateMath.perSecond(old: 3000, new: 1000, interval: 1), 0)
        XCTAssertEqual(RateMath.perSecond(old: 0, new: 1000, interval: 0), 0)
    }

    func testByteFormats() {
        XCTAssertEqual(ByteFormat.size(494_384_795_648), "494 GB")
        XCTAssertEqual(ByteFormat.memory(5_952_618_496), "5.5 GB")
        XCTAssertEqual(ByteFormat.rate(1_234_000), "1.2 MB/s")
        XCTAssertEqual(ByteFormat.compactRate(0), "0K")
        XCTAssertEqual(ByteFormat.compactRate(340_000), "340K")
        XCTAssertEqual(ByteFormat.compactRate(1_234_000), "1.2M")
        XCTAssertEqual(ByteFormat.compactRate(25_000_000), "25M")
        XCTAssertEqual(ByteFormat.percent(0.195), "20%")
    }

    func testTopParsing() {
        let text = """
        Processes: 566 total, 3 running
        Load Avg: 2.18, 2.39, 2.49

        PID    COMMAND          %CPU
        407    WindowServer     43.6
        13286  Safari Web Conten 12.3
        """
        let rows = TopParse.rows(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], TopParse.Row(pid: 13286, command: "Safari Web Conten", value: "12.3"))
        XCTAssertEqual(TopParse.memoryBytes("523M"), 523 * 1024 * 1024)
        XCTAssertEqual(TopParse.memoryBytes("1024K+"), 1024 * 1024)
        XCTAssertEqual(TopParse.memoryBytes("2G-"), 2 * 1024 * 1024 * 1024)
    }

    func testHistoryKeepsLastPoints() {
        var history = MonitorHistory()
        for i in 0..<(MonitorHistory.capacity + 30) { history.append(Double(i)) }
        XCTAssertEqual(history.points.count, MonitorHistory.capacity)
        XCTAssertEqual(history.points.first?.a, 30)
    }

    func testHistoryKeepsTwoMinutesInPowerSaving() {
        // 省電模式每 2 秒一點：只保留最近 2 分鐘，圖表的「最近 2 分鐘」才正確
        let start = Date(timeIntervalSince1970: 1_000_000)
        var history = MonitorHistory()
        for i in 0..<100 { history.append(Double(i), at: start.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(history.points.count, 61)
        XCTAssertEqual(history.points.first?.a, 39)
        // 每秒一點時仍以 120 個為上限
        var everySecond = MonitorHistory()
        for i in 0..<200 { everySecond.append(Double(i), at: start.addingTimeInterval(Double(i))) }
        XCTAssertEqual(everySecond.points.count, MonitorHistory.capacity)
    }
}
