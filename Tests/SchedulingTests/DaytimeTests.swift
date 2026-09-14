import XCTest
@testable import Scheduling

final class DaytimeTests: XCTestCase {
    func testDaytimeIntervals() {
        XCTAssertEqual(OvernightScheduler.Config(daytime: "h1").daytimeInterval, 3600)
        XCTAssertEqual(OvernightScheduler.Config(daytime: "h3").daytimeInterval, 3 * 3600)
        XCTAssertNil(OvernightScheduler.Config(daytime: "off").daytimeInterval)
        XCTAssertNil(OvernightScheduler.Config(daytime: "garbage").daytimeInterval, "an unknown value never means 'read'")
    }
    func testTimeParsing() {
        XCTAssertEqual(OvernightScheduler.Config.parse("03:30").0, 3); XCTAssertEqual(OvernightScheduler.Config.parse("03:30").1, 30)
        XCTAssertEqual(OvernightScheduler.Config.parse(nil).0, 3); XCTAssertEqual(OvernightScheduler.Config.parse("nope").1, 0)
    }
}
