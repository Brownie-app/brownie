import Testing
import Foundation
@testable import Proactive
import Domain

/// A nudge never fails on the brain's wrapping: the loop knows the channel and the person.
@Suite struct NudgeRepairTests {
    let loop = Loop(id: "L", direction: .mine, person: "Kanika Pandey", what: "send Arif the licensing update", quote: "will send tomorrow", sourceLabel: "WhatsApp · Kanika · Fri", due: nil, openedAt: Date())

    @Test func aUsableRecipeIsKept() {
        let raw: [String: Any] = ["title": "Nudge Kanika", "draft": "hi", "recipe": ["kind": "whatsapp", "chat": "Kanika", "body": "hi"]]
        let r = LoopNudger.repair(raw, loop: loop)
        #expect((r["recipe"] as? [String: Any])?["chat"] as? String == "Kanika")
    }
    @Test func aWrappedCardIsUnwrapped() {
        let raw: [String: Any] = ["card": ["title": "t", "draft": "d", "recipe": ["kind": "whatsapp", "chat": "K", "body": "d"]]]
        #expect(LoopNudger.repair(raw, loop: loop)["title"] as? String == "t")
        let list: [String: Any] = ["cards": [["title": "first", "draft": "d", "recipe": ["kind": "mail", "to": "a", "subject": "s", "body": "d", "attachments": []]]]]
        #expect(LoopNudger.repair(list, loop: loop)["title"] as? String == "first")
    }
    @Test func aMissingOrStrangeRecipeIsBuiltFromTheLoop() {
        let r = LoopNudger.repair(["title": "t", "draft": "Hi Kanika, update coming"], loop: loop)
        let recipe = r["recipe"] as? [String: Any]
        #expect(recipe?["kind"] as? String == "whatsapp" && recipe?["chat"] as? String == "Kanika Pandey" && recipe?["body"] as? String == "Hi Kanika, update coming")
        let slack = LoopNudger.repair(["title": "t", "draft": "d", "recipe": ["kind": "slack", "channel": "x"]], loop: loop)
        #expect((slack["recipe"] as? [String: Any])?["kind"] as? String == "whatsapp", "a channel that isn't a recipe → the loop's channel")
        var mailLoop = loop; mailLoop = Loop(id: "M", direction: .theirs, person: "arif@x.com", what: "w", quote: "q", sourceLabel: "Gmail · Inbox", due: nil, openedAt: Date())
        let mail = LoopNudger.repair(["title": "t", "message": "d"], loop: mailLoop)
        #expect((mail["recipe"] as? [String: Any])?["kind"] as? String == "mail" && mail["draft"] as? String == "d", "'message' counts as the draft")
        let im = LoopNudger.repair(["title": "t", "draft": "d"], loop: Loop(id: "I", direction: .mine, person: "Amma", what: "w", quote: "q", sourceLabel: "iMessage · Amma · Sun", due: nil, openedAt: Date()))
        #expect((im["recipe"] as? [String: Any])?["kind"] as? String == "imessage")
    }
    @Test func theRepairedCardParses() {
        let r = LoopNudger.repair(["draft": "hi there"], loop: loop)
        let c = Preparer.card(from: r, now: Date())
        #expect(c?.title == "Nudge Kanika Pandey" && c?.evidence.first?.text == "will send tomorrow")
        if case .whatsapp(let chat, let body, _) = c!.recipe { #expect(chat == "Kanika Pandey" && body == "hi there") } else { Issue.record("expected a WhatsApp recipe") }
    }
}
