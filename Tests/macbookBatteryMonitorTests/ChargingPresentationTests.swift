import Foundation
final class ChargingPresentationTests {
    func testFullPriorityAndBriefFlagChanges() {
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true, fullyCharged: true,
            voltage_mV: 12000, amperage_mA: 0)
        s.applyLivePower(battery: 0.9, adapter: 12, system: 13.1)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        for t in 1...12 {
            s.isCharging = t % 2 == 0
            s.fullyCharged = t % 3 == 0
            XCTAssertEqual(filter.state(s, uptime: Double(t)), .full)
        }
        let e = Estimator.estimates(s, avgDischarge_mA: nil, avgCharge_mA: nil, displayState: .full)
        XCTAssertEqual(e.state, .full)
        XCTAssertTrue(abs(e.batteryWatts + 1.1) < 0.001)
        XCTAssertEqual(e.flowKind, .adapter)
        XCTAssertNil(e.toFull)
    }
    func testFullHysteresisAndSustainedRecharge() {
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true, fullyCharged: true)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        s.percent = 99; s.fullyCharged = false
        XCTAssertEqual(filter.state(s, uptime: 1), .full)
        s.isCharging = true
        XCTAssertEqual(filter.state(s, uptime: 2), .full)
        XCTAssertEqual(filter.state(s, uptime: 11), .full)
        XCTAssertEqual(filter.state(s, uptime: 12), .charging)
        s.isCharging = false
        XCTAssertEqual(filter.state(s, uptime: 13), .charging)
        XCTAssertEqual(filter.state(s, uptime: 23), .full)
        s.percent = 98
        XCTAssertEqual(filter.state(s, uptime: 24), .full)
        s.percent = 97
        XCTAssertEqual(filter.state(s, uptime: 25), .pluggedIdle)
    }
    func testInterruptedConfirmationAndUnplugAreImmediate() {
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        s.percent = 99; s.isCharging = true
        XCTAssertEqual(filter.state(s, uptime: 1), .full)
        s.isCharging = false
        XCTAssertEqual(filter.state(s, uptime: 9), .full)
        s.isCharging = true
        XCTAssertEqual(filter.state(s, uptime: 10), .full)
        XCTAssertEqual(filter.state(s, uptime: 19), .full)
        s.externalConnected = false
        XCTAssertEqual(filter.state(s, uptime: 19.1), .discharging)
        let e = Estimator.estimates(s, avgDischarge_mA: nil, avgCharge_mA: nil, displayState: .full)
        XCTAssertEqual(e.state, .discharging)
        XCTAssertEqual(e.flowKind, .battery)
        s.externalConnected = true
        XCTAssertEqual(filter.state(s, uptime: 20), .charging)
    }
    func testRealMixedSupplyAtFullIsNotHidden() {
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true, fullyCharged: true,
            voltage_mV: 12000, amperage_mA: 0)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        s.amperage_mA = -1000
        XCTAssertEqual(filter.state(s, uptime: 1), .full)
        XCTAssertEqual(filter.state(s, uptime: 11), .full)
        var flow = PowerFlowPresentation()
        XCTAssertEqual(flow.kind(connected: true, watts: 0, nearFull: true, uptime: 0), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -12, nearFull: true, uptime: 1), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -12, nearFull: true, uptime: 11), .mixed)
        var e = Estimator.estimates(s, avgDischarge_mA: nil, avgCharge_mA: nil, displayState: .full)
        e.displayFlow = .mixed
        XCTAssertEqual(e.state, .full)
        XCTAssertEqual(e.flowKind, .mixed)
        XCTAssertEqual(e.batteryWatts, -12)
    }
    func testInitialNearFullSpikeAlsoNeedsConfirmation() {
        var flow = PowerFlowPresentation()
        XCTAssertEqual(flow.kind(connected: true, watts: 7, nearFull: true, uptime: 0), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -5, nearFull: true, uptime: 1), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: 0.2, nearFull: true, uptime: 2), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -12, nearFull: true, uptime: 3), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -12, nearFull: true, uptime: 13), .mixed)
    }
    func testMinorAssistAndFlowConfirmation() {
        var flow = PowerFlowPresentation()
        XCTAssertEqual(flow.kind(connected: true, watts: 0, nearFull: true, uptime: 0), .adapter)
        for t in 1...20 {
            XCTAssertEqual(flow.kind(connected: true, watts: t % 2 == 0 ? 1.9 : -1.9,
                                     nearFull: true, uptime: Double(t)), .adapter)
        }
        XCTAssertEqual(flow.kind(connected: true, watts: -3, nearFull: true, uptime: 21), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -3, nearFull: true, uptime: 30), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -3, nearFull: true, uptime: 31), .mixed)
        XCTAssertEqual(flow.kind(connected: true, watts: 4, nearFull: true, uptime: 32), .mixed)
        XCTAssertEqual(flow.kind(connected: true, watts: 4, nearFull: true, uptime: 42), .charging)
        XCTAssertEqual(flow.kind(connected: true, watts: -1, nearFull: true, uptime: 43), .charging)
        XCTAssertEqual(flow.kind(connected: true, watts: -1, nearFull: true, uptime: 53), .adapter)
        XCTAssertEqual(flow.kind(connected: false, watts: -1, nearFull: true, uptime: 53.1), .battery)
        XCTAssertEqual(flow.kind(connected: true, watts: -1, nearFull: true, uptime: 53.2), .adapter)
        XCTAssertEqual(flow.kind(connected: true, watts: -1, nearFull: false, uptime: 53.3), .mixed)
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true, fullyCharged: true,
            voltage_mV: 12000, amperage_mA: -100)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        s.fullyCharged = false
        XCTAssertEqual(filter.state(s, uptime: 20), .full)
    }
    func testChargeLimitAndMixedSupplyOutsideFullArePreserved() {
        var filter = ChargingPresentation()
        var s = BatterySnapshot(percent: 100, externalConnected: true, fullyCharged: true)
        XCTAssertEqual(filter.state(s, uptime: 0), .full)
        s.chargeLimit = ChargeLimit(limit: 80, reason: "manualChargeLimit")
        s.amperage_mA = -1000; s.voltage_mV = 12000
        XCTAssertEqual(filter.state(s, uptime: 1), .limitReached)
        s.chargeLimit = nil; s.fullyCharged = false; s.percent = 75
        XCTAssertEqual(filter.state(s, uptime: 2), .pluggedIdle)
        let e = Estimator.estimates(s, avgDischarge_mA: nil, avgCharge_mA: nil)
        XCTAssertEqual(e.flowKind, .mixed)
        s.isCharging = true
        XCTAssertEqual(filter.state(s, uptime: 3), .pluggedIdle)
        XCTAssertEqual(filter.state(s, uptime: 13), .charging)
    }
}
