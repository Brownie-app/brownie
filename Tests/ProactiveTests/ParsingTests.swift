import XCTest
@testable import Proactive
import Domain

/// The brain's JSON is untrusted input: every parser fails closed.
final class ParsingTests: XCTestCase {
    func testPreparerCardCarriesLoopAndCameBack() {
        let d: [String: Any] = ["title": "Nudge Priya", "why": "w", "actionLabel": "Send", "dueLine": "3 days", "urgency": "high", "draftLabel": "Draft", "draft": "hi",
                                "recipe": ["kind": "whatsapp", "chat": "Priya", "phone": "919999", "body": "hi"], "evidence": [["source": "WhatsApp", "when": "Thu", "text": "asked"]],
                                "verification": "verified", "verifiedLine": "ok", "loopID": "ABC", "cameBack": true]
        let c = Preparer.card(from: d, now: Date())
        XCTAssertNotNil(c); XCTAssertEqual(c?.loopID, "ABC"); XCTAssertEqual(c?.isComeBack, true)
        if case .whatsapp(let chat, let body, let phone) = c!.recipe { XCTAssertEqual(chat, "Priya"); XCTAssertEqual(body, "hi"); XCTAssertEqual(phone, "919999") } else { XCTFail() }
    }
    func testPreparerCardWithoutRecipeIsDropped() {
        XCTAssertNil(Preparer.card(from: ["title": "x"], now: Date()))
        XCTAssertNil(Preparer.card(from: ["title": "x", "recipe": ["kind": "teleport"]], now: Date()))
    }
    func testNullLoopIDBecomesNil() {
        let d: [String: Any] = ["title": "t", "recipe": ["kind": "browser", "url": "https://a"], "loopID": "null"]
        XCTAssertNil(Preparer.card(from: d, now: Date())?.loopID)
    }
    func testRecipeShapes() {
        XCTAssertNotNil(Preparer.recipe(from: ["kind": "imessage", "to": "Amma", "body": "b"]))
        XCTAssertNotNil(Preparer.recipe(from: ["kind": "mail", "to": "a@b", "subject": "s", "body": "b"]))
        XCTAssertNotNil(Preparer.recipe(from: ["kind": "calendar", "title": "t", "startISO": "x", "endISO": "y", "notes": ""]))
        XCTAssertNotNil(Preparer.recipe(from: ["kind": "note", "relativePath": "Work/B.md", "body": "b"]))
        XCTAssertNotNil(Preparer.recipe(from: ["kind": "computerUse", "goal": "g"]))
        XCTAssertNil(Preparer.recipe(from: [:]))
    }
    func testJudgeWrapperToleratesMissingLoops() throws {
        let json = ##"{"action_items":[{"title":"t","action":"a","importance":"i","dueDate":null,"sources":["#1"],"urgency":"high"}]}"##
        let w = try JSONDecoder().decode(Judge.Wrapper.self, from: Data(json.utf8))
        XCTAssertEqual(w.action_items.count, 1); XCTAssertNil(w.loops); XCTAssertNil(w.action_items[0].cameBack)
    }
    func testJudgeWrapperDecodesLoopsAndUpdates() throws {
        let json = #"{"action_items":[],"loops":[{"person":"Karan","direction":"theirs","what":"villa share","quote":"tonight","source":"WhatsApp · Fri","due":null}],"loop_updates":[{"id":"ABCD1234","status":"closed","how":"paid"}]}"#
        let w = try JSONDecoder().decode(Judge.Wrapper.self, from: Data(json.utf8))
        XCTAssertEqual(w.loops?.first?.person, "Karan"); XCTAssertEqual(w.loop_updates?.first?.status, "closed")
    }
    func testJudgeTrimKeepsNewestFirst() {
        let long = String(repeating: "x", count: 100)
        let t = Judge.trim(long, to: 10)
        XCTAssertTrue(t.hasPrefix("xxxxxxxxxx")); XCTAssertTrue(t.contains("omitted"))
    }
    func testIsoWeekKey() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 14   // a Monday
        let d = Calendar(identifier: .iso8601).date(from: c)!
        XCTAssertEqual(WeeklyWriter.isoWeek(d), "2026-W38")
        c.day = 20; XCTAssertEqual(WeeklyWriter.isoWeek(Calendar(identifier: .iso8601).date(from: c)!), "2026-W38", "Sunday belongs to the same ISO week")
        c.day = 21; XCTAssertEqual(WeeklyWriter.isoWeek(Calendar(identifier: .iso8601).date(from: c)!), "2026-W39")
    }
    func testAskerAnswerRoundTrips() throws {
        let a = Asker.Answer(question: "q", answer: "A [1] B", citations: [.init(n: 1, kind: "note", label: "People/Karan", ref: "People/Karan.md")], actions: [.init(label: "Open", kind: "loops", ref: "")], at: Date())
        let back = try JSONDecoder().decode(Asker.Answer.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }
}
