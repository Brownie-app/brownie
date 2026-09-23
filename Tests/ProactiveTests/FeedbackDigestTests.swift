import Testing
import Foundation
@testable import Proactive
import Domain

/// Thumbs-downs become instructions the judge reads; the Sunday letter owns them.
@Suite struct FeedbackDigestTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func fb(_ v: CardFeedback.Verdict, title: String = "Reply to Rohan", person: String? = "Rohan", note: String = "", daysAgo: Double = 1) -> CardFeedback {
        CardFeedback(cardID: UUID().uuidString, cardTitle: title, person: person, sourceLabel: "WhatsApp", verdict: v, note: note, at: now.addingTimeInterval(-daysAgo * 86400))
    }

    @Test func nothingSaysNothing() { #expect(FeedbackDigest.instructions([], now: now) == "") }

    @Test func notMineBecomesANeverRule() {
        let s = FeedbackDigest.instructions([fb(.notMine, person: "Rohan"), fb(.notMine, title: "Villa share", person: "Rohan")], now: now)
        #expect(s == "Anything involving Rohan is not the user's — never make a card about it.", "one rule per person, however many cards")
    }

    @Test func notImportantOnceIsAHintTwiceIsARule() {
        #expect(FeedbackDigest.instructions([fb(.notImportant, person: "Amma")], now: now).contains("raise the bar for that person"))
        #expect(FeedbackDigest.instructions([fb(.notImportant, person: "Amma"), fb(.notImportant, title: "x", person: "Amma")], now: now).contains("Cards about Amma only when there is a promise or a deadline"))
    }

    @Test func tooFormalPerPersonAndGlobally() {
        let one = FeedbackDigest.instructions([fb(.tooFormal, person: "Kanika")], now: now)
        #expect(one == "Drafts to Kanika: plain and casual, the way the user writes to them.")
        let two = FeedbackDigest.instructions([fb(.tooFormal, person: "Kanika"), fb(.tooFormal, person: "Meera")], now: now)
        #expect(two.hasPrefix("Every draft was too formal for this user"))
        #expect(two.contains("Drafts to Kanika") && two.contains("Drafts to Meera"))
    }

    @Test func specificCardsAreNamedWithTheDate() {
        let s = FeedbackDigest.instructions([fb(.alreadyDone, title: "Send the deck", daysAgo: 2), fb(.wrongPerson, title: "Book the table", person: "Priya"), fb(.wrongTiming, title: "Diwali flights"), fb(.other, title: "Villa", note: " Rohan handles the villa now ")], now: now)
        let f = DateFormatter(); f.dateFormat = "d MMM"
        #expect(s.contains("“Send the deck” was already done (the user said so on \(f.string(from: now.addingTimeInterval(-2 * 86400))))"))
        #expect(s.contains("“Book the table” named the wrong person (it was addressed to Priya)"))
        #expect(s.contains("“Diwali flights” came too early"))
        #expect(s.contains("About “Villa” the user said: “Rohan handles the villa now”."), "notes are trimmed and quoted verbatim")
    }

    @Test func oldLessonsFadeAndTheListIsCapped() {
        #expect(FeedbackDigest.instructions([fb(.notMine, daysAgo: 91)], now: now) == "", "90-day horizon")
        let many = (0..<40).map { fb(.alreadyDone, title: "Card \($0)", daysAgo: Double($0) / 10) }
        let lines = FeedbackDigest.instructions(many, now: now).split(separator: "\n")
        #expect(lines.count == FeedbackDigest.maxLines)
        #expect(lines.first!.contains("Card 0"), "newest first")
    }

    @Test func weekLineOwnsTheMisses() {
        let since = now.addingTimeInterval(-6 * 86400)
        #expect(FeedbackDigest.weekLine([], since: since) == "")
        #expect(FeedbackDigest.weekLine([fb(.notMine, daysAgo: 10)], since: since) == "", "only this week")
        let line = FeedbackDigest.weekLine([fb(.notMine, person: "Rohan"), fb(.tooFormal), fb(.tooFormal), fb(.alreadyDone)], since: since)
        #expect(line == "You corrected 4 cards this week: 1 wasn't yours (Rohan) · 1 already done · 2 too formal. Those lessons are now in Brownie's standing instructions.")
    }

    @Test func roundTripsThroughJSON() throws {
        let f = fb(.other, note: "hi")
        #expect(try JSONDecoder().decode(CardFeedback.self, from: JSONEncoder().encode(f)) == f)
    }

    @Test func cardPersonComesFromTheRecipe() {
        func c(_ r: Recipe) -> Card { Card(id: "1", title: "t", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .low, draftLabel: "", draft: "", recipe: r, evidence: [], verification: .verified, verifiedLine: "", createdAt: now) }
        #expect(c(.whatsapp(chat: "Rohan", body: "")).person == "Rohan")
        #expect(c(.mail(to: "arif@x.com", subject: "", body: "", attachments: [])).person == "arif@x.com")
        #expect(c(.browser(url: "u")).person == nil)
    }
}
