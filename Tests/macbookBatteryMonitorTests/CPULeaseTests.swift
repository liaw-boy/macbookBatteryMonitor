import Foundation
final class CPULeaseTests {
    func run() {
        var leases = CPUSamplingLeases()
        let a = UUID(), b = UUID()
        XCTAssertTrue(!leases.isActive(at: 10))
        leases.set(a, active: true, at: 10)
        XCTAssertTrue(leases.isActive(at: 14.9))
        XCTAssertTrue(!leases.isActive(at: 15))
        leases.set(b, active: true, at: 14)
        leases.set(a, active: false, at: 14)
        XCTAssertTrue(leases.isActive(at: 16))
        leases.remove(b)
        XCTAssertTrue(!leases.isActive(at: 16))
        leases.set(a, active: true, at: 20)
        XCTAssertTrue(!leases.isActive(at: 19))
        let reading = CPUPowerReading(watts: 17.5, uptime: 10)
        XCTAssertEqual(reading.freshWatts(at: 12.9), 17.5)
        XCTAssertNil(reading.freshWatts(at: 14))
        XCTAssertNil(reading.freshWatts(at: 9))
        XCTAssertNil(CPUPowerReading(watts: .nan, uptime: 10).freshWatts(at: 11))
        XCTAssertNil(CPUPowerReading(watts: -1, uptime: 10).freshWatts(at: 11))
    }
}
