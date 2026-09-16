import Foundation

/// What Brownie has actually read from one source, so the user can see "how far back" instead of
/// guessing. Written by the read loop after every run and merged across runs: the date range only widens,
/// the item count only grows, and `notRead` is the run's whole word on what lies below what was read — the
/// read loop carries each bucket's set-aside count on its cursor, so a cap that held back history keeps
/// counting on the quiet nights after it, until "Read further back" reads it or the source starts over.
public struct SourceCoverage: Codable, Sendable, Equatable {
    public var source: SourceID
    public var oldestRead: Date?
    public var newestRead: Date?
    public var itemsRead: Int
    public var notRead: Int
    public var lastRun: Date
    /// Chats, folders or mailboxes this run touched. Zero when the source has no such split.
    public var buckets: Int

    public init(source: SourceID, oldestRead: Date?, newestRead: Date?, itemsRead: Int, notRead: Int, lastRun: Date, buckets: Int = 0) {
        self.source = source; self.oldestRead = oldestRead; self.newestRead = newestRead
        self.itemsRead = itemsRead; self.notRead = notRead; self.lastRun = lastRun; self.buckets = buckets
    }

    /// One run's figures folded into what was known: the range widens, the count accumulates, and the
    /// leftover and the last run are simply the newest word on the matter.
    public static func merge(_ known: SourceCoverage?, with fresh: SourceCoverage) -> SourceCoverage {
        guard let known, known.source == fresh.source else { return fresh }
        var m = fresh
        m.oldestRead = [known.oldestRead, fresh.oldestRead].compactMap { $0 }.min()
        m.newestRead = [known.newestRead, fresh.newestRead].compactMap { $0 }.max()
        m.itemsRead = known.itemsRead + fresh.itemsRead
        m.buckets = fresh.buckets > 0 ? fresh.buckets : known.buckets
        return m
    }

    /// The list without one source: its cursors were reset, so the next run establishes its figures afresh
    /// instead of adding a second read of the same items to the count.
    public static func forgetting(_ source: SourceID, in all: [SourceCoverage]) -> [SourceCoverage] { all.filter { $0.source != source } }

    /// The whole list with one source's fresh figures merged in, order kept.
    public static func merge(_ all: [SourceCoverage], with fresh: SourceCoverage) -> [SourceCoverage] {
        var out = all
        if let i = out.firstIndex(where: { $0.source == fresh.source }) { out[i] = merge(out[i], with: fresh) } else { out.append(fresh) }
        return out
    }

    public static func decode(_ json: String?) -> [SourceCoverage] {
        guard let json, let d = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SourceCoverage].self, from: d)) ?? []
    }
    public static func encode(_ all: [SourceCoverage]) -> String? {
        (try? JSONEncoder().encode(all)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The sentence Settings and the README show for each source:
/// "WhatsApp: 6 chats · read back to 14 Jun 2026 · 1,240 messages · older not read".
public enum CoverageLine {
    public static func render(_ all: [SourceCoverage], timeZone: TimeZone = .current) -> String {
        guard !all.isEmpty else { return "Nothing read yet." }
        return all.map { render($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    public static func render(_ c: SourceCoverage, timeZone: TimeZone = .current) -> String {
        let words = nouns(c.source)
        var parts: [String] = []
        if c.buckets > 0, let unit = words.bucket { parts.append("\(count(c.buckets)) \(unit)") }
        if let oldest = c.oldestRead { parts.append("read back to \(day(oldest, timeZone))") }
        parts.append("\(count(c.itemsRead)) \(words.item)")
        parts.append(c.notRead > 0 ? "older not read" : "everything read")
        return "\(name(c.source)): " + parts.joined(separator: " · ")
    }

    static func name(_ s: SourceID) -> String {
        switch s.rawValue {
        case "whatsapp": return "WhatsApp"; case "imessage": return "iMessage"; case "telegram": return "Telegram"
        case "slack": return "Slack"; case "teams": return "Microsoft Teams"; case "gmail": return "Gmail"
        case "files": return "Files"; case "notes": return "Apple Notes"; case "voicememos": return "Voice Memos"
        case "recordings": return "Meeting audio"; case "calendar": return "Calendar"
        default: return s.rawValue.split(separator: ":").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? s.rawValue
        }
    }
    static func nouns(_ s: SourceID) -> (bucket: String?, item: String) {
        switch s.rawValue {
        case "whatsapp", "imessage", "telegram", "slack", "teams": return ("chats", "messages")
        case "gmail": return ("mailboxes", "emails")
        case "files": return ("folders", "files")
        case "notes": return (nil, "notes")
        case "voicememos", "recordings": return (nil, "recordings")
        case "calendar": return (nil, "events")
        default: return (nil, "items")
        }
    }
    static func count(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US_POSIX"); f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
    static func day(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}
