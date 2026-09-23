import Testing
import Foundation
@testable import Proactive
import Domain
import Knowledge

/// A rated note goes out with the summaries it was written from: the ones of the last thirty days that name it, newest
/// first, sixty at most — to a file named for the day and the note, whose body stays the one that was rated.
@Suite struct NoteEvalExportTests {
    // 2026-09-18 12:00 UTC, a Friday.
    static let now = Date(timeIntervalSince1970: 1_789_732_800)
    static let utc = TimeZone(identifier: "UTC")!
    static func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
    /// A summary row as the reader would have kept it, merged `mergedDaysAgo` ago (nil: never merged).
    static func row(_ id: Int64, bucket: String = "Family", title: String = "t", text: String, mergedDaysAgo: Double? = 1) -> SummaryRecord {
        SummaryRecord(id: id, runID: 1, source: SourceID("whatsapp"), bucket: BucketID("w:\(bucket)"), bucketName: bucket, kind: .directMessage, title: title, text: text,
                      itemDate: ago((mergedDaysAgo ?? 0) + 1), createdAt: ago((mergedDaysAgo ?? 0) + 0.5), sid: "s\(id)", mergedAt: mergedDaysAgo.map(ago))
    }
    static func note(_ body: String, path: String = "People/Meera Iyer.md", aliases: [String] = []) -> Note {
        let m = NoteMeta(brownie: "person", aliases: aliases, created: "2026-09-01", updated: "2026-09-17", contentHash: NoteMeta.hash(body))
        return Note(relativePath: path, title: String(path.split(separator: "/").last!.dropLast(3)), body: body, meta: m, updatedAt: now)
    }
    static func rating(_ n: Note, _ v: NoteFeedback.Verdict = .notRight, reason: String? = "too much hedging", daysAgo: Double = 0) -> NoteFeedback {
        NoteFeedback(path: n.relativePath, title: n.title, contentHash: NoteMeta.hash(n.body), verdict: v, reason: reason, at: ago(daysAgo))
    }
    static func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("note-evals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func read(_ u: URL) throws -> NoteEvalExport.Record { try NoteEvalExport.decoder.decode(NoteEvalExport.Record.self, from: Data(contentsOf: u)) }

    // MARK: selection

    @Test func evidenceIsWhatNamesTheNoteInTheChatTheTitleOrTheText() {
        let rows = [
            Self.row(1, bucket: "Meera Iyer", text: "flight on Friday"),                       // the chat is hers
            Self.row(2, bucket: "Family", text: "Meera Iyer said the villa is booked"),        // named in the text
            Self.row(3, bucket: "Family", title: "Meera Iyer's plan", text: "the plan"),       // named in the title, possessive
            Self.row(4, bucket: "Family", text: "Ameera Iyer is someone else"),                // not a whole word
            Self.row(5, bucket: "Work", text: "nothing about her"),
            Self.row(6, bucket: "Family", text: "MEERA IYER in capitals counts"),
        ]
        let picked = NoteEvalExport.evidence(title: "Meera Iyer", aliases: [], in: rows, now: Self.now)
        #expect(picked.map(\.id) == [6, 3, 2, 1], "all merged the same night, so the later rows first")
    }

    @Test func aliasesCountAndTheWindowIsThirtyDaysOfMergedRows() {
        let rows = [
            Self.row(1, bucket: "Family", text: "Mee sent the photos"),                        // an alias, whole word
            Self.row(2, bucket: "Family", text: "Meerabai is a different name"),
            Self.row(3, bucket: "Meera Iyer", text: "merged a month ago", mergedDaysAgo: 30),  // on the edge: out
            Self.row(4, bucket: "Meera Iyer", text: "merged just inside", mergedDaysAgo: 29.9),
            Self.row(5, bucket: "Meera Iyer", text: "never merged: not in the notes yet", mergedDaysAgo: nil),
        ]
        #expect(NoteEvalExport.evidence(title: "Meera Iyer", aliases: ["Mee", " "], in: rows, now: Self.now).map(\.id) == [1, 4])
        #expect(NoteEvalExport.evidence(title: " ", aliases: [], in: rows, now: Self.now).isEmpty, "no name, no evidence")
    }

    @Test func evidenceIsNewestMergedFirstAndCappedAtSixty() {
        let rows = (1...80).map { Self.row(Int64($0), bucket: "Meera", text: "row \($0)", mergedDaysAgo: Double($0) / 10) }
        let picked = NoteEvalExport.evidence(title: "Meera", aliases: [], in: rows, now: Self.now)
        #expect(picked.count == NoteEvalExport.cap && picked.first?.id == 1 && picked.last?.id == 60)
        let sameNight = [Self.row(1, bucket: "Meera", text: "a", mergedDaysAgo: 1), Self.row(2, bucket: "Meera", text: "b", mergedDaysAgo: 1)]
        #expect(NoteEvalExport.evidence(title: "Meera", aliases: [], in: sameNight, now: Self.now).map(\.id) == [2, 1], "merged together: the later row first")
    }

    @Test func wholeWordsWhateverTheCaseOrAccents() {
        #expect(NoteEvalExport.mentions("Meera's flight", "Meera") && NoteEvalExport.mentions("with meera.", "Meera") && NoteEvalExport.mentions("Méera", "Meera"))
        #expect(!NoteEvalExport.mentions("Ameera", "Meera") && !NoteEvalExport.mentions("Meerabai", "Meera") && !NoteEvalExport.mentions("Meera2", "Meera"))
        #expect(NoteEvalExport.mentions("KP Loadmill said", "KP") && !NoteEvalExport.mentions("a backpack", "KP"))
    }

    // MARK: the file

    @Test func theFileIsNamedForTheDayAndTheNote() {
        let fb = Self.rating(Self.note("# Meera Iyer\n"))
        #expect(NoteEvalExport.fileName(fb, timeZone: Self.utc) == "2026-09-18-people-meera-iyer.json")
        let late = NoteFeedback(path: "Groups/Building Chat.md", title: "Building Chat", contentHash: "h", verdict: .good, at: Self.now.addingTimeInterval(11 * 3600))
        #expect(NoteEvalExport.fileName(late, timeZone: Self.utc) == "2026-09-18-groups-building-chat.json")
        #expect(NoteEvalExport.fileName(late, timeZone: TimeZone(identifier: "Asia/Kolkata")!) == "2026-09-19-groups-building-chat.json", "the day is the clock's")
        #expect(NoteEvalExport.slug("Work/Q4 Launch (v2).md") == "work-q4-launch-v2" && NoteEvalExport.slug("Café Réunion.md") == "cafe-reunion" && NoteEvalExport.slug("...") == "note")
    }

    @Test func theBodyKeptIsTheOneThatWasRated() {
        let rated = "# Meera\n\nShe will probably maybe come.\n", rewritten = "# Meera\n\nShe is coming on Friday.\n"
        let hash = NoteMeta.hash(rated)
        func rec(_ body: String, summaries: [NoteEvalExport.Summary] = []) -> NoteEvalExport.Record {
            NoteEvalExport.Record(path: "People/Meera.md", title: "Meera", body: body, contentHash: hash, verdict: .notRight, reason: "hedging", at: Self.now, summaries: summaries)
        }
        let more = [NoteEvalExport.Summary(Self.row(9, text: "new evidence"))]
        #expect(NoteEvalExport.merged(existing: nil, fresh: rec(rewritten)) == rec(rewritten), "nothing on record: what is on disk is written")
        #expect(NoteEvalExport.merged(existing: rec(rated), fresh: rec(rewritten, summaries: more)) == rec(rated, summaries: more), "the note moved on overnight: the rated body stays, the evidence is tonight's")
        #expect(NoteEvalExport.merged(existing: rec(rewritten), fresh: rec(rated, summaries: more)) == rec(rated, summaries: more), "the note on disk is the rated one: it wins over a stale file")
        #expect(NoteEvalExport.merged(existing: rec("older words"), fresh: rec(rewritten)) == rec(rewritten), "neither matches: the note on disk")
        #expect(NoteEvalExport.merged(existing: rec("older words"), fresh: rec("", summaries: more)) == rec("older words", summaries: more), "the note is gone: the file's words stay")
    }

    @Test func aRatingIsWrittenWithItsEvidenceAndTheRegistrysSpellings() throws {
        let dir = try Self.folder()
        let n = Self.note("# Meera Iyer\n\n## About\n- probably lives in Goa\n", aliases: ["Mee"])
        let fb = Self.rating(n, reason: "too much hedging")
        let people = [Person(id: "p1", name: "Meera", aliases: ["Meera I"], notePath: n.relativePath, firstSeen: Self.now, lastSeen: Self.now),
                      Person(id: "p2", name: "Karan", aliases: ["KK"], notePath: "People/Karan.md", firstSeen: Self.now, lastSeen: Self.now)]
        let rows = [Self.row(1, bucket: "Family", text: "Mee is in Goa"), Self.row(2, bucket: "Family", text: "Meera I called"), Self.row(3, bucket: "Family", text: "KK called"), Self.row(4, bucket: "Family", text: "Karan's turn")]
        let url = try #require(try NoteEvalExport.write(fb, note: n, rows: rows, people: people, folder: dir, now: Self.now, timeZone: Self.utc))
        #expect(url.lastPathComponent == "2026-09-18-people-meera-iyer.json")
        let r = try Self.read(url)
        #expect(r.path == n.relativePath && r.title == "Meera Iyer" && r.body == n.body && r.contentHash == NoteMeta.hash(n.body))
        #expect(r.verdict == .notRight && r.reason == "too much hedging" && r.at == fb.at)
        #expect(r.summaries.map(\.id) == [2, 1], "the note's own aliases and the registry's, not another person's")
        #expect(r.summaries[0].bucketName == "Family" && r.summaries[0].source == "whatsapp" && r.summaries[0].sid == "s2" && r.summaries[0].mergedAt == Self.ago(1))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"verdict\" : \"notRight\"") && raw.contains("\"at\" : \"2026-09-18T12:00:00Z\""), "plain words and ISO dates, for a person or an eval runner to read")
    }

    @Test func aSecondExportRefreshesTheEvidenceAndKeepsTheRatedWords() throws {
        let dir = try Self.folder()
        let rated = Self.note("# Meera Iyer\n\nprobably in Goa\n")
        let fb = Self.rating(rated)
        try NoteEvalExport.write(fb, note: rated, rows: [Self.row(1, bucket: "Meera Iyer", text: "first night")], people: [], folder: dir, now: Self.now, timeZone: Self.utc)
        // The night rewrote the note and merged more; FINISH exports again at the same file.
        let rewritten = Self.note("# Meera Iyer\n\nin Goa till Sunday\n")
        let url = try #require(try NoteEvalExport.write(fb, note: rewritten, rows: [Self.row(1, bucket: "Meera Iyer", text: "first night"), Self.row(2, bucket: "Meera Iyer", text: "second night", mergedDaysAgo: 0.1)], people: [], folder: dir, now: Self.now.addingTimeInterval(86400), timeZone: Self.utc))
        let r = try Self.read(url)
        #expect(r.body == rated.body && r.summaries.map(\.id) == [2, 1], "the rated words, tonight's evidence")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1, "one file per rating")
        // The note is gone altogether: the file keeps its words and still gets the evidence.
        let gone = try #require(try NoteEvalExport.write(fb, note: nil, rows: [Self.row(3, bucket: "Meera Iyer", text: "after")], people: [], folder: dir, now: Self.now, timeZone: Self.utc))
        #expect(try Self.read(gone).body == rated.body && (try Self.read(gone)).summaries.map(\.id) == [3])
        #expect(try NoteEvalExport.write(Self.rating(Self.note("x", path: "People/Nobody.md")), note: nil, rows: [], people: [], folder: dir, now: Self.now, timeZone: Self.utc) == nil, "no note and nothing on record: nothing to write")
    }

    @Test func exportAllTakesEveryRatingOfTheLastThirtyDays() async throws {
        let dir = try Self.folder()
        let meera = Self.note("# Meera Iyer\n"), karan = Self.note("# Karan\n", path: "People/Karan.md")
        var list = NoteFeedbackList()
        list.add(Self.rating(meera, .good, reason: nil, daysAgo: 2), now: Self.now)
        list.add(Self.rating(karan, reason: "wrong person", daysAgo: 29), now: Self.now)
        list.add(Self.rating(Self.note("# Old\n", path: "People/Old.md"), daysAgo: 31), now: Self.now)
        let kb = FakeKnowledge(notes: [meera, karan])
        let store = FakeStore(rows: [Self.row(1, bucket: "Karan", text: "x"), Self.row(2, bucket: "Meera Iyer", text: "y")])
        let n = await NoteEvalExport.exportAll(list, knowledge: kb, store: store, people: [], folder: dir, now: Self.now, timeZone: Self.utc)
        #expect(n == 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["2026-08-20-people-karan.json", "2026-09-16-people-meera-iyer.json"], "the one older than thirty days is not exported")
        #expect(try Self.read(dir.appendingPathComponent(files[0])).summaries.map(\.id) == [1] && (try Self.read(dir.appendingPathComponent(files[1]))).verdict == .good)
    }

    // MARK: fakes

    struct FakeKnowledge: KnowledgeStore {
        let notes: [Note]
        var rootURL: URL { URL(fileURLWithPath: "/nowhere") }
        func exists() async -> Bool { true }
        func folders() async throws -> [KnowledgeFolder] { [] }
        func note(at relativePath: String) async throws -> Note? { notes.first { $0.relativePath == relativePath } }
        func save(_ note: Note) async throws {}
        func delete(relativePath: String) async throws {}
        func search(_ query: String, limit: Int) async throws -> [Note] { [] }
        func fingerprint() async throws -> String { "" }
        func noteCount() async throws -> Int { notes.count }
    }
    /// Only `summaries(since:)` answers; the export asks nothing else of the store.
    struct FakeStore: RunStore {
        let rows: [SummaryRecord]
        func beginRun(trigger: RunTrigger, at: Date) async throws -> Int64 { 0 }
        func endRun(_ id: Int64, outcome: RunOutcome, stats: RunStats, at: Date) async throws {}
        func recentRuns(limit: Int) async throws -> [RunRecord] { [] }
        func lastRun() async throws -> RunRecord? { nil }
        func cursor(_ bucket: BucketID) async throws -> BucketCursor? { nil }
        func cursors(for source: SourceID) async throws -> [BucketCursor] { [] }
        func commit(runID: Int64, cursor: BucketCursor, bucketName: String, candidate: Candidate, outcome: Outcome, at: Date) async throws {}
        func setCursor(_ cursor: BucketCursor, at: Date) async throws {}
        func clearBucket(_ bucket: BucketID) async throws {}
        func resetCursors(for source: SourceID) async throws {}
        func summaries(since: Date?) async throws -> [SummaryRecord] { rows }
        func unmergedSummaries() async throws -> [SummaryRecord] { [] }
        func markMerged(ids: [Int64], at: Date) async throws {}
        func retireMerged(now: Date, keepFor: TimeInterval) async throws {}
        func wipeSummaries() async throws {}
        func drops(since: Date) async throws -> [DropRecord] { [] }
        func logSend(purpose: String, model: String, bytes: Int, detail: String, cameBack: String, payload: String, at: Date) async throws -> Int64 { 0 }
        func setSendResult(_ id: Int64, cameBack: String) async throws {}
        func sendLog(since: Date) async throws -> [SendRecord] { [] }
        func value(_ key: String) async throws -> String? { nil }
        func setValue(_ key: String, _ value: String?) async throws {}
        func keys(withPrefix prefix: String) async throws -> [String] { [] }
        func prune(now: Date) async throws {}
        func factoryReset() async throws {}
    }
}
