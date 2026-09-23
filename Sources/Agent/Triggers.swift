import Foundation
import Domain
import Support

/// Shell-style file matching for trigger recipes: `*` any run, `?` one character, case-insensitive.
public enum Glob {
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] { pi += 1; ni += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ni; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Watches a folder for new files that match a pattern. Pure decision (`newFiles`) + a small
/// DispatchSource wrapper; the app runs the recipe with `file` filled in.
public final class FolderWatcher: @unchecked Sendable {
    public struct Seen: Sendable, Equatable { public let path: String; public let modified: Date }
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var known: Set<String> = []
    private let queue = DispatchQueue(label: "brownie.trigger")   // one scan at a time, so a file fires once
    private var pending: DispatchWorkItem?
    private let log = Log("trigger")

    public init() {}

    /// Files in `folder` matching `pattern` that are not in `known` and are at least `settle` seconds old
    /// (so a download still being written is not picked up mid-way). Hidden files never count.
    public static func newFiles(in folder: URL, pattern: String, known: Set<String>, now: Date = Date(), settle: TimeInterval = 3) -> [Seen] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { u -> Seen? in
            let name = u.lastPathComponent
            let path = u.resolvingSymlinksInPath().path   // /var and /private/var are the same place
            guard !known.contains(path), !known.contains(u.path), Glob.matches(pattern, name), !name.hasSuffix(".download"), !name.hasSuffix(".crdownload"), !name.hasSuffix(".part") else { return nil }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let m = v?.contentModificationDate, now.timeIntervalSince(m) >= settle else { return nil }
            return Seen(path: path, modified: m)
        }.sorted { $0.modified < $1.modified }
    }

    /// Starts watching. Existing files are remembered, not fired, so turning a trigger on doesn't replay history.
    public func start(_ folder: URL, pattern: String, onFile: @escaping @Sendable (Seen) -> Void) {
        stop()
        known = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appendingPathComponent($0).resolvingSymlinksInPath().path })
        fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { log.warn("can't watch \(folder.path)"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // A download raises several events; coalesce them and give the file a moment to finish landing.
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                for f in Self.newFiles(in: folder, pattern: pattern, known: self.known) { self.known.insert(f.path); self.log.info("new file \(f.path)"); onFile(f) }
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 3.5, execute: work)
        }
        src.setCancelHandler { [fd = self.fd] in close(fd) }
        src.resume(); source = src
        log.info("watching \(folder.path) for \(pattern)")
    }
    public func stop() { source?.cancel(); source = nil; fd = -1 }
    deinit { stop() }
}
