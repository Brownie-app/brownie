import Testing
import Foundation
@testable import Proactive
import Domain

/// The check before cards show: closed loops, fired twins, missing files and old notes.
@Suite struct QuietCheckTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func card(_ id: String, loop: String? = nil, evidence: [Evidence] = [], recipe: Recipe = .browser(url: "u"), state: CardState = .ready, cameBack: Bool? = nil, resolvedAgo: TimeInterval? = nil) -> Card {
        var c = Card(id: id, title: "Card \(id)", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: recipe, evidence: evidence, verification: .verified, verifiedLine: "", state: state, createdAt: now.addingTimeInterval(-3600), cameBack: cameBack, loopID: loop)
        if let r = resolvedAgo { c.resolvedAt = now.addingTimeInterval(-r) }
        return c
    }
    func loop(_ id: String, closed: Bool = false, how: String? = nil) -> Loop {
        Loop(id: id, direction: .mine, person: "Kanika", what: "send the update", quote: "", sourceLabel: "WhatsApp", due: nil, status: closed ? .closed : .open, openedAt: now.addingTimeInterval(-86400), closedAt: closed ? now : nil, closedHow: how)
    }
    func run(_ cards: [Card], loops: [Loop] = [], past: [Card] = [], notes: [String: Date] = [:], files: Set<String> = [], staleDays: Int = 7) -> QuietCheck.Result {
        QuietCheck.run(cards: cards, loops: loops, past: past, noteUpdated: { notes[$0] }, fileExists: { files.contains($0) }, now: now, staleDays: staleDays)
    }

    @Test func aClosedLoopTakesItsCardWithIt() {
        let r = run([card("a", loop: "L1"), card("b", loop: "L2")], loops: [loop("L1", closed: true, how: "she replied"), loop("L2")])
        #expect(r.kept.map(\.id) == ["b"])
        #expect(r.dropped.map(\.why) == ["the loop it was about closed — she replied"])
    }

    @Test func aLoopAlreadyFiredIsNotAskedTwiceUnlessItCameBack() {
        let fired = card("old", loop: "L1", state: .fired, resolvedAgo: 3600)
        #expect(run([card("a", loop: "L1")], loops: [loop("L1")], past: [fired]).dropped.map(\.why) == ["you already fired a card for this"])
        #expect(run([card("a", loop: "L1", cameBack: true)], loops: [loop("L1")], past: [fired]).kept.count == 1, "a came-back nudge is deliberate")
        let longAgo = card("old", loop: "L1", state: .fired, resolvedAgo: 3 * 86400)
        #expect(run([card("a", loop: "L1")], loops: [loop("L1")], past: [longAgo]).kept.count == 1, "after the card's lifetime it may come again")
    }

    @Test func aMissingAttachmentDropsTheCard() {
        let c = card("a", recipe: .mail(to: "arif", subject: "s", body: "b", attachments: ["/Users/v/Desktop/deck.pdf"]))
        #expect(run([c], files: []).dropped.map(\.why) == ["the file it needs is gone: deck.pdf"])
        #expect(run([c], files: ["/Users/v/Desktop/deck.pdf"]).kept.count == 1)
        let named = card("b", recipe: .imessage(to: "Amma", body: "", attachments: ["photo from Sunday"]))
        #expect(run([named]).kept.count == 1, "a described attachment isn't a path to check")
    }

    @Test func oldNotesFlagOrDropDependingOnWhatElseThereIs() {
        let old = now.addingTimeInterval(-10 * 86400), fresh = now.addingTimeInterval(-86400)
        let notes = ["People/Kanika.md": old, "People/Meera.md": fresh]
        let onlyOld = card("a", evidence: [Evidence(source: "People/Kanika.md", when: "x", text: "t")])
        #expect(run([onlyOld], notes: notes).dropped.map(\.why) == ["built only on notes last updated 10 days ago"])
        #expect(run([onlyOld], notes: notes, staleDays: 14).kept.first?.staleLine == nil, "within the setting it is simply fine")
        let mixed = card("b", evidence: [Evidence(source: "People/Kanika.md", when: "x", text: "t"), Evidence(source: "WhatsApp · Kanika · Fri", when: "12 Sep 2026", text: "t")])
        let r = run([mixed], notes: notes)
        #expect(r.kept.count == 1 && r.kept[0].staleLine == "Partly from a note last updated 10 days ago (People/Kanika.md)")
        let freshOnly = card("c", evidence: [Evidence(source: "People/Meera.md", when: "x", text: "t")])
        #expect(run([freshOnly], notes: notes).kept.first?.staleLine == nil)
        let unknown = card("d", evidence: [Evidence(source: "People/Gone.md", when: "x", text: "t")])
        #expect(run([unknown], notes: notes).kept.count == 1, "a note we can't date is left alone")
    }

    @Test func nonReadyCardsPassThroughUntouched() {
        let s = card("s", state: .snoozed), f = card("f", state: .fired)
        let r = run([s, f, card("a")])
        #expect(r.kept.map(\.id) == ["a", "s", "f"] && r.dropped.isEmpty)
    }

    @Test func staleLineSurvivesWithDueLine() {
        var c = card("a"); c.staleLine = "old"
        #expect(c.withDueLine("Due tomorrow").staleLine == "old")
    }
}
