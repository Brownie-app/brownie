import Testing
import Foundation
@testable import Knowledge
import Domain

/// What a night writes when there is no brain: one note per day, the reader's own words, and the questions
/// people are still waiting on at the top. No model is involved, so every one of these is exact.
@Suite struct SummaryNotesTests {
    let utc = TimeZone(identifier: "UTC")!
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }
    /// 11 October 2026, a Sunday, 10:00 UTC.
    let day = Date(timeIntervalSince1970: 1_791_712_800)

    func summary(_ id: Int64, _ source: String, _ bucket: String, title: String, text: String, at: Date? = nil) -> SummaryRecord {
        SummaryRecord(id: id, runID: 1, source: SourceID(source), bucket: BucketID("\(source):\(bucket)"), bucketName: bucket,
                      kind: .directMessage, title: title, text: text, itemDate: at ?? day, createdAt: at ?? day)
    }
    func ask(_ person: String, _ question: String, answeredAt: Date? = nil, addressed: Bool? = nil) -> Ask {
        Ask(id: question, person: person, bucket: BucketID("whatsapp:1"), askedAt: day.addingTimeInterval(-3600),
            question: question, answeredAt: answeredAt, addressed: addressed)
    }

    @Test func aDaysSummariesBecomeOneNoteGroupedByWhereTheyCameFrom() throws {
        let note = try #require(SummaryNotes.render(summaries: [
            summary(1, "files", "Desktop", title: "invoice-sept.pdf", text: "An invoice from Chhabra & Co for September, due on the 20th."),
            summary(2, "whatsapp", "Tanvi Rege", title: "", text: "Tanvi is in Goa from the 3rd to the 6th and asked about the flat."),
            summary(3, "files", "Documents", title: "lease.pdf", text: "The flat's lease runs to March."),
        ], day: day, calendar: cal))
        #expect(note.hasPrefix("# Read on Sunday 11 October"))
        #expect(note.contains("## Files · Desktop") && note.contains("## WhatsApp · Tanvi Rege") && note.contains("## Files · Documents"))
        #expect(note.contains("**invoice-sept.pdf** — An invoice from Chhabra & Co"))
        #expect(note.contains("Brownie read 3 things on this day"), "the count is of what was kept, in words")
        #expect(note.contains("nothing here has been judged or drafted"), "it says what it is not")
    }

    @Test func everyBulletEndsWithTheDateTheVaultExpects() throws {
        let note = try #require(SummaryNotes.render(summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: "Something.")], day: day, calendar: cal))
        let bullets = note.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(!bullets.isEmpty)
        for b in bullets { #expect(b.contains("(2026-10-11)"), "a bullet without its date is a bullet the gardener drops: \(b)") }
    }

    @Test func openAsksAreAtTheTopInTheWordsTheyWereAskedIn() throws {
        let note = try #require(SummaryNotes.render(
            summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: "Something.")],
            asks: [ask("Lalita Pathak", "can you call Mr Vartak about the pen test?"),
                   ask("Zubin Patel", "sorted?", answeredAt: day, addressed: false)],
            day: day, calendar: cal))
        let waiting = note.range(of: "## Waiting on you")
        let files = note.range(of: "## Files")
        #expect(waiting != nil && files != nil && waiting!.lowerBound < files!.lowerBound, "waiting comes first")
        #expect(note.contains("**Lalita Pathak** asked: can you call Mr Vartak about the pen test? — no reply from you yet"))
        #expect(note.contains("**Zubin Patel** asked: sorted? — you wrote back, but not about this"),
                "a reply that settled nothing is not silence, and the note says which it was")
    }

    @Test func aDayWithNothingKeptWritesNoNoteAtAll() {
        #expect(SummaryNotes.render(summaries: [], day: day, calendar: cal) == nil)
        #expect(SummaryNotes.render(summaries: [summary(1, "files", "Desktop", title: "", text: "   \n ")], day: day, calendar: cal) == nil,
                "an empty summary is not a thing to write down")
    }

    @Test func aSecondRunOnTheSameDayAddsOnlyWhatIsNew() throws {
        let first = try #require(SummaryNotes.render(summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: "The first thing.")], day: day, calendar: cal))
        let second = try #require(SummaryNotes.merge(summaries: [
            summary(1, "files", "Desktop", title: "a.pdf", text: "The first thing."),
            summary(2, "whatsapp", "Tanvi Rege", title: "", text: "The second thing."),
        ], day: day, into: first, calendar: cal))
        #expect(second.components(separatedBy: "The first thing.").count - 1 == 1, "the first bullet is not repeated")
        #expect(second.contains("The second thing."))
        #expect(second.components(separatedBy: "# Read on").count - 1 == 1, "one heading")
        #expect(second.components(separatedBy: "Nothing left your Mac").count - 1 == 1, "one footer")
        #expect(SummaryNotes.merge(summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: "The first thing.")],
                                   day: day, into: second, calendar: cal) == nil,
                "a run with nothing new does not touch the file")
    }

    @Test func eachDayGetsItsOwnNoteAndOpenAsksRideOnTodaysOnly() throws {
        let yesterday = day.addingTimeInterval(-86400)
        let notes = SummaryNotes.notes(summaries: [
            summary(1, "files", "Desktop", title: "a.pdf", text: "Today's thing."),
            summary(2, "files", "Desktop", title: "b.pdf", text: "Yesterday's thing.", at: yesterday),
        ], asks: [ask("Lalita Pathak", "where are the numbers?")], now: day, calendar: cal, existing: { _ in nil })
        #expect(notes.map(\.path) == ["Read/2026-10-10.md", "Read/2026-10-11.md"], "oldest first, one file each")
        #expect(notes[0].body.contains("Waiting on you") == false, "a back-dated day does not repeat today's open questions")
        #expect(notes[1].body.contains("Waiting on you"))
    }

    @Test func theNoteSaysNothingLeftYourMac() throws {
        let note = try #require(SummaryNotes.render(summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: "Something.")], day: day, calendar: cal))
        #expect(note.hasSuffix("Written on this Mac by the reader. Nothing left your Mac.\n"))
    }

    @Test func aLongSummaryIsCutToSomethingAPersonWillRead() throws {
        let long = String(repeating: "word ", count: 200)
        let note = try #require(SummaryNotes.render(summaries: [summary(1, "files", "Desktop", title: "a.pdf", text: long)], day: day, calendar: cal))
        let bullet = try #require(note.split(separator: "\n").first { $0.hasPrefix("- ") })
        #expect(bullet.count < 420 && bullet.contains("…"))
    }
}
