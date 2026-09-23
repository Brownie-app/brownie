import Testing
import Foundation
import Domain
@testable import Platform

/// A store written before summaries had a stable id or a merged mark opens cleanly: the columns are
/// added, old rows read back with neither, and they still count as unmerged.
@Suite struct RunStoreMigrationTests {
    static func oldDatabase() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("old-store-\(UUID().uuidString).sqlite").path
        do {
            let db = try SQLite(path: path)
            try db.exec("""
            CREATE TABLE summary(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, source_id TEXT NOT NULL,
                bucket_id TEXT NOT NULL, bucket_name TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
                item_date REAL, created_at REAL NOT NULL);
            CREATE INDEX summary_created ON summary(created_at);
            """)
            try db.run("INSERT INTO summary(run_id, source_id, bucket_id, bucket_name, kind, title, text, item_date, created_at) VALUES(?,?,?,?,?,?,?,?,?)",
                       [.int(1), .text("whatsapp"), .text("whatsapp:1"), .text("Nayan"), .text("directMessage"), .text("T"), .text("old row"), .real(1_700_000_000), .real(1_700_000_100)])
        }
        return path
    }

    static func columns(_ path: String) throws -> Set<String> {
        Set(try SQLite(path: path, readOnly: true).query("PRAGMA table_info(summary)").compactMap { $0["name"].text })
    }

    @Test func oldStoreGainsTheColumnsAndOldRowsReadBackWithoutThem() async throws {
        let path = try Self.oldDatabase()
        #expect(!(try Self.columns(path)).contains("sid"))
        let store = try SQLiteRunStore(path: path)
        let cols = try Self.columns(path)
        #expect(cols.contains("sid") && cols.contains("merged_at") && cols.contains("judged_at"))
        let rows = try await store.summaries(since: nil)
        #expect(rows.count == 1 && rows[0].sid == nil && rows[0].mergedAt == nil && rows[0].judgedAt == nil && rows[0].text == "old row")
        #expect(try await store.unmergedSummaries().map(\.id) == [rows[0].id], "an old row has not been merged")
        try await store.markMerged(ids: [rows[0].id], at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await store.unmergedSummaries().isEmpty)
        #expect(try await store.summaries(since: nil)[0].mergedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func openingTwiceIsHarmless() async throws {
        let path = try Self.oldDatabase()
        _ = try SQLiteRunStore(path: path)
        let again = try SQLiteRunStore(path: path)
        #expect(try await again.summaries(since: nil).count == 1)
    }

    /// A store from the build that listed every file and walked 500 a night, with cursors left mid-walk.
    static func oldCursorDatabase() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("old-cursors-\(UUID().uuidString).sqlite").path
        do {
            let db = try SQLite(path: path)
            try db.exec("""
            CREATE TABLE bucket_cursor(bucket_id TEXT PRIMARY KEY, source_id TEXT NOT NULL,
                mark_order REAL, mark_tiebreak TEXT, floor_order REAL, floor_tiebreak TEXT, updated_at REAL NOT NULL);
            """)
            let rows: [(String, String, Double, Double?)] = [("files:downloads", "files", 1_789_000_000, 1_763_000_000), ("notes:all", "notes", 1_789_000_000, 1_750_000_000),
                                                             ("voicememos:all", "voicememos", 1_789_000_000, 1_780_000_000), ("recordings:all", "recordings", 1_789_000_000, 1_780_000_000),
                                                             ("whatsapp:7", "whatsapp", 1_789_000_000, 1_788_000_000), ("files:desktop", "files", 1_789_000_000, nil)]
            for (bucket, source, mark, floor) in rows {
                try db.run("INSERT INTO bucket_cursor(bucket_id, source_id, mark_order, mark_tiebreak, floor_order, floor_tiebreak, updated_at) VALUES(?,?,?,?,?,?,?)",
                           [.text(bucket), .text(source), .real(mark), .text("m"), floor.map { .real($0) } ?? .null, .init(floor.map { _ in "f" }), .real(1_789_100_000)])
            }
            // A files root the old build never got a mark on: its floor is not a wedge, and it must stay.
            try db.run("INSERT INTO bucket_cursor(bucket_id, source_id, mark_order, mark_tiebreak, floor_order, floor_tiebreak, updated_at) VALUES(?,?,?,?,?,?,?)",
                       [.text("files:odd"), .text("files"), .null, .null, .real(1_763_000_000), .text("f"), .real(1_789_100_000)])
        }
        return path
    }

    @Test func windowBoundSourcesLoseAFloorTheNewWindowCouldNeverReachOnceAndChatsKeepTheirs() async throws {
        let path = try Self.oldCursorDatabase()
        let store = try SQLiteRunStore(path: path)
        for bucket in ["files:downloads", "notes:all", "voicememos:all", "recordings:all"] {
            let c = try #require(try await store.cursor(BucketID(bucket)))
            #expect(c.isComplete && c.mark?.order == 1_789_000_000, "\(bucket) resumes incrementally from its mark")
        }
        let chat = try #require(try await store.cursor(BucketID("whatsapp:7")))
        #expect(chat.floor?.order == 1_788_000_000, "a chat mid-first-read still walks below its floor inside the slice")
        let markless = try #require(try await store.cursor(BucketID("files:odd")))
        #expect(markless.mark == nil && markless.floor?.order == 1_763_000_000)
        let desktop = try #require(try await store.cursor(BucketID("files:desktop")))
        #expect(desktop.isComplete && desktop.setAside == 0 && desktop.gated.isEmpty, "old rows read back with nothing set aside and nothing gated")

        // The collapse ran once: a floor this build leaves behind survives the next opening.
        let midway = BucketCursor(bucket: BucketID("files:downloads"), source: "files", mark: ItemKey(order: 1_789_400_000, tiebreak: "n"), floor: ItemKey(order: 1_789_300_000, tiebreak: "o"))
        try await store.setCursor(midway, at: Date(timeIntervalSince1970: 1_789_500_000))
        let reopened = try SQLiteRunStore(path: path)
        #expect(try await reopened.cursor(BucketID("files:downloads")) == midway)
    }

    @Test func aCursorWrittenByItselfRoundTripsWithWhatItSetAsideAndWhatItGated() async throws {
        let store = try SQLiteRunStore.inMemory()
        let gated = [ItemKey(order: 2_001_513_725, tiebreak: "y2033"), ItemKey(order: 2_101_513_725, tiebreak: "y2036")]
        let c = BucketCursor(bucket: BucketID("capped:chat"), source: "capped", mark: ItemKey(order: 9, tiebreak: "m9"), floor: nil, setAside: 4_990, gated: gated)
        try await store.setCursor(c, at: Date(timeIntervalSince1970: 1_789_500_000))
        #expect(try await store.cursor(c.bucket) == c)
        #expect(try await store.cursors(for: "capped") == [c])
        let summaries = try await store.summaries(since: nil), drops = try await store.drops(since: .distantPast)
        #expect(summaries.isEmpty && drops.isEmpty, "no item stands behind the write")
        var moved = c; moved.floor = nil; moved.setAside = 0; moved.gated = []
        try await store.setCursor(moved, at: Date(timeIntervalSince1970: 1_789_500_100))
        #expect(try await store.cursor(c.bucket) == moved, "a second write replaces, including an emptied gated list")
    }

    @Test func newRowsCarryAStableIdThatOnlyDependsOnTheItem() async throws {
        let store = try SQLiteRunStore.inMemory()
        let run = try await store.beginRun(trigger: .test, at: Date())
        let key = ItemKey(order: 42, tiebreak: "m42")
        let c = Candidate(source: "whatsapp", bucket: BucketID("whatsapp:1"), key: key, kind: .directMessage, id: "m42", itemDate: Date())
        try await store.commit(runID: run, cursor: BucketCursor(bucket: c.bucket, source: c.source, mark: key, floor: nil), bucketName: "Nayan",
                               candidate: c, outcome: Outcome(reason: .kept, survivor: Survivor(_unchecked: "T", summary: "s")), at: Date())
        let row = try #require(try await store.summaries(since: nil).first)
        #expect(row.sid == SQLiteRunStore.stableID(c))
        #expect(row.sid?.count == 12 && row.sid!.allSatisfy { $0.isHexDigit })
        let sameItemOtherNight = Candidate(source: "whatsapp", bucket: BucketID("whatsapp:1"), key: key, kind: .directMessage, id: "m42", itemDate: nil, metadata: ["x": "y"])
        #expect(SQLiteRunStore.stableID(sameItemOtherNight) == row.sid, "date and metadata do not change the id")
        let otherItem = Candidate(source: "whatsapp", bucket: BucketID("whatsapp:1"), key: ItemKey(order: 43, tiebreak: "m43"), kind: .directMessage, id: "m43", itemDate: nil)
        #expect(SQLiteRunStore.stableID(otherItem) != row.sid)
    }
}
