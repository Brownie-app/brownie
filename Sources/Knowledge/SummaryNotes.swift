import Foundation
import Domain

/// What a night writes when there is no brain.
///
/// Three screens used to promise that Brownie "reads and keeps notes" without one, and all three were wrong:
/// every note in the vault is written by `KnowledgeBuilder`, which the run only reaches `if let brain`. So a
/// keyless Mac read a hundred things and wrote nothing, and the Knowledge screen said notes appear "after the
/// first run with a brain" — the one honest sentence in the app, contradicting the other three.
///
/// This is the deterministic half: one note per day, the reader's own words grouped by where they came from,
/// with the questions people are still waiting on at the top. No model decides anything here. It is additive —
/// the summaries behind it stay unmerged, so a brain added in week two still builds proper notes out of
/// everything read in week one.
public enum SummaryNotes {
    /// Where a day's note lives. Its own folder, so the gardener and the archive can treat the reader's raw
    /// output differently from the notes a brain curated.
    public static let folder = "Read"
    public static func path(for day: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "\(folder)/\(f.string(from: day)).md"
    }

    /// The day a summary belongs to: when the thing itself happened, or failing that when it was read.
    public static func day(of s: SummaryRecord, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: s.itemDate ?? s.createdAt)
    }

    /// One day's note, or nil when the day kept nothing worth writing down. Bullets end in `(YYYY-MM-DD)`
    /// because that is the shape `NoteSkeleton` and `NoteLint` expect of every line in the vault.
    public static func render(summaries: [SummaryRecord], asks: [Ask] = [], day: Date,
                              calendar: Calendar = .current) -> String? {
        let kept = summaries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let open = asks.filter(\.isOpen).sorted { $0.askedAt < $1.askedAt }
        guard !kept.isEmpty || !open.isEmpty else { return nil }

        let heading = DateFormatter(); heading.calendar = calendar; heading.timeZone = calendar.timeZone
        heading.locale = Locale(identifier: "en_US_POSIX"); heading.dateFormat = "EEEE d MMMM"
        let stamp = DateFormatter(); stamp.calendar = calendar; stamp.timeZone = calendar.timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd"

        var out = "# Read on \(heading.string(from: day))\n\n"
        out += "Brownie read \(kept.count) thing\(kept.count == 1 ? "" : "s") on this day. No brain is set up, so "
        out += "nothing here has been judged or drafted — these are the reader's own words, written on this Mac.\n"

        if !open.isEmpty {
            out += "\n## Waiting on you\n"
            for a in open {
                out += "- **\(a.person)** asked: \(line(a.question)) — \(a.answeredAt == nil ? "no reply from you yet" : "you wrote back, but not about this") (\(stamp.string(from: a.askedAt)))\n"
            }
        }

        // Grouped by where it came from, in the order the sources were read, so the note reads like the night did.
        var seen: [String] = []
        var byGroup: [String: [SummaryRecord]] = [:]
        for s in kept {
            let g = group(s)
            if byGroup[g] == nil { seen.append(g) }
            byGroup[g, default: []].append(s)
        }
        for g in seen {
            out += "\n## \(g)\n"
            for s in byGroup[g]!.sorted(by: { ($0.itemDate ?? $0.createdAt) < ($1.itemDate ?? $1.createdAt) }) {
                let when = stamp.string(from: s.itemDate ?? s.createdAt)
                let title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "- " + (title.isEmpty ? "" : "**\(title)** — ") + line(s.text) + " (\(when)) \(marker)\(s.id) -->\n"
            }
        }
        out += "\n---\nWritten on this Mac by the reader. Nothing left your Mac.\n"
        return out
    }

    /// Marks which summary a bullet came from, so a second run on the same day adds only what is new.
    static let marker = "<!-- read:"

    /// The summary ids a note already holds.
    public static func held(in markdown: String) -> Set<Int64> {
        var out = Set<Int64>()
        for raw in markdown.split(separator: "\n") {
            guard let open = raw.range(of: marker), let close = raw[open.upperBound...].range(of: "-->") else { continue }
            if let n = Int64(raw[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)) { out.insert(n) }
        }
        return out
    }

    /// A day read twice adds only what the note does not already hold, and never repeats a bullet. A note the
    /// user has edited by hand is left alone entirely — their words are not ours to rewrite.
    public static func merge(summaries: [SummaryRecord], asks: [Ask] = [], day: Date,
                             into existing: String?, calendar: Calendar = .current) -> String? {
        guard let existing, !existing.isEmpty else {
            return render(summaries: summaries, asks: asks, day: day, calendar: calendar)
        }
        let already = held(in: existing)
        let fresh = summaries.filter { !already.contains($0.id) }
        guard !fresh.isEmpty else { return nil }   // nothing new: do not touch the file at all
        guard let addition = render(summaries: fresh, asks: asks, day: day, calendar: calendar) else { return nil }
        // Keep what is there; append only the new groups, without a second heading or a second footer.
        let body = addition
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop { !$0.hasPrefix("## ") }
            .prefix { !$0.hasPrefix("---") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let trimmed = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("---") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + "\n\n" + body + "\n\n---\nWritten on this Mac by the reader. Nothing left your Mac.\n"
    }

    /// "WhatsApp · Tanvi Rege", "Files · Desktop" — the app and the chat or folder it came from.
    static func group(_ s: SummaryRecord) -> String {
        let app = appName(s.source)
        let bucket = s.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        return bucket.isEmpty ? app : "\(app) · \(bucket)"
    }

    static func appName(_ s: SourceID) -> String {
        switch s.rawValue {
        case "whatsapp": return "WhatsApp"; case "imessage": return "Messages"; case "telegram": return "Telegram"
        case "slack": return "Slack"; case "teams": return "Teams"; case "gmail": return "Gmail"
        case "files": return "Files"; case "notes": return "Notes"; case "calendar": return "Calendar"
        case "voicememos": return "Voice Memo"; case "recordings": return "Recording"
        default: return s.rawValue.hasPrefix("mcp:") ? String(s.rawValue.dropFirst(4)).capitalized : s.rawValue.capitalized
        }
    }

    /// One line, trimmed to something a person will read, with the newlines taken out so a bullet stays a bullet.
    static func line(_ s: String, cap: Int = 300) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= cap ? t : String(t.prefix(cap - 1)) + "…"
    }

    /// Every day the summaries touch, with the note for each. Nothing is written for a day that kept nothing.
    public static func notes(summaries: [SummaryRecord], asks: [Ask] = [], now: Date,
                             calendar: Calendar = .current, existing: (String) -> String?) -> [(path: String, body: String)] {
        var byDay: [Date: [SummaryRecord]] = [:]
        for s in summaries { byDay[day(of: s, calendar: calendar), default: []].append(s) }
        let today = calendar.startOfDay(for: now)
        return byDay.keys.sorted().compactMap { d in
            let p = path(for: d, calendar: calendar)
            // Open asks ride on today's note only; repeating them on every back-dated day would be noise.
            let a = d == today ? asks : []
            guard let body = merge(summaries: byDay[d]!, asks: a, day: d, into: existing(p), calendar: calendar) else { return nil }
            return (p, body)
        }
    }
}
