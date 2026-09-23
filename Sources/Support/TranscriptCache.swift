import Foundation

/// The transcripts folder: one JSON per recording already read, kept so a recording is transcribed once. A transcript
/// nobody has asked for in `keepDays` is deleted at FINISH; a recording read that far back is behind its bucket's mark,
/// and one read again after "Read further back" is simply transcribed again.
public enum TranscriptCache {
    public static let keepDays = 180

    /// Deletes cache files whose modification date is older than `keepDays` before `now`; returns how many went.
    @discardableResult
    public static func prune(in directory: URL = Paths.transcripts, now: Date, keepDays: Int = keepDays) -> Int {
        let fm = FileManager.default
        let floor = now.addingTimeInterval(-Double(keepDays) * 86400)
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var gone = 0
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mtime < floor else { continue }
            if (try? fm.removeItem(at: url)) != nil { gone += 1 }
        }
        return gone
    }
}
