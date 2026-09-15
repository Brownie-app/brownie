import Testing
import Foundation
@testable import Proactive
import Domain

/// A promise said out loud becomes a loop with its timestamp, in the right direction.
@Suite struct TranscriptPromisesTests {
    let date = Date(timeIntervalSince1970: 1_757_600_000), now = Date(timeIntervalSince1970: 1_757_700_000)
    func parse(_ s: String) -> [TranscriptPromises.Found] { TranscriptPromises.parse(summary: s, recording: "Meera call", date: date, now: now) }

    @Test func theUserPromisingIsMine() {
        let f = parse(#"The user and Meera go through pricing. At [03:12] the user says "I'll send it by Thursday" to Meera. Small talk follows."#)
        #expect(f.count == 1)
        let l = f[0].loop
        #expect(l.direction == .mine && l.person == "Meera" && l.what == "send it by Thursday" && l.quote == "I'll send it by Thursday")
        #expect(l.sourceLabel == "Recording · Meera call · 03:12" && f[0].seconds == 192)
        #expect(l.due == "by Thursday" && l.openedAt == date && l.status == .open)
        #expect(l.id.hasPrefix("rec-"))
    }

    @Test func themPromisingIsTheirsAndAsksFlip() {
        let f = parse(#"At [05:40] Meera says "I'll share the deck tonight". At [07:02] Meera asks "can you review the numbers before Friday?". At [09:15] the user asks "could you send the invoice" to Rohan Mehta."#)
        #expect(f.map { $0.loop.direction } == [.theirs, .mine, .theirs])
        #expect(f.map { $0.loop.person } == ["Meera", "Meera", "Rohan Mehta"])
        #expect(f.map { $0.loop.what } == ["share the deck tonight", "review the numbers before Friday", "send the invoice"])
        #expect(f[1].loop.due == "before Friday")
    }

    @Test func statementsThatAreNotPromisesAreIgnored() {
        #expect(parse(#"At [01:00] the user says "the weather was awful in Goa" to Meera."#).isEmpty)
        #expect(parse(#"At [01:00] Meera says "the numbers look fine"."#).isEmpty)
        #expect(parse("No timestamps at all; the user talks through the plan.").isEmpty)
    }

    @Test func longRecordingsAndCurlyQuotes() {
        let f = parse("At [1:02:05] the user promised “I’ll call the landlord tomorrow” to Priya.")
        #expect(f.count == 1 && f[0].seconds == 3725 && f[0].loop.what == "call the landlord tomorrow" && f[0].loop.person == "Priya")
    }

    @Test func idsAreStableAcrossNightsSoNothingDoubles() {
        let a = parse(#"At [03:12] the user says "I'll send it by Thursday" to Meera."#)[0].loop.id
        let b = parse(#"At [03:12] the user says "I'll send it by Thursday" to Meera."#)[0].loop.id
        #expect(a == b)
        #expect(TranscriptPromises.parse(summary: #"At [03:12] the user says "I'll send it by Thursday" to Meera."#, recording: "Other call", date: date, now: now)[0].loop.id != a)
    }

    @Test func onlyTheUsersPromisesBecomeCards() {
        let f = parse(#"At [03:12] the user says "I'll send it by Thursday" to Meera. At [05:40] Meera says "I'll share the deck"."#)
        let c = TranscriptPromises.candidates(f)
        #expect(c.count == 1 && c[0].title == "You said you'd send it by Thursday" && c[0].loopID == f[0].loop.id && c[0].urgency == .high)
        #expect(c[0].sources == ["Recording · Meera call · 03:12"])
    }
}
