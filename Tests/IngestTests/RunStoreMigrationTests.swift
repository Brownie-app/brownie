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
        #expect(cols.contains("sid") && cols.contains("merged_at"))
        let rows = try await store.summaries(since: nil)
        #expect(rows.count == 1 && rows[0].sid == nil && rows[0].mergedAt == nil && rows[0].text == "old row")
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
