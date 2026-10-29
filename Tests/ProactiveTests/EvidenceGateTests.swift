import Testing
import Foundation
import Domain
@testable import Proactive

/// UNIT. The two gates that stand between a model's word and the user's morning.
///
/// The judge writes loops from summaries and has not seen a message since ingest; the preparer grades its own
/// cards and has never failed itself. These are the checks the app can make on its own, and every case below is
/// one the shipped app got wrong on real data before they existed.
@Suite struct EvidenceGateTests {

    let now = Date(timeIntervalSinceReferenceDate: 814_900_000)

    func line(_ text: String, id: String = "m1") -> SourceLine { SourceLine(id: id, said: now, text: text) }

    func loop(_ what: String, person: String = "Asha Mehra", quote: String = "", id: String = "L1") -> Loop {
        Loop(id: id, direction: .mine, person: person, what: what, quote: quote.isEmpty ? what : quote,
             sourceLabel: "WhatsApp · \(person)", due: nil, openedAt: now)
    }

    func card(_ title: String, why: String = "", evidence: [Evidence], verified: Bool = true, id: String = "C1") -> Card {
        Card(id: id, title: title, sourceLabel: "WhatsApp · Asha Mehra (+15550)", why: why, actionLabel: "", dueLine: "",
             urgency: .medium, draftLabel: "", draft: "", recipe: .computerUse(goal: "g"), evidence: evidence,
             verification: verified ? .verified : .unverified, verifiedLine: "checked", createdAt: now)
    }

    // MARK: - Loops

    /// The card that started all of this. One real message, and a figure in the loop that nobody said.
    @Test func aFigureNobodySaidIsCutAndThePromiseSurvives() throws {
        let msgs = [line("Hi, tried calling. Please call back when free."), line("Sorry, was travelling — will call you back.")]
        let out = LoopGate.apply([loop("Call Asha Mehra back about the potential 9 lakh funding")], lines: { _ in msgs })
        #expect(out.kept.count == 1)
        #expect(out.kept[0].what == "Call Asha Mehra back", "the promise was real; only the clause was not")
        #expect(out.repaired.count == 1)
        #expect(out.repaired[0].unsupported == ["9 lakh"])
        let span = try #require(out.kept[0].span, "and what survives carries the line it came from")
        #expect(msgs.map(\.text).contains(span.text))
    }

    @Test func aLoopWhoseFiguresAreAllInTheMessagesPassesThroughUntouched() {
        let msgs = [line("can you send the 2,00,000 by 30 Sep?")]
        let l = loop("Send the 2,00,000 by 30 Sep")
        let out = LoopGate.apply([l], lines: { _ in msgs })
        #expect(out.kept == [out.kept[0]])
        #expect(out.kept[0].what == l.what)
        #expect(out.repaired.isEmpty && out.refused.isEmpty)
        #expect(out.proven == 1)
    }

    /// A chat Brownie cannot open must not be able to delete a true promise.
    @Test func aConversationThatCannotBeReadLeavesEverythingAlone() {
        let out = LoopGate.apply([loop("Call Asha back about the potential 9 lakh funding")], lines: { _ in [] })
        #expect(out.kept.count == 1)
        #expect(out.kept[0].what.contains("9 lakh"), "unproven is not disproven")
        #expect(out.unchecked == 1)
        #expect(out.kept[0].span == nil)
        #expect(out.repaired.isEmpty && out.refused.isEmpty)
    }

    @Test func aPromiseThatIsNothingButTheInventedPartIsRefused() {
        let out = LoopGate.apply([loop("Pay 9 lakh")], lines: { _ in [line("please call me back")] })
        #expect(out.kept.isEmpty)
        #expect(out.refused.count == 1)
        #expect(out.refused[0].unsupported == ["9 lakh"])
    }

    /// Three loops in one real ledger carried the same registry id, corrupted three different ways. The
    /// model's own quote carried the same wrong digits each time, so only the message can tell them apart.
    @Test func aCorruptedIdentifierIsCutWhereTheRealOnePasses() {
        let msgs = [line("push api-worker:latest to 100200300400500 when the build is done")]
        let real = LoopGate.apply([loop("Share the corrected api-worker:latest image with 100200300400500")], lines: { _ in msgs })
        #expect(real.repaired.isEmpty, "the id that was actually said stays")

        let garbled = LoopGate.apply([loop("Share the corrected api-worker:latest image with 10020030040050010")], lines: { _ in msgs })
        #expect(garbled.kept.first?.what == "Share the corrected api-worker:latest image")
        #expect(garbled.repaired.first?.unsupported == ["10020030040050010"])
    }

    @Test func theLoopKeepsItsIdentityThroughARepairSoNothingDownstreamLosesIt() {
        var l = loop("Call back about the 9 lakh funding", id: "KEEP-ME")
        l.status = .open
        l.firedCardIDs = ["card-1"]
        l.cameBackCount = 2
        let out = LoopGate.apply([l], lines: { _ in [line("call me back please")] })
        let kept = out.kept[0]
        #expect(kept.id == "KEEP-ME")
        #expect(kept.firedCardIDs == ["card-1"])
        #expect(kept.cameBackCount == 2)
        #expect(kept.direction == l.direction && kept.person == l.person && kept.openedAt == l.openedAt)
    }

