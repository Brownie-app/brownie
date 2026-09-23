import Foundation
import os

/// The one logger. Subsystem-scoped categories; everything also lands in
/// `~/Library/Logs/Brownie/<category>.log` when file logging is enabled (flushed per line — the
/// black box for diagnosing an empty morning).
public struct Log: Sendable {
    public let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        self.logger = Logger(subsystem: "app.brownie", category: category)
    }

    public func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    public func warn(_ message: @autoclosure () -> String) { emit(.error, message()) }
    public func error(_ message: @autoclosure () -> String) { emit(.fault, message()) }
    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }

    private func emit(_ level: OSLogType, _ message: String) {
        logger.log(level: level, "\(message, privacy: .public)")
        FileLog.shared.write(category: category, level: level, message: message)
    }

    /// Rotation for the app's own log folder: every `<category>.log` over `maxBytes` becomes `.log.1`, the older copies
    /// shift up, and copies past `keep` are deleted. Returns the categories rotated. Called nightly at FINISH.
    @discardableResult
    public static func rotate(maxBytes: Int = 5 * 1024 * 1024, keep: Int = 2) -> [String] {
        FileLog.shared.rotate(maxBytes: maxBytes, keep: keep)
    }

    /// The same rotation over any folder — the pure file work, for tests and for folders the app does not write to.
    @discardableResult
    public static func rotate(in directory: URL, maxBytes: Int, keep: Int) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var rotated: [String] = []
        for name in names.sorted() where name.hasSuffix(".log") {
            let url = directory.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size > maxBytes else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent("\(name).\(keep)"))
            for i in stride(from: keep - 1, through: 1, by: -1) {
                let old = directory.appendingPathComponent("\(name).\(i)")
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: directory.appendingPathComponent("\(name).\(i + 1)")) }
            }
            if keep >= 1 { try? fm.moveItem(at: url, to: directory.appendingPathComponent("\(name).1")) } else { try? fm.removeItem(at: url) }
            rotated.append(String(name.dropLast(4)))
        }
        return rotated
    }
}

/// Per-category rolling text logs. Never receives content (summaries, messages) — callers log
/// counts, ids, reasons and timings only.
public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog()
    private let queue = DispatchQueue(label: "app.brownie.filelog")
    private var handles: [String: FileHandle] = [:]
    private let directory: URL
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Brownie", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var directoryURL: URL { directory }

    /// Rotates on the writer's own queue with every handle closed first, so the next line opens a fresh file rather
    /// than following the renamed one.
    fileprivate func rotate(maxBytes: Int, keep: Int) -> [String] {
        queue.sync {
            for h in handles.values { try? h.close() }
            handles.removeAll()
            return Log.rotate(in: directory, maxBytes: maxBytes, keep: keep)
        }
    }

    fileprivate func write(category: String, level: OSLogType, message: String) {
        queue.async {
            let line = "\(self.formatter.string(from: Date())) [\(self.label(level))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let handle = self.handles[category] ?? self.open(category)
            handle?.write(data)
        }
    }

    private func open(_ category: String) -> FileHandle? {
        let url = directory.appendingPathComponent("\(category).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        handles[category] = h
        return h
    }

    private func label(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .error: return "warn"
        case .fault: return "error"
        default: return "log"
        }
    }
}
