import Foundation

final class ChargeLimitTests {
    func testOptionsFromSystem() {
        XCTAssertEqual(ChargeLimitLogic.options(from: [80, 85, 90, 95, 100].map { NSNumber(value: $0) }), [80, 85, 90, 95, 100])
        // 去重、排序、丟掉不合理的值
        let messy: [Any] = [100, 90, 90, 80, 0, 255].map { NSNumber(value: $0) } + ["x" as NSString]
        XCTAssertEqual(ChargeLimitLogic.options(from: messy), [80, 90, 100])
        // 沒回傳、只有一個值、或沒有 100（不限制）就用預設級距
        XCTAssertEqual(ChargeLimitLogic.options(from: nil), ChargeLimitLogic.defaultOptions)
        XCTAssertEqual(ChargeLimitLogic.options(from: [NSNumber(value: 100)]), ChargeLimitLogic.defaultOptions)
        XCTAssertEqual(ChargeLimitLogic.options(from: [NSNumber(value: 80), NSNumber(value: 90)]), ChargeLimitLogic.defaultOptions)
    }

    func testNormalizedLimit() {
        XCTAssertEqual(ChargeLimitLogic.normalized(95), 95)
        XCTAssertEqual(ChargeLimitLogic.normalized(100), 100)
        XCTAssertEqual(ChargeLimitLogic.normalized(0), 100)
        XCTAssertEqual(ChargeLimitLogic.normalized(255), 100)
    }

    func testSliderPositions() {
        let options = ChargeLimitLogic.defaultOptions
        XCTAssertEqual(ChargeLimitLogic.index(of: 80, in: options), 0)
        XCTAssertEqual(ChargeLimitLogic.index(of: 95, in: options), 3)
        // 不在級距上的值放到最接近的格子
        XCTAssertEqual(ChargeLimitLogic.index(of: 92, in: options), 2)
        XCTAssertEqual(ChargeLimitLogic.limit(atIndex: 3.4, in: options), 95)
        XCTAssertEqual(ChargeLimitLogic.limit(atIndex: -2, in: options), 80)
        XCTAssertEqual(ChargeLimitLogic.limit(atIndex: 9, in: options), 100)
        XCTAssertNil(ChargeLimitLogic.limit(atIndex: .nan, in: options))
        XCTAssertNil(ChargeLimitLogic.limit(atIndex: 1, in: []))
    }
}
