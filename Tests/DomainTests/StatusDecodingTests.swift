import Testing
import Foundation
@testable import Domain

/// Ledgers written before loops could lapse still load, and a status word this build has never seen does not lose the ledger.
@Suite struct StatusDecodingTests {
    @Test func anOldLoopWithoutTheNewFieldsDecodes() throws {
        let json = """
        {"id":"L1","direction":"mine","person":"Amma","what":"call","quote":"Sunday","sourceLabel":"iMessage · Thu","due":"Sunday","status":"open","openedAt":780000000,"firedCardIDs":[],"cameBackCount":0}
        """
        let l = try JSONDecoder().decode(Loop.self, from: Data(json.utf8))
        #expect(l.status == .open && l.lapsedAt == nil && l.closedBy == nil && l.closedAt == nil)
        let back = try JSONDecoder().decode(Loop.self, from: JSONEncoder().encode(l))
        #expect(back == l, "and it round-trips unchanged")
    }
    @Test func aLapsedLoopRoundTrips() throws {
        var l = Loop(id: "L2", direction: .theirs, person: "Karan", what: "villa share", quote: "", sourceLabel: "s", due: nil, openedAt: Date(timeIntervalSince1970: 1_700_000_000))
        l.status = .lapsed; l.lapsedAt = Date(timeIntervalSince1970: 1_708_000_000); l.closedAt = l.lapsedAt; l.closedBy = "lapsed"
        let json = String(data: try JSONEncoder().encode(l), encoding: .utf8)!
        #expect(json.contains("\"status\":\"lapsed\"") && json.contains("\"closedBy\":\"lapsed\""))
        #expect(try JSONDecoder().decode(Loop.self, from: Data(json.utf8)) == l)
    }
    @Test func anUnknownStatusReadsAsClosedInsteadOfFailingTheLedger() throws {
        let json = """
        [{"id":"L1","direction":"mine","person":"A","what":"w","quote":"","sourceLabel":"s","status":"forgotten","openedAt":780000000,"firedCardIDs":[],"cameBackCount":0},
         {"id":"L2","direction":"mine","person":"B","what":"w","quote":"","sourceLabel":"s","status":"open","openedAt":780000000,"firedCardIDs":[],"cameBackCount":0}]
        """
        let loops = try JSONDecoder().decode([Loop].self, from: Data(json.utf8))
        #expect(loops.map(\.status) == [.closed, .open], "the strange one stops being tracked; the rest of the ledger is untouched")
        #expect(try JSONDecoder().decode(LoopStatus.self, from: Data("\"lapsed\"".utf8)) == .lapsed)
    }
    @Test func anOldAskWithoutLapsedAtDecodes() throws {
        let json = """
        {"id":"ask-1","person":"Nitesh","bucket":{"rawValue":"whatsapp:1"},"askedAt":780000000,"question":"beer?","answeredAt":780001000,"reply":"yes","addressed":true}
        """
        let a = try JSONDecoder().decode(Ask.self, from: Data(json.utf8))
        #expect(a.lapsedAt == nil && a.isAnswered && !a.isLapsed && !a.isOpen)
        var waiting = Ask(id: "ask-2", person: "N", bucket: BucketID("whatsapp:1"), askedAt: Date(), question: "q?")
        #expect(waiting.isOpen && !waiting.isLapsed)
        waiting.lapsedAt = Date()
        #expect(!waiting.isOpen && waiting.isLapsed, "let go is neither open nor answered")
    }
}
