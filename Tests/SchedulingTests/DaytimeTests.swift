import Testing
import Foundation
@testable import Scheduling

@Suite struct DaytimeTests {
    @Test func testDaytimeIntervals() {
        #expect(OvernightScheduler.Config(daytime: "h1").daytimeInterval == 3600.0)
        #expect(OvernightScheduler.Config(daytime: "h3").daytimeInterval == 3 * 3600.0)
        #expect(OvernightScheduler.Config(daytime: "off").daytimeInterval == nil)
        #expect(OvernightScheduler.Config(daytime: "garbage").daytimeInterval == nil, "an unknown value never means 'read'")
    }
    @Test func testTimeParsing() {
        #expect(OvernightScheduler.Config.parse("03:30").0 == 3); #expect(OvernightScheduler.Config.parse("03:30").1 == 30)
        #expect(OvernightScheduler.Config.parse(nil).0 == 3); #expect(OvernightScheduler.Config.parse("nope").1 == 0)
    }
}
