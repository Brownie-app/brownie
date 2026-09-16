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
            mark_order REAL, mark_tiebreak TEXT, floor_order REAL, floor_tiebreak TEXT, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS summary(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, source_id TEXT NOT NULL,
            bucket_id TEXT NOT NULL, bucket_name TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
            item_date REAL, created_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS summary_created ON summary(created_at);
        CREATE TABLE IF NOT EXISTS drop_log(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, source_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL, reason TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS drop_at ON drop_log(at);
        CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS send_log(id INTEGER PRIMARY KEY, at REAL NOT NULL, purpose TEXT NOT NULL, model TEXT NOT NULL,
            bytes INTEGER NOT NULL, detail TEXT NOT NULL, came_back TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS send_at ON send_log(at);
        """)
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
        return BucketCursor(bucket: BucketID(r["bucket_id"].text ?? ""), source: SourceID(r["source_id"].text ?? ""), mark: mark, floor: floor)
    }

    /// The atomic commit. See `03-ingest.md`.
    public func commit(runID: Int64, cursor: BucketCursor, bucketName: String, candidate: Candidate, outcome: Outcome, at: Date) throws {
        try db.transaction {
            if let s = outcome.survivor {
                try db.run("""
                INSERT INTO summary(run_id, source_id, bucket_id, bucket_name, kind, title, text, item_date, created_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [.int(runID), .text(candidate.source.rawValue), .text(candidate.bucket.rawValue), .text(bucketName),
                      .text(candidate.kind.rawValue), .text(s.title), .text(s.summary), .init(candidate.itemDate), .init(at)])
            } else if outcome.reason != .kept {
                // Reason only — never content. Sensitive rows carry nothing but the fact.
                try db.run("INSERT INTO drop_log(run_id, source_id, bucket_name, reason, at) VALUES(?,?,?,?,?)",
                           [.int(runID), .text(candidate.source.rawValue), .text(bucketName), .text(outcome.reason.rawValue), .init(at)])
            }
            try db.run("""
            INSERT INTO bucket_cursor(bucket_id, source_id, mark_order, mark_tiebreak, floor_order, floor_tiebreak, updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(bucket_id) DO UPDATE SET source_id=excluded.source_id, mark_order=excluded.mark_order,
              mark_tiebreak=excluded.mark_tiebreak, floor_order=excluded.floor_order, floor_tiebreak=excluded.floor_tiebreak,
              updated_at=excluded.updated_at
            """, [.text(cursor.bucket.rawValue), .text(cursor.source.rawValue),
                  cursor.mark.map { .real($0.order) } ?? .null, .init(cursor.mark?.tiebreak),
                  cursor.floor.map { .real($0.order) } ?? .null, .init(cursor.floor?.tiebreak), .init(at)])
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
        return rows.map { r in
            SummaryRecord(id: r["id"].int ?? 0, runID: r["run_id"].int ?? 0, source: SourceID(r["source_id"].text ?? ""),
                          bucket: BucketID(r["bucket_id"].text ?? ""), bucketName: r["bucket_name"].text ?? "",
                          kind: SourceKind(rawValue: r["kind"].text ?? "") ?? .document, title: r["title"].text ?? "",
                          text: r["text"].text ?? "", itemDate: r["item_date"].date, createdAt: r["created_at"].date ?? Date())
        }
    }

    public func wipeSummaries() throws { try db.run("DELETE FROM summary") }

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

    // MARK: reset

    /// Retention: drop log and run rows older than 90 days.
    public func prune(olderThan days: Int = 90) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        try db.run("DELETE FROM drop_log WHERE at < ?", [.real(cutoff)])
        try db.run("DELETE FROM run WHERE started_at < ?", [.real(cutoff)])
        try db.run("DELETE FROM send_log WHERE at < ?", [.real(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)])
    }

    public func factoryReset() throws {
        try db.transaction {
            try db.exec("DELETE FROM summary; DELETE FROM bucket_cursor; DELETE FROM drop_log; DELETE FROM run; DELETE FROM send_log;")
            try db.exec("DELETE FROM setting WHERE key LIKE 'walkthrough.%' OR key LIKE 'proactive.%' OR key LIKE 'knowledge.%' OR key LIKE 'hands.recipes%' OR key='app.onboardingDone'")
        }
        log.info("factory reset")
    }
}
