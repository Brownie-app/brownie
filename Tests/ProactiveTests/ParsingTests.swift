import Testing
import Foundation
@testable import Proactive
import Domain

/// The brain's JSON is untrusted input: every parser fails closed.
@Suite struct ParsingTests {
    @Test func testPreparerCardCarriesLoopAndCameBack() {
        let d: [String: Any] = ["title": "Nudge Priya", "why": "w", "actionLabel": "Send", "dueLine": "3 days", "urgency": "high", "draftLabel": "Draft", "draft": "hi",
                                "recipe": ["kind": "whatsapp", "chat": "Priya", "phone": "919999", "body": "hi"], "evidence": [["source": "WhatsApp", "when": "Thu", "text": "asked"]],
                                "verification": "verified", "verifiedLine": "ok", "loopID": "ABC", "cameBack": true]
        let c = Preparer.card(from: d, now: Date())
        #expect(c != nil); #expect(c?.loopID == "ABC"); #expect(c?.isComeBack == true)
        if case .whatsapp(let chat, let body, let phone) = c!.recipe { #expect(chat == "Priya"); #expect(body == "hi"); #expect(phone == "919999") } else { Issue.record("failed") }
    }
    @Test func testPreparerCardWithoutRecipeIsDropped() {
        #expect(Preparer.card(from: ["title": "x"], now: Date()) == nil)
        #expect(Preparer.card(from: ["title": "x", "recipe": ["kind": "teleport"]], now: Date()) == nil)
    }
    @Test func testNullLoopIDBecomesNil() {
        let d: [String: Any] = ["title": "t", "recipe": ["kind": "browser", "url": "https://a"], "loopID": "null"]
        #expect(Preparer.card(from: d, now: Date())?.loopID == nil)
    }
    @Test func testRecipeShapes() {
        #expect(Preparer.recipe(from: ["kind": "imessage", "to": "Amma", "body": "b"]) != nil)
        #expect(Preparer.recipe(from: ["kind": "mail", "to": "a@b", "subject": "s", "body": "b"]) != nil)
        #expect(Preparer.recipe(from: ["kind": "calendar", "title": "t", "startISO": "x", "endISO": "y", "notes": ""]) != nil)
        #expect(Preparer.recipe(from: ["kind": "note", "relativePath": "Work/B.md", "body": "b"]) != nil)
        #expect(Preparer.recipe(from: ["kind": "computerUse", "goal": "g"]) != nil)
        #expect(Preparer.recipe(from: [:]) == nil)
    }
    @Test func testJudgeWrapperToleratesMissingLoops() throws {
        let json = ##"{"action_items":[{"title":"t","action":"a","importance":"i","dueDate":null,"sources":["#1"],"urgency":"high"}]}"##
        let w = try JSONDecoder().decode(Judge.Wrapper.self, from: Data(json.utf8))
        #expect(w.action_items.count == 1); #expect(w.loops == nil); #expect(w.action_items[0].cameBack == nil)
    }
    @Test func testJudgeWrapperDecodesLoopsAndUpdates() throws {
        let json = #"{"action_items":[],"loops":[{"person":"Karan","direction":"theirs","what":"villa share","quote":"tonight","source":"WhatsApp · Fri","due":null}],"loop_updates":[{"id":"ABCD1234","status":"closed","how":"paid"}]}"#
        let w = try JSONDecoder().decode(Judge.Wrapper.self, from: Data(json.utf8))
        #expect(w.loops?.first?.person == "Karan"); #expect(w.loop_updates?.first?.status == "closed")
    }
    @Test func testJudgeTrimKeepsNewestFirst() {
        let long = String(repeating: "x", count: 100)
        let t = Judge.trim(long, to: 10)
        #expect(t.hasPrefix("xxxxxxxxxx")); #expect(t.contains("omitted"))
    }
    @Test func testIsoWeekKey() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 14   // a Monday
        let d = Calendar(identifier: .iso8601).date(from: c)!
        #expect(WeeklyWriter.isoWeek(d) == "2026-W38")
        c.day = 20; #expect(WeeklyWriter.isoWeek(Calendar(identifier: .iso8601).date(from: c)!) == "2026-W38", "Sunday belongs to the same ISO week")
        c.day = 21; #expect(WeeklyWriter.isoWeek(Calendar(identifier: .iso8601).date(from: c)!) == "2026-W39")
    }
    @Test func testAskerAnswerRoundTrips() throws {
        let a = Asker.Answer(question: "q", answer: "A [1] B", citations: [.init(n: 1, kind: "note", label: "People/Karan", ref: "People/Karan.md")], actions: [.init(label: "Open", kind: "loops", ref: "")], at: Date())
        let back = try JSONDecoder().decode(Asker.Answer.self, from: JSONEncoder().encode(a))
        #expect(back == a)
    }
}
