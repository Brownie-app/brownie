import Foundation
import Domain
import Support

/// Resumable download into Application Support. Progress is published; a partial file resumes
/// with a Range request; the final file is moved into place only when the size matches.
public actor ModelDownload {
    public struct Progress: Sendable, Equatable { public let received: Int64; public let total: Int64; public var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 } }
    public enum State: Sendable, Equatable { case idle, downloading(Progress), verifying, done(URL), failed(String) }

    private let info: LocalModelInfo
    private let log = Log("model.download")
    private var task: Task<Void, Never>?
    public private(set) var state: State = .idle
    private var observers: [UUID: @Sendable (State) -> Void] = [:]

    public init(info: LocalModelInfo) { self.info = info }

    public func observe(_ f: @escaping @Sendable (State) -> Void) -> UUID { let id = UUID(); observers[id] = f; f(state); return id }
    public func unobserve(_ id: UUID) { observers[id] = nil }
    private func set(_ s: State) { state = s; for o in observers.values { o(s) } }

    public var destination: URL { Paths.models.appendingPathComponent(info.fileName) }
    private var partial: URL { Paths.models.appendingPathComponent(info.fileName + ".part") }

    public func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    public func cancel() { task?.cancel(); task = nil; set(.idle) }

    private func run() async {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { set(.done(destination)); task = nil; return }
        let existing = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: info.downloadURL)
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200...206).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let resuming = http.statusCode == 206
            if !resuming, existing > 0 { try? fm.removeItem(at: partial) }
            if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            let total = (resuming ? existing : 0) + http.expectedContentLength
            var received = resuming ? existing : 0
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            var lastReport = Date.distantPast
            for try await b in bytes {
                buffer.append(b)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.5 { set(.downloading(Progress(received: received, total: total))); lastReport = Date() }
                }
                if Task.isCancelled { try handle.close(); return }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
            try handle.close()
            set(.verifying)
            let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
            guard total <= 0 || size == total else { throw URLError(.cannotDecodeContentData) }
            try fm.moveItem(at: partial, to: destination)
            log.info("downloaded \(info.fileName) \(size) bytes")
            set(.done(destination))
        } catch {
            log.warn("download failed: \(error)")
            set(.failed(error.localizedDescription))
        }
        task = nil
    }

    public static func freeDiskBytes() -> Int64 {
        (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
}
