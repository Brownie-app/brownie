import Testing
import Foundation
@testable import Proactive
import Domain

/// The bar a loop must clear: the exact strings the judge reported from the user's vault as "promises", the ones
/// that are sentiments turned away and the ones that are deliverables let through; the mirrored pair folded; the
/// user never the other party.
@Suite struct LoopQualityTests {
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16
    func loop(_ what: String, person: String = "Kanika Pandey", dir: LoopDirection = .mine, at: Date = now, id: String = UUID().uuidString) -> Loop {
        Loop(id: id, direction: dir, person: person, what: what, quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: at)
    }

    @Test func sentimentsAndAgreementsInPrincipleAreNotCommitments() {
        for what in ["Build something big", "Build a company with Kanika", "Not back out of the venture if Kanika goes full-time",
                     "Discuss the future of the company and the goal of building a multimillion dollar business",
                     "Focus on her network", "Focus on improving the user experience", "Go full time on Orbit to chase more deals"] {
            #expect(!LoopQuality.isCommitment(what), "“\(what)” is a sentiment, not a deliverable: \(LoopQuality.reason(what) ?? "accepted")")
        }
    }
    @Test func theAspirationListTurnsAwayEachLeadVerb() {
        for what in ["Be more present at home", "Become a better manager", "Keep doing the good work", "Improve the onboarding flow", "Work on the pitch",
                     "Think about the offer", "Consider moving to Pune", "Explore a partnership with Razorpay", "Try the new gym", "Aim for ten deals a month",
                     "Plan to discuss the equity split", "Continue the weekly calls", "Building a company together", "Payment for the villa", "Reply", ""] {
            #expect(!LoopQuality.isCommitment(what), "“\(what)” should be turned away")
        }
    }
    @Test func deliverablesAreCommitments() {
        for what in ["Send Vivek the final proposal for commentary on slides 6–11", "Call Mr. Taragi", "Provide her sister's number and email for Loopsy",
                     "Provide rough estimates for the three requested tasks", "Ping Arif again", "Join the meeting", "Copy Browserbase design for the product"] {
            #expect(LoopQuality.isCommitment(what), "“\(what)” is a deliverable: \(LoopQuality.reason(what) ?? "")")
        }
    }
    @Test func anyConcreteVerbWithAnObjectPassesAndAModalPrefixIsForgiven() {
        for what in ["Pay 500 to Arjun", "Book the villa for the 12th", "Set up the Slack channel", "Introduce Kanika to Rohan", "Finalise the deck",
                     "to send the invoice", "will share the recording", "Nudge the landlord about the deposit", "Keepsake photo for Priya"] {
            #expect(LoopQuality.isCommitment(what), "“\(what)”: \(LoopQuality.reason(what) ?? "")")
        }
        #expect(LoopQuality.reason("Call") == "“call” names no object")
        #expect(LoopQuality.reason("Focus on her network")?.contains("intention") == true)
    }

    @Test func theSamePromiseOncePerSideIsOneLoop() {
        let theirs = loop("Provide her sister's number and email for Loopsy", dir: .theirs, id: "A")
        let mine = loop("Provide Vivek's sister's number and email for Loopsy", dir: .mine, at: Self.now.addingTimeInterval(86400), id: "B")
        let out = LoopQuality.dedupeMirrored([theirs, mine])
        #expect(out.map(\.id) == ["A"], "the first stays, the mirror goes")
        #expect(LoopQuality.dedupeMirrored([mine, theirs]).map(\.id) == ["B"], "whichever came first")
    }
    @Test func twoRealLoopsInOppositeDirectionsStay() {
        let a = loop("Send the signed NDA", dir: .mine, id: "A"), b = loop("Share the cap table", dir: .theirs, id: "B")
        #expect(LoopQuality.dedupeMirrored([a, b]).count == 2, "different promises are not mirrors")
        let far = loop("Provide Vivek's sister's number and email for Loopsy", dir: .theirs, at: Self.now.addingTimeInterval(-5 * 86400), id: "C")
        #expect(LoopQuality.dedupeMirrored([loop("Provide her sister's number and email for Loopsy", id: "D"), far]).count == 2, "five days apart is not the same night's mirror")
        let sameSide = loop("Provide Vivek's sister's number and email for Loopsy", dir: .mine, id: "E")
        #expect(LoopQuality.dedupeMirrored([loop("Provide her sister's number and email for Loopsy", id: "F"), sameSide]).count == 2, "the same direction is the ledger's own dedupe, not a mirror")
        #expect(LoopQuality.dedupeMirrored([loop("Send the deck", person: "Arjun", id: "G"), loop("Send the deck", person: "Kanika", dir: .theirs, id: "H")]).count == 2, "another person is another loop")
    }

