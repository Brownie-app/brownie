import Testing
import Foundation
@testable import Proactive
import Domain

@Suite struct LoopLedgerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func loop(_ person: String, _ what: String, dir: LoopDirection = .theirs, id: String = UUID().uuidString, status: LoopStatus = .open, closedAt: Date? = nil, fired: [String] = []) -> Loop {
        Loop(id: id, direction: dir, person: person, what: what, quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, status: status, openedAt: now, closedAt: closedAt, firedCardIDs: fired)
    }

    @Test func testNewLoopsAreAdded() {
        let out = LoopLedger.merge(existing: [], found: [loop("Karan", "send his villa share")], updates: [], items: [], now: now)
        #expect(out.count == 1); #expect(out[0].status == .open)
    }
    @Test func testDuplicateOfOpenLoopIsDropped() {
        let existing = [loop("Karan", "send his share of the villa")]
        let out = LoopLedger.merge(existing: existing, found: [loop("karan ", "villa share to send")], updates: [], items: [], now: now)
        #expect(out.count == 1, "same person, same promise → no duplicate")
    }
    @Test func testDifferentPromiseSamePersonIsKept() {
        let out = LoopLedger.merge(existing: [loop("Karan", "villa share")], found: [loop("Karan", "cricket tickets for Sunday")], updates: [], items: [], now: now)
        #expect(out.count == 2)
    }
    @Test func testDirectionMattersForDedupe() {
        let out = LoopLedger.merge(existing: [loop("Karan", "the villa share", dir: .theirs)], found: [loop("Karan", "the villa share", dir: .mine)], updates: [], items: [], now: now)
        #expect(out.count == 2)
    }
    @Test func testClosureByIdPrefix() {
        let l = loop("Priya", "answer on the dates", id: "ABCDEFGH-1234")
        let out = LoopLedger.merge(existing: [l], found: [], updates: [(idPrefix: "ABCDEFGH", closed: true, how: "she replied")], items: [], now: now)
        #expect(out[0].status == .closed); #expect(out[0].closedHow == "she replied"); #expect(out[0].closedAt == now)
    }
    @Test func testClosedLoopDoesNotBlockANewOne() {
        let old = loop("Karan", "villa share", status: .closed, closedAt: now.addingTimeInterval(-86400))
        let out = LoopLedger.merge(existing: [old], found: [loop("Karan", "villa share")], updates: [], items: [], now: now)
        #expect(out.filter { $0.status == .open }.count == 1)
    }
    @Test func testCameBackIncrementsCount() {
        let l = loop("Priya", "answer", id: "PRIYA123-x", fired: ["card1"])
        let item = ActionItem(title: "t", action: "a", importance: "i", dueDate: nil, sources: [], urgency: .high, cameBack: true, loopID: "PRIYA123")
        let out = LoopLedger.merge(existing: [l], found: [], updates: [], items: [item], now: now)
        #expect(out[0].cameBackCount == 1)
    }
    @Test func testClosedLoopsFallOffAfterThirtyDays() {
        let old = loop("X", "y", status: .closed, closedAt: now.addingTimeInterval(-31 * 86400))
        let recent = loop("X", "z", status: .closed, closedAt: now.addingTimeInterval(-2 * 86400))
        let out = LoopLedger.merge(existing: [old, recent], found: [], updates: [], items: [], now: now)
        #expect(out.count == 1); #expect(out[0].what == "z")
    }
    @Test func testCountsSplitByDirectionAndWeek() {
        let loops = [loop("A", "1", dir: .mine), loop("B", "2", dir: .theirs), loop("C", "3", status: .closed, closedAt: Date().addingTimeInterval(-3600)), loop("D", "4", status: .closed, closedAt: Date().addingTimeInterval(-10 * 86400))]
        let c = LoopLedger.counts(loops)
        #expect(c.mine == 1); #expect(c.theirs == 1); #expect(c.closedThisWeek == 1)
    }
    @Test func testJudgeLineMentionsFiredCard() {
        #expect(loop("K", "w", fired: ["c"]).judgeLine.contains("card fired"))
        #expect(!(loop("K", "w").judgeLine.contains("card fired")))
    }
}