    @Test func eachPersonsChatIsReadOnceHoweverManyLoopsTheyHave() async {
        let asked = Counter()
        let loops = [loop("Call back", id: "a"), loop("Send the file", id: "b"), loop("Pay it", person: "Nayra", id: "c")]
        _ = await LoopGate.apply(loops, lookup: { person, _ in await asked.hit(person); return [self.line("ok")] })
        #expect(await asked.count == 2, "two people, two reads — not three")
    }

    // MARK: - Cards

    /// A summary and the People note written from that summary are one source quoted twice. The shipped app
    /// marked exactly this `verified`.
    @Test func aCardBackedOnlyByBrowniesOwnWritingCannotCallItselfChecked() {
        let circular = card("Call Asha about funding", evidence: [
            Evidence(source: "People/Asha Mehra.md", when: "2026-10-28", text: "the status records your promise"),
            Evidence(source: "Read/2026-10-28.md", when: "2026-10-28", text: "you owe Asha a call"),
        ])
        let out = CardGate.apply([circular], lines: { _ in [] })
        #expect(out.cards[0].verification == .unverified)
        #expect(out.cards[0].verifiedLine.contains("something I wrote myself"))
        #expect(out.downgraded.count == 1)
    }

    @Test func oneRealSourceAmongTheNotesIsEnoughToStandUp() {
        let grounded = card("Call Asha about funding", evidence: [
            Evidence(source: "People/Asha Mehra.md", when: "2026-10-28", text: "the status records your promise"),
            Evidence(source: "WhatsApp · Asha Mehra", when: "2026-10-27", text: "please call back"),
        ])
        let out = CardGate.apply([grounded], lines: { _ in [] })
        #expect(out.cards[0].verification == .verified)
        #expect(out.downgraded.isEmpty)
    }

    @Test func aCardWhoseFigureIsInNoMessageLosesTheClaimToHaveBeenChecked() {
        let c = card("Call Asha about funding", why: "They asked about the 9 lakh funding next month",
                     evidence: [Evidence(source: "WhatsApp · Asha Mehra", when: "2026-10-27", text: "please call back")])
        let out = CardGate.apply([c], lines: { _ in [line("please call back when free")] })
        #expect(out.cards[0].verification == .unverified)
        #expect(out.cards[0].verifiedLine.contains("isn't in any message"))
    }

    /// The card still reaches the morning. Downgrading is about the claim of having checked, not about hiding
    /// the thing — a user who is shown nothing cannot correct it.
    @Test func aDowngradedCardKeepsItsPlaceAndEverythingElseAboutIt() {
        let c = card("Call Asha about funding", why: "about the 9 lakh funding",
                     evidence: [Evidence(source: "WhatsApp · M", when: "x", text: "call back")])
        let out = CardGate.apply([c], lines: { _ in [line("call me back")] })
        #expect(out.cards.count == 1)
        #expect(out.cards[0].id == c.id && out.cards[0].title == c.title && out.cards[0].why == c.why)
        #expect(out.cards[0].state == c.state && out.cards[0].recipe == c.recipe && out.cards[0].evidence == c.evidence)
    }

    @Test func aCardThatNeverClaimedToBeCheckedIsLeftAlone() {
        let c = card("Call Asha", why: "about the 9 lakh", evidence: [], verified: false)
        let out = CardGate.apply([c], lines: { _ in [line("call me")] })
        #expect(out.downgraded.isEmpty)
        #expect(out.cards[0].verifiedLine == "checked", "its own line stands; the gate only ever takes the claim away")
    }

    @Test func aCardWithNoEvidenceAtAllIsNotCalledCircular() {
        let out = CardGate.apply([card("Renew the domain", evidence: [])], lines: { _ in [] })
        #expect(out.cards[0].verification == .verified, "nothing to be circular with — the specifics check is the one that applies")
    }

    // MARK: - Provenance

    @Test func whatCountsAsBrowniesOwnWriting() {
        for s in ["People/Asha Mehra.md", "Groups/Book club.md", "Read/2026-10-28.md", "the loops ledger", "Loop · 1A2B3C4D"] {
            #expect(Evidence(source: s, when: "", text: "").isDerived, "\(s) is something Brownie wrote")
        }
        for s in ["WhatsApp · Asha Mehra", "Gmail · billing@google.com", "Files · Desktop", "Recording · team call · 03:12", "Calendar · Calendar"] {
            #expect(!Evidence(source: s, when: "", text: "").isDerived, "\(s) is the world's")
        }
    }

    actor Counter {
        private var seen: Set<String> = []
        func hit(_ s: String) { seen.insert(s) }
        var count: Int { seen.count }
    }
}