    @Test func theGateDropsSentimentsMirrorsAndTheUserAsTheOtherParty() {
        let loops = [loop("Build a company with Kanika", id: "1"), loop("Close one more deal after SBI", person: "Vivek Upreti", id: "2"),
                     loop("Provide her sister's number and email for Loopsy", dir: .theirs, id: "3"), loop("Provide Vivek's sister's number and email for Loopsy", id: "4"),
                     loop("Send Kanika the final proposal", id: "5"), loop("Ping Arif again", person: "Vivek", id: "6")]
        let out = LoopQuality.admit(loops, selfNames: ["Vivek Upreti", "vivek"])
        #expect(out.kept.map(\.id) == ["3", "5"])
        #expect(out.rejected.map(\.loop.id) == ["1", "2", "4", "6"])
        #expect(out.rejected[0].reason.contains("intention") && out.rejected[1].reason.contains("the user") && out.rejected[2].reason.contains("mirrors") && out.rejected[3].reason.contains("the user"))
        #expect(LoopQuality.admit(loops).kept.count == 4, "with no self names known, only the bar and the mirror rule apply")
        let open = loop("Provide her sister's number and email for Loopsy", dir: .theirs, at: Self.now.addingTimeInterval(-2 * 86400), id: "OPEN")
        let lastNight = LoopQuality.admit([loops[3]], existing: [open])
        #expect(lastNight.kept.isEmpty && lastNight.rejected.first?.reason.contains("mirrors") == true, "the mirror of a loop still open from an earlier night is turned away too")
        var closed = open; closed.status = .closed
        #expect(LoopQuality.admit([loops[3]], existing: [closed]).kept.count == 1, "a closed loop mirrors nothing")
    }
}

@Suite struct LoopSweepTests {
    func loop(_ person: String, _ what: String, _ status: LoopStatus = .open) -> Loop {
        var l = Loop(id: UUID().uuidString, direction: .mine, person: person, what: what, quote: "q", sourceLabel: "WhatsApp", due: nil, openedAt: Date(timeIntervalSince1970: 1_789_000_000))
        l.status = status; return l
    }
    @Test func nobodyIsNoOtherParty() {
        for bad in ["another contact", "someone", "the team", "a colleague", "them", "Unknown", "N/A", "123", ""] { #expect(!LoopQuality.isPersonLabel(bad), "\(bad)") }
        for good in ["Tom", "Kanika Pandey Loadmill", "Mr. Taragi", "Amma", "Nitesh", "Priya's team lead"] { #expect(LoopQuality.isPersonLabel(good), "\(good)") }
    }
    @Test func theSweepHoldsAnOldLedgerToTheBar() {
        let loops = [loop("Kanika Pandey Loadmill", "Build something big"), loop("Kanika Pandey Loadmill", "Build a company with Kanika", .closed), loop("another contact", "Call them to discuss something else", .closed),
                     loop("Vivek Upreti", "Close one more deal after SBI"), loop("Kanika Pandey Loadmill", "Call Mr. Taragi"), loop("Nitesh", "Provide rough estimates for the three requested tasks"), loop("Tom", "Send Tom an update")]
        let (kept, dropped) = LoopQuality.sweep(loops, selfNames: ["Vivek Upreti"])
        #expect(kept.map(\.what) == ["Call Mr. Taragi", "Provide rough estimates for the three requested tasks", "Send Tom an update"])
        #expect(dropped.count == 4 && dropped.contains { $0.reason.contains("nobody") } && dropped.contains { $0.reason.contains("the user") })
        #expect(LoopQuality.sweep(kept, selfNames: ["Vivek Upreti"]).dropped.isEmpty, "a clean ledger is untouched")
    }
}

@Suite struct LoopQualityVerbShapesTests {
    @Test func implementIsAVerbAndTryToIsAHedgeOnADeliverable() {
        for good in ["Implement the feature Nitesh sent", "Try to send Nayan the outstanding payment via UPI", "Will try to call Mr. Taragi", "Document the API for Arif", "Present the deck to SBI", "Agreed to send the invoice"] {
            #expect(LoopQuality.isCommitment(good), "\(good): \(LoopQuality.reason(good) ?? "")")
        }
        for bad in ["Try harder", "Try", "Implementation of the feature", "Try to be better", "Figure out the product confusion", "Work out the pricing"] { #expect(!LoopQuality.isCommitment(bad), "\(bad)") }
    }
}
