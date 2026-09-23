import Testing
import Foundation
@testable import Proactive
import Domain
import Support

@Suite struct DueNudgerTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))! }
    func loop(_ due: Date?, status: LoopStatus = .open, nudged: Bool? = nil) -> Loop {
        var l = Loop(direction: .theirs, person: "Priya", what: "answer", quote: "q", sourceLabel: "WhatsApp", due: "Tuesday", dueDate: due, status: status, openedAt: day(2026, 9, 17)); l.nudgedForDue = nudged; return l
    }
    @Test func testDueWithinWindow() {
        let now = day(2026, 9, 21, hour: 3)   // Monday 3 AM
        let due = DueNudger.due([loop(day(2026, 9, 22)), loop(day(2026, 9, 25)), loop(nil)], now: now, days: 1, calendar: cal)
        #expect(due.count == 1, "only Tuesday's loop is within a day")
        #expect(DueNudger.due([loop(day(2026, 9, 22)), loop(day(2026, 9, 23))], now: now, days: 2, calendar: cal).count == 2)
    }
    @Test func testOverdueStillCounts() { #expect(DueNudger.due([loop(day(2026, 9, 10))], now: day(2026, 9, 21), days: 1, calendar: cal).count == 1) }
    @Test func testNudgedClosedAndOffAreSkipped() {
        let now = day(2026, 9, 21)
        #expect(DueNudger.due([loop(day(2026, 9, 22), nudged: true)], now: now, days: 1, calendar: cal).isEmpty)
        #expect(DueNudger.due([loop(day(2026, 9, 22), status: .closed)], now: now, days: 1, calendar: cal).isEmpty)
        #expect(DueNudger.due([loop(day(2026, 9, 22))], now: now, days: 0, calendar: cal).isEmpty, "'only when asked' never nudges")
    }
    @Test func testNudgeLine() {
        let now = day(2026, 9, 19)   // Saturday
        #expect(DueNudger.nudgeLine(for: loop(day(2026, 9, 22)), days: 1, now: now, calendar: cal) == "card Mon 7:30")
        #expect(DueNudger.nudgeLine(for: loop(day(2026, 9, 22)), days: 2, now: now, calendar: cal) == "card Sun 7:30")
        #expect(DueNudger.nudgeLine(for: loop(day(2026, 9, 19)), days: 1, now: now, calendar: cal) == "card next morning")
        #expect(DueNudger.nudgeLine(for: loop(day(2026, 9, 22), nudged: true), days: 1, now: now, calendar: cal) == "card sent")
        #expect(DueNudger.nudgeLine(for: loop(nil), days: 1, now: now, calendar: cal) == nil)
        #expect(DueNudger.nudgeLine(for: loop(day(2026, 9, 22)), days: 0, now: now, calendar: cal) == nil)
    }
    @Test func testDueLine() {
        let now = day(2026, 9, 21)
        #expect(DueNudger.dueLine(day(2026, 9, 22), now: now, calendar: cal) == "Due tomorrow")
        #expect(DueNudger.dueLine(day(2026, 9, 21, hour: 18), now: now, calendar: cal) == "Due today")
        #expect(DueNudger.dueLine(day(2026, 9, 19), now: now, calendar: cal) == "Overdue 2 days")
        #expect(DueNudger.dueLine(day(2026, 9, 26), now: now, calendar: cal) == "Due in 5 days")
    }
    @Test func testJudgeDateParsing() {
        let clock = FixedClock(day(2026, 9, 21))
        #expect(Judge.date("2026-09-23", clock: clock) == day(2026, 9, 23))
        #expect(Judge.date("Tuesday", clock: clock) == nil); #expect(Judge.date(nil, clock: clock) == nil); #expect(Judge.date("2026-9-3", clock: clock) == nil)
    }
    @Test func testLedgerLearnsADateLater() {
        let now = day(2026, 9, 21)
        let known = [loop(nil)]
        let out = LoopLedger.merge(existing: known, found: [loop(day(2026, 9, 22))], updates: [], items: [], now: now)
        #expect(out.count == 1); #expect(out[0].dueDate == day(2026, 9, 22))
    }
    @Test func testDueCardCarriesDateAndLine() {
        var c = Card(id: "1", title: "t", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .high, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: Date())
        c.dueDate = day(2026, 9, 22)
        let c2 = c.withDueLine("Due tomorrow")
        #expect(c2.isDue); #expect(c2.dueLine == "Due tomorrow"); #expect(c2.dueDate == c.dueDate)
    }
}
