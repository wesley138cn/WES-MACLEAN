import XCTest
@testable import Lime

final class FanSensorTests: XCTestCase {
    func testSMCDecoding() {
        XCTAssertEqual(FanSensor.decode([0x17, 0x70], type: "fpe2"), 1500)
        XCTAssertEqual(FanSensor.decode([0x40, 0x80], type: "sp78"), 64.5)
        XCTAssertEqual(FanSensor.decode([0xFF, 0x80], type: "sp78"), -0.5)
        XCTAssertEqual(FanSensor.decode([0, 0, 0xC8, 0x42], type: "flt "), 100)
        XCTAssertNil(FanSensor.decode([0], type: "fpe2"))
        XCTAssertNil(FanSensor.decode([0, 0, 0x80, 0x7F], type: "flt "))
        XCTAssertNil(FanSensor.decode([1], type: "unknown"))
    }
    func testMissingStoppedAndAbsentFansAreDistinct() {
        XCTAssertEqual(FanSnapshot.unavailable.display, "未提供")
        XCTAssertEqual(FanSnapshot(count: 0, readings: []).display, "无风扇")
        XCTAssertEqual(FanSnapshot(count: 1, readings: [.init(index: 0, rpm: 0)]).display, "0 RPM")
        XCTAssertEqual(FanSnapshot(count: 1, readings: [.init(index: 0, rpm: nil)]).display, "— RPM")
    }
    func testM1SensorAndFallback() {
        let readings = ["TCHP": 41.016, "Tp09": 62.0, "TC0P": 48.0]
        XCTAssertEqual(FanSensor.temperature(model: "MacBookAir10,1") { readings[$0] }, 41.016)
        XCTAssertEqual(FanSensor.temperature(model: "Mac16,12") { readings[$0] }, 62)
        XCTAssertEqual(FanSensor.temperature(model: "MacBookAir10,1") { $0 == "TCHP" ? .nan : 48 }, 48)
        XCTAssertNil(FanSensor.temperature(model: "MacBookAir10,1") { _ in 126 })
        XCTAssertNil(FanSensor.temperature(model: "unknown") { _ in nil })
    }
    func testFanlessModelIsExplicit() {
        XCTAssertTrue(FanSensor.isKnownFanless("Mac16,12"))
        XCTAssertTrue(FanSensor.isKnownFanless("MacBookAir10,1"))
        XCTAssertFalse(FanSensor.isKnownFanless("unknown"))
        XCTAssertFalse(FanSensor.isKnownFanless("MacBookPro18,1"))
    }
}
