import Foundation
final class CPUPowerStreamTests {
    func run() {
        var stream = CPUPowerStream()
        XCTAssertNil(stream.append("GPU Power: 800 mW\nCPU Pow"))
        XCTAssertEqual(stream.append("er: 17300 mW\n"), 17.3)
        XCTAssertNil(stream.append("Combined CPU + GPU Power: 123 mW\nCPU Power: nan mW\nCPU Power: -1 mW\n"))
        XCTAssertEqual(stream.append("CPU Power: 0 mW\nCPU Power: 2100 mW\n"), 2.1)
        XCTAssertNil(stream.append("CPU Power: 600000 mW\n"))
    }
}
