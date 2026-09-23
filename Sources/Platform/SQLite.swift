import Foundation
import CSQLite

/// A thin, safe wrapper over sqlite3. One connection, serialised by the owning actor.
public final class SQLite: @unchecked Sendable {
    public enum Value: Sendable, Equatable {
        case null, int(Int64), real(Double), text(String), blob(Data)
        public var int: Int64? { if case .int(let v) = self { return v }; return nil }
        public var real: Double? { if case .real(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
        public var text: String? { if case .text(let v) = self { return v }; return nil }
        public var blob: Data? { if case .blob(let v) = self { return v }; return nil }
    }
    public struct Row: Sendable {
        public let columns: [String: Value]
        public subscript(_ name: String) -> Value { columns[name] ?? .null }
    }
    public struct Error: Swift.Error, CustomStringConvertible { public let code: Int32; public let message: String; public var description: String { "sqlite \(code): \(message)" } }

    private var db: OpaquePointer?

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h = handle { sqlite3_close(h) }
            throw Error(code: rc, message: msg)
        }
        db = h
        if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;") }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"; sqlite3_free(err)
            throw Error(code: rc, message: msg)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Error(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        return sqlite3_last_insert_rowid(db)
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let count = sqlite3_column_count(stmt)
        let names = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var cols: [String: Value] = [:]
                for i in 0..<count {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: cols[names[Int(i)]] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: cols[names[Int(i)]] = .real(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: cols[names[Int(i)]] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, i))
                        cols[names[Int(i)]] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: n) : Data())
                    default: cols[names[Int(i)]] = .null
                    }
                }
                rows.append(Row(columns: cols))
            } else if rc == SQLITE_DONE { break }
            else { throw Error(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let v = try body(); try exec("COMMIT"); return v }
        catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else { throw Error(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(s, idx)
            case .int(let v): sqlite3_bind_int64(s, idx, v)
            case .real(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(v.count), transient) }
            }
        }
        return s
    }
}

public extension SQLite.Value {
    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ d: Date?) { self = d.map { .real($0.timeIntervalSince1970) } ?? .null }
    init(_ i: Int) { self = .int(Int64(i)) }
    var date: Date? { real.map { Date(timeIntervalSince1970: $0) } }
}
