import Foundation

final class ThermalTests {
    func testSensorClassificationAndRangeFilter() {
        XCTAssertEqual(ThermalMath.category(for: "PMU tdie3"), .soc)
        XCTAssertEqual(ThermalMath.category(for: "pACC MTR Temp Sensor2"), .cpu)
        XCTAssertEqual(ThermalMath.category(for: "eACC MTR Temp Sensor0"), .cpu)
        XCTAssertEqual(ThermalMath.category(for: "GPU MTR Temp Sensor1"), .gpu)
        XCTAssertEqual(ThermalMath.category(for: "NAND CH0 temp"), .storage)
        XCTAssertEqual(ThermalMath.category(for: "gas gauge battery"), .battery)
        XCTAssertNil(ThermalMath.category(for: "PMU tdev1"))
        XCTAssertTrue(!ThermalMath.isPlausible(0))
        XCTAssertTrue(!ThermalMath.isPlausible(-3))
        XCTAssertTrue(!ThermalMath.isPlausible(150))
        XCTAssertTrue(!ThermalMath.isPlausible(.nan))
        XCTAssertTrue(ThermalMath.isPlausible(41.6))
    }

    func testSummaryAveragesDuplicateServicesAndDropsBadValues() {
        let summary = ThermalMath.summary([
            ("PMU tdie0", 40), ("PMU tdie0", 42),   // 同名兩個服務先平均成 41
            ("PMU tdie1", 45),
            ("PMU tdie2", 0),                        // 讀取失敗，丟棄
            ("gas gauge battery", 34), ("gas gauge battery", 36),
            ("PMU tdev1", 99),                       // 不認得，忽略
        ])
        XCTAssertEqual(summary.soc?.average, 43)
        XCTAssertEqual(summary.soc?.maximum, 45)
        XCTAssertEqual(summary.battery?.average, 35)
        XCTAssertNil(summary.cpu)
        XCTAssertNil(summary.gpu)
        XCTAssertTrue(!summary.isEmpty)
        XCTAssertTrue(ThermalMath.summary([]).isEmpty)
    }

    func testFanFractionIsClampedAndSafeWithoutMax() {
        XCTAssertEqual(FanReading(id: 0, name: "f", rpm: 3400, minRPM: 2317, maxRPM: 6800).fraction, 0.5)
        XCTAssertEqual(FanReading(id: 0, name: "f", rpm: 9000, minRPM: 2317, maxRPM: 6800).fraction, 1)
        XCTAssertEqual(FanReading(id: 0, name: "f", rpm: 3000, minRPM: 0, maxRPM: 0).fraction, 0)
    }

    func testSleepingClusterJunkValuesAreIgnored() {
        // 實測 M2 Pro 閒置時效能核心回報的假值
        XCTAssertNil(ThermalMath.dieStatistic([0, 4.6, 5.3, 6.7, 8.4]))
        XCTAssertNil(ThermalMath.dieStatistic([]))
        // 一半休眠、一半有效：只用有效的
        let mixed = ThermalMath.dieStatistic([6.7, 4.6, 51.0, 49.0, 0])
        XCTAssertEqual(mixed?.average, 50)
        XCTAssertEqual(mixed?.maximum, 51)
        XCTAssertNil(ThermalMath.dieStatistic([130, .nan]))
    }

    func testKeyTableOnlyCoversVerifiedChips() {
        XCTAssertEqual(ThermalKeyTable.keys(forChip: "Apple M2 Pro")?.gpu, ["Tg0f", "Tg0j"])
        XCTAssertEqual(ThermalKeyTable.keys(forChip: "Apple M2")?.cpu.count, 12)
        XCTAssertNil(ThermalKeyTable.keys(forChip: "Apple M1"))
        XCTAssertNil(ThermalKeyTable.keys(forChip: "Apple M3 Max"))
        XCTAssertNil(ThermalKeyTable.keys(forChip: "Apple M20"))
        // Intel 用 SMC 鍵：每個核心 TC1C 起，核心鍵讀不到時改用 PECI／die／proximity
        let intel = ThermalKeyTable.keys(forChip: "Intel(R) Core(TM) i5-8500B CPU @ 3.00GHz")
        XCTAssertEqual(intel?.cpu.first, "TC1C")
        XCTAssertEqual(intel?.cpuFallback.first, "TCXC")
        XCTAssertTrue(intel?.gpu.contains("TCGC") == true)
        XCTAssertTrue(intel?.coresSleep == false)
    }

    func testIntelFallbackAndPlainSensors() {
        // 不存在的核心回報 -127：過濾掉；備援鍵取第一個有效的
        XCTAssertEqual(ThermalMath.dieStatistic([82, 73, -127].filter(ThermalMath.isValidDieTemperature))?.maximum, 82)
        XCTAssertEqual(ThermalMath.firstValid([nil, -127, 80.2, 56.1])?.average, 80.2)
        XCTAssertNil(ThermalMath.firstValid([nil, 0]))
        XCTAssertEqual(ThermalMath.plainStatistic([52.1, 50.9, nil, 0])?.maximum, 52.1)
        XCTAssertNil(ThermalMath.plainStatistic([nil, -127]))
    }

    func testEachSensorKeepsItsLastValidValue() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var held: [String: (value: Double, date: Date)] = [:]
        // 兩顆都有效
        XCTAssertEqual(ThermalMath.effectiveDieValues([("A", 50), ("B", 60)], held: &held, now: t0), [50, 60])
        // A 讀到假值：沿用 50；B 有新值
        XCTAssertEqual(ThermalMath.effectiveDieValues([("A", 6.7), ("B", 61)], held: &held, now: t0.addingTimeInterval(1)), [50, 61])
        // 讀不到（nil）也沿用
        XCTAssertEqual(ThermalMath.effectiveDieValues([("A", nil), ("B", 62)], held: &held, now: t0.addingTimeInterval(2)), [50, 62])
        // A 超過 120 秒沒有有效值：放棄；B 最近有效，仍保留
        let late = ThermalMath.effectiveDieValues([("A", 4.6), ("B", 5.3)], held: &held, now: t0.addingTimeInterval(122))
        XCTAssertEqual(late, [62])
        // 全部過期：沒有值
        XCTAssertEqual(ThermalMath.effectiveDieValues([("A", 0), ("B", 0)], held: &held, now: t0.addingTimeInterval(400)), [])
        // 從來沒有有效值：不顯示
        var empty: [String: (value: Double, date: Date)] = [:]
        XCTAssertEqual(ThermalMath.effectiveDieValues([("X", 6.7)], held: &empty, now: t0), [])
    }

    func testAverageDoesNotDropWhenOneClusterSleeps() {
        // 節能核心 ≈ 48，效能核心 ≈ 54。效能核心休眠時沿用舊值，平均不應掉到只剩節能核心的數字
        let t0 = Date(timeIntervalSince1970: 5_000)
        var held: [String: (value: Double, date: Date)] = [:]
        let awake: [(key: String, value: Double?)] = [("E1", 48), ("E2", 48), ("P1", 54), ("P2", 54)]
        let asleep: [(key: String, value: Double?)] = [("E1", 48), ("E2", 48), ("P1", 6.7), ("P2", 4.6)]
        XCTAssertEqual(ThermalMath.dieStatistic(ThermalMath.effectiveDieValues(awake, held: &held, now: t0))?.average, 51)
        XCTAssertEqual(ThermalMath.dieStatistic(ThermalMath.effectiveDieValues(asleep, held: &held, now: t0.addingTimeInterval(1)))?.average, 51)
    }
}
