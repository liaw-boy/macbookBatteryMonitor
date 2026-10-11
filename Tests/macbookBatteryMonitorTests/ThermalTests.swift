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
}
