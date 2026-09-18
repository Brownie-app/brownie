import Foundation
import Domain
import Support

/// The app's store on SQLite. `commit` is ONE transaction: summary (if kept) + drop-log row (if
/// dropped) + cursor advance. A crash anywhere leaves the store consistent.
public actor SQLiteRunStore: RunStore {
    private let db: SQLite
    private let log = Log("store")

    public init(path: String) throws {
        db = try SQLite(path: path)
        try migrate()
    }

    public static func inMemory() throws -> SQLiteRunStore { try SQLiteRunStore(path: ":memory:") }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS run(id INTEGER PRIMARY KEY, trigger TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
            outcome TEXT, stats TEXT NOT NULL DEFAULT '{}');
        CREATE TABLE IF NOT EXISTS bucket_cursor(bucket_id TEXT PRIMARY KEY, source_id TEXT NOT NULL,
            mark_order REAL, mark_tiebreak TEXT, floor_order REAL, floor_tiebreak TEXT, updated_at REAL NOT NULL,
            set_aside INTEGER NOT NULL DEFAULT 0, gated TEXT);
        CREATE TABLE IF NOT EXISTS summary(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, source_id TEXT NOT NULL,
            bucket_id TEXT NOT NULL, bucket_name TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
            item_date REAL, created_at REAL NOT NULL, sid TEXT, merged_at REAL, judged_at REAL);
        CREATE INDEX IF NOT EXISTS summary_created ON summary(created_at);
        CREATE TABLE IF NOT EXISTS drop_log(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, source_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL, reason TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS drop_at ON drop_log(at);
        CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS send_log(id INTEGER PRIMARY KEY, at REAL NOT NULL, purpose TEXT NOT NULL, model TEXT NOT NULL,
            bytes INTEGER NOT NULL, detail TEXT NOT NULL, came_back TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS send_at ON send_log(at);
        """)
        // Stores from before summaries had a stable id or a merged mark: add the columns; old rows read back nil.
        let columns = Set(try db.query("PRAGMA table_info(summary)").compactMap { $0["name"].text })
        if !columns.contains("sid") { try db.exec("ALTER TABLE summary ADD COLUMN sid TEXT") }
        if !columns.contains("merged_at") { try db.exec("ALTER TABLE summary ADD COLUMN merged_at REAL") }
        // Stores from before merged rows stayed as evidence: a merged row still here was never judged (the old FINISH
        // deleted judged rows), so it reads back unjudged and is owed to the judge — exactly as before.
        if !columns.contains("judged_at") { try db.exec("ALTER TABLE summary ADD COLUMN judged_at REAL") }
        // Stores from before a cursor carried what its bucket set aside or the bad-dated items already recorded.
        let cursorColumns = Set(try db.query("PRAGMA table_info(bucket_cursor)").compactMap { $0["name"].text })
        if !cursorColumns.contains("set_aside") { try db.exec("ALTER TABLE bucket_cursor ADD COLUMN set_aside INTEGER NOT NULL DEFAULT 0") }
        if !cursorColumns.contains("gated") { try db.exec("ALTER TABLE bucket_cursor ADD COLUMN gated TEXT") }
        // Once, for the sources whose first read became window-bound: a root walked part-way under the old build,
        // which listed everything, has a floor older than anything the new window will list, so its resume would
        // find nothing below the floor for good. Collapsing the floor into the mark lets it go on incrementally.
        // A floor a later run of this build leaves behind is not touched: the key keeps this to one opening.
        if try db.query("SELECT 1 FROM setting WHERE key=?", [.text(Self.floorsCollapsedKey)]).isEmpty {
            try db.run("UPDATE bucket_cursor SET floor_order=NULL, floor_tiebreak=NULL WHERE mark_order IS NOT NULL AND floor_order IS NOT NULL AND source_id IN ('files','notes','voicememos','recordings')")
            try db.run("INSERT INTO setting(key,value) VALUES(?,?)", [.text(Self.floorsCollapsedKey), .text("1")])
        }
    }
    static let floorsCollapsedKey = "store.windowFloorsCollapsed"

    /// The id a note cites for one item: twelve hex digits of an FNV-1a fold over source, bucket, kind
    /// and item key, so the same item always gets the same id and two runs never disagree.
    public static func stableID(_ c: Candidate) -> String {
        let key = "\(c.source.rawValue)|\(c.bucket.rawValue)|\(c.kind.rawValue)|\(c.key.order)|\(c.key.tiebreak)"
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in key.utf8 { h1 = (h1 ^ UInt64(b)) &* 0x100000001b3; h2 = (h2 &+ UInt64(b)) &* 0x100000001b3 }
        return String(String(format: "%016llx%016llx", h1 ^ (h2 >> 7), h2).prefix(12))
    }

    // MARK: runs

    public func beginRun(trigger: RunTrigger, at: Date) throws -> Int64 {
        try db.run("INSERT INTO run(trigger, started_at) VALUES(?,?)", [.text(trigger.rawValue), .init(at)])
    }

    public func endRun(_ id: Int64, outcome: RunOutcome, stats: RunStats, at: Date) throws {
        let o = String(data: try JSONEncoder().encode(outcome), encoding: .utf8)!
        let s = String(data: try JSONEncoder().encode(stats), encoding: .utf8)!
        try db.run("UPDATE run SET ended_at=?, outcome=?, stats=? WHERE id=?", [.init(at), .text(o), .text(s), .int(id)])
    }

    public func recentRuns(limit: Int) throws -> [RunRecord] {
        try db.query("SELECT * FROM run ORDER BY started_at DESC LIMIT ?", [.init(limit)]).map(Self.runRecord)
    }

    public func lastRun() throws -> RunRecord? { try recentRuns(limit: 1).first }

    private static func runRecord(_ r: SQLite.Row) -> RunRecord {
        let dec = JSONDecoder()
        let outcome = r["outcome"].text.flatMap { try? dec.decode(RunOutcome.self, from: Data($0.utf8)) }
        let stats = r["stats"].text.flatMap { try? dec.decode(RunStats.self, from: Data($0.utf8)) } ?? RunStats()
        return RunRecord(id: r["id"].int ?? 0, trigger: RunTrigger(rawValue: r["trigger"].text ?? "") ?? .manual,
                         startedAt: r["started_at"].date ?? Date(), endedAt: r["ended_at"].date, outcome: outcome, stats: stats)
    }

    // MARK: cursors

    public func cursor(_ bucket: BucketID) throws -> BucketCursor? {
        try db.query("SELECT * FROM bucket_cursor WHERE bucket_id=?", [.text(bucket.rawValue)]).first.map(Self.cursorRecord)
    }

    public func cursors(for source: SourceID) throws -> [BucketCursor] {
        try db.query("SELECT * FROM bucket_cursor WHERE source_id=?", [.text(source.rawValue)]).map(Self.cursorRecord)
    }

    private static func cursorRecord(_ r: SQLite.Row) -> BucketCursor {
        let mark = r["mark_order"].real.map { ItemKey(order: $0, tiebreak: r["mark_tiebreak"].text ?? "") }
        let floor = r["floor_order"].real.map { ItemKey(order: $0, tiebreak: r["floor_tiebreak"].text ?? "") }
        let gated = r["gated"].text.flatMap { try? JSONDecoder().decode([ItemKey].self, from: Data($0.utf8)) } ?? []
        return BucketCursor(bucket: BucketID(r["bucket_id"].text ?? ""), source: SourceID(r["source_id"].text ?? ""), mark: mark, floor: floor,
                            setAside: Int(r["set_aside"].int ?? 0), gated: gated)
    }

    /// The cursor row as one upsert, shared by the atomic commit and the cursor-only write.
    private func upsertCursor(_ cursor: BucketCursor, at: Date) throws {
        let gated = cursor.gated.isEmpty ? nil : (try? JSONEncoder().encode(cursor.gated)).flatMap { String(data: $0, encoding: .utf8) }
        try db.run("""
        INSERT INTO bucket_cursor(bucket_id, source_id, mark_order, mark_tiebreak, floor_order, floor_tiebreak, updated_at, set_aside, gated)
        VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(bucket_id) DO UPDATE SET source_id=excluded.source_id, mark_order=excluded.mark_order,
          mark_tiebreak=excluded.mark_tiebreak, floor_order=excluded.floor_order, floor_tiebreak=excluded.floor_tiebreak,
          updated_at=excluded.updated_at, set_aside=excluded.set_aside, gated=excluded.gated
        """, [.text(cursor.bucket.rawValue), .text(cursor.source.rawValue),
              cursor.mark.map { .real($0.order) } ?? .null, .init(cursor.mark?.tiebreak),
              cursor.floor.map { .real($0.order) } ?? .null, .init(cursor.floor?.tiebreak), .init(at), .init(cursor.setAside), .init(gated)])
    }

    public func setCursor(_ cursor: BucketCursor, at: Date) throws { try upsertCursor(cursor, at: at) }

    /// The atomic commit. See `03-ingest.md`.
    public func commit(runID: Int64, cursor: BucketCursor, bucketName: String, candidate: Candidate, outcome: Outcome, at: Date) throws {
        try db.transaction {
            if let s = outcome.survivor {
                try db.run("""
                INSERT INTO summary(run_id, source_id, bucket_id, bucket_name, kind, title, text, item_date, created_at, sid)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [.int(runID), .text(candidate.source.rawValue), .text(candidate.bucket.rawValue), .text(bucketName),
                      .text(candidate.kind.rawValue), .text(s.title), .text(s.summary), .init(candidate.itemDate), .init(at), .text(Self.stableID(candidate))])
            } else if outcome.reason != .kept {
                // Reason only — never content. Sensitive rows carry nothing but the fact.
                try db.run("INSERT INTO drop_log(run_id, source_id, bucket_name, reason, at) VALUES(?,?,?,?,?)",
                           [.int(runID), .text(candidate.source.rawValue), .text(bucketName), .text(outcome.reason.rawValue), .init(at)])
            }
            try upsertCursor(cursor, at: at)
        }
    }

    public func clearBucket(_ bucket: BucketID) throws {
        try db.run("DELETE FROM bucket_cursor WHERE bucket_id=?", [.text(bucket.rawValue)])
    }

    public func resetCursors(for source: SourceID) throws {
        try db.run("DELETE FROM bucket_cursor WHERE source_id=?", [.text(source.rawValue)])
    }

    // MARK: summaries

    public func summaries(since: Date?) throws -> [SummaryRecord] {
        let rows = since == nil
            ? try db.query("SELECT * FROM summary ORDER BY created_at DESC")
            : try db.query("SELECT * FROM summary WHERE COALESCE(item_date, created_at) >= ? ORDER BY created_at DESC", [.init(since)])
        return rows.map(Self.summaryRecord)
    }

    /// Oldest first, so the notes are told about things in the order they happened.
    public func unmergedSummaries() throws -> [SummaryRecord] {
        try db.query("SELECT * FROM summary WHERE merged_at IS NULL ORDER BY COALESCE(item_date, created_at) ASC, id ASC").map(Self.summaryRecord)
    }

    public func markMerged(ids: [Int64], at: Date) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            // SQLite caps bound parameters, so long lists go in slices.
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.run("UPDATE summary SET merged_at=? WHERE id IN (\(marks))", [.init(at)] + chunk.map { .int($0) })
            }
        }
    }

    /// Judged rows are stamped, never deleted on the night: what merged more than `keepFor` ago goes, in the same transaction.
    public func retireMerged(now: Date, keepFor: TimeInterval) throws {
        try db.transaction {
            try db.run("UPDATE summary SET judged_at=? WHERE merged_at IS NOT NULL AND judged_at IS NULL", [.init(now)])
            try deleteJudged(mergedBefore: now.addingTimeInterval(-keepFor))
        }
    }
    /// Only a row the judge has seen is evidence that can age out; one merged but never judged is still owed a judgement.
    private func deleteJudged(mergedBefore cutoff: Date) throws {
        try db.run("DELETE FROM summary WHERE judged_at IS NOT NULL AND merged_at < ?", [.real(cutoff.timeIntervalSince1970)])
    }

    public func wipeSummaries() throws { try db.run("DELETE FROM summary") }

    private static func summaryRecord(_ r: SQLite.Row) -> SummaryRecord {
        SummaryRecord(id: r["id"].int ?? 0, runID: r["run_id"].int ?? 0, source: SourceID(r["source_id"].text ?? ""),
                      bucket: BucketID(r["bucket_id"].text ?? ""), bucketName: r["bucket_name"].text ?? "",
                      kind: SourceKind(rawValue: r["kind"].text ?? "") ?? .document, title: r["title"].text ?? "",
                      text: r["text"].text ?? "", itemDate: r["item_date"].date, createdAt: r["created_at"].date ?? Date(),
                      sid: r["sid"].text, mergedAt: r["merged_at"].date, judgedAt: r["judged_at"].date)
    }

    // MARK: drops

    public func drops(since: Date) throws -> [DropRecord] {
        try db.query("SELECT * FROM drop_log WHERE at >= ? ORDER BY at DESC", [.init(since)]).map { r in
            DropRecord(id: r["id"].int ?? 0, runID: r["run_id"].int ?? 0, source: SourceID(r["source_id"].text ?? ""),
                       bucketName: r["bucket_name"].text ?? "", reason: VerdictReason(rawValue: r["reason"].text ?? "") ?? .modelDrop,
                       at: r["at"].date ?? Date())
        }
    }

    // MARK: what left the Mac

    public func logSend(purpose: String, model: String, bytes: Int, detail: String, cameBack: String, payload: String, at: Date) throws -> Int64 {
        try db.run("INSERT INTO send_log(at,purpose,model,bytes,detail,came_back,payload) VALUES(?,?,?,?,?,?,?)",
                   [.init(at), .text(purpose), .text(model), .init(bytes), .text(detail), .text(cameBack), .text(payload)])
    }
    public func setSendResult(_ id: Int64, cameBack: String) throws {
        try db.run("UPDATE send_log SET came_back=? WHERE id=?", [.text(cameBack), .int(id)])
    }
    public func sendLog(since: Date) throws -> [SendRecord] {
        try db.query("SELECT * FROM send_log WHERE at >= ? ORDER BY at DESC LIMIT 500", [.init(since)]).map { r in
            SendRecord(id: r["id"].int ?? 0, at: r["at"].date ?? Date(), purpose: r["purpose"].text ?? "", model: r["model"].text ?? "",
                       bytes: Int(r["bytes"].int ?? 0), detail: r["detail"].text ?? "", cameBack: r["came_back"].text ?? "", payload: r["payload"].text ?? "")
        }
    }

    // MARK: settings

    public func value(_ key: String) throws -> String? {
        try db.query("SELECT value FROM setting WHERE key=?", [.text(key)]).first?["value"].text
    }

    public func setValue(_ key: String, _ value: String?) throws {
        if let value { try db.run("INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }
        else { try db.run("DELETE FROM setting WHERE key=?", [.text(key)]) }
    }

    public func keys(withPrefix prefix: String) throws -> [String] {
        try db.query("SELECT key FROM setting WHERE substr(key, 1, ?) = ? ORDER BY key", [.init(prefix.count), .text(prefix)]).compactMap { $0["key"].text }
    }

    // MARK: reset

    /// Retention: drop log and run rows older than 90 days, the send log and judged summaries older than 30, and Sunday
    /// letters older than 26 weeks (the week's key is its ISO week; the pointer keys beside them are not dated and stay).
    /// The vault health history trims itself as it is appended, so it is not touched here.
    public func prune(now: Date) throws { try prune(now: now, olderThan: 90) }
    public func prune(now: Date, olderThan days: Int) throws {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        try db.run("DELETE FROM drop_log WHERE at < ?", [.real(cutoff)])
        try db.run("DELETE FROM run WHERE started_at < ?", [.real(cutoff)])
        try db.run("DELETE FROM send_log WHERE at < ?", [.real(now.addingTimeInterval(-30 * 86400).timeIntervalSince1970)])
        try deleteJudged(mergedBefore: now.addingTimeInterval(-SummaryRecord.evidenceWindow))
        for key in try keys(withPrefix: "proactive.weekly.") where Self.weekIsOlder(key, than: Self.weeklyKeep, at: now) { try setValue(key, nil) }
    }
    static let weeklyKeep = 26

    /// "proactive.weekly.2026-W12" → whether that ISO week began more than `weeks` weeks before `now`. A key that is not
    /// a week (".latest", ".seen") is never older.
    static func weekIsOlder(_ key: String, than weeks: Int, at now: Date) -> Bool {
        let tail = key.split(separator: ".").last.map(String.init) ?? ""
        let parts = tail.split(separator: "-W")
        guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1]), tail.count == 8 else { return false }
        let cal = Calendar(identifier: .iso8601)
        guard let start = cal.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) else { return false }
        return start < now.addingTimeInterval(-Double(weeks) * 7 * 86400)
    }

    public func factoryReset() throws {
        try db.transaction {
            try db.exec("DELETE FROM summary; DELETE FROM bucket_cursor; DELETE FROM drop_log; DELETE FROM run; DELETE FROM send_log;")
            try db.exec("DELETE FROM setting WHERE key LIKE 'walkthrough.%' OR key LIKE 'proactive.%' OR key LIKE 'knowledge.%' OR key LIKE 'hands.recipes%' OR key='app.onboardingDone'")
        }
        log.info("factory reset")
    }
}
