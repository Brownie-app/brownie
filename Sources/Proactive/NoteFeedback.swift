import Foundation
import Domain

/// Turns the user's word on the notes into the lines the note builder reads before it writes, and into the Sunday
/// letter's confession — the notes' twin of `FeedbackDigest`.
public enum NoteFeedbackDigest {
    public static let horizon: TimeInterval = 90 * 86400
    public static let maxLines = 24
    public static let maxGoodTitles = 8

    /// Standing instructions learned from the ratings, newest first. A "not right" with a reason is one line; the same
    /// wording twice is one line; a note called right (its latest word) is named once at the end so the style is kept.
    /// Empty when there is nothing to say.
    public static func instructions(_ all: [NoteFeedback], now: Date) -> String {
        let recent = all.filter { now.timeIntervalSince($0.at) < horizon }.sorted { $0.at > $1.at }
        guard !recent.isEmpty else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM"
        var lines: [String] = []
        var seen = Set<String>()
        for fb in recent where fb.verdict == .notRight {
            guard let reason = fb.reason, seen.insert(key(reason)).inserted else { continue }
            lines.append("- \(reason) (about \(fb.title), \(f.string(from: fb.at)))")
        }
        var out: [String] = []
        if !lines.isEmpty { out.append("WHAT YOU CORRECTED IN THE NOTES (standing instructions, newest first):"); out.append(contentsOf: lines.prefix(maxLines)) }
        let good = latestPerNote(recent).filter { $0.verdict == .good }.map(\.title)
        if !good.isEmpty { out.append("Notes you called right: \(good.prefix(maxGoodTitles).joined(separator: ", ")) — keep that style.") }
        return out.joined(separator: "\n")
    }

    /// One sentence for the Sunday letter: what was corrected this week, and what was called right.
    public static func weekLine(_ all: [NoteFeedback], since: Date) -> String {
        let week = all.filter { $0.at >= since }.sorted { $0.at > $1.at }
        guard !week.isEmpty else { return "" }
        let latest = latestPerNote(week)
        let wrong = latest.filter { $0.verdict == .notRight }, right = latest.filter { $0.verdict == .good }
        var parts: [String] = []
        if !wrong.isEmpty {
            let said = wrong.map { fb in fb.reason.map { "\($0) (\(fb.title))" } ?? "\(fb.title) (no reason given)" }
            parts.append("You corrected \(wrong.count) note\(wrong.count == 1 ? "" : "s") this week: " + said.joined(separator: " · ") + ". Those lessons are now in Brownie's standing instructions for the notes.")
        }
        if !right.isEmpty { parts.append("You called \(right.count) note\(right.count == 1 ? "" : "s") right: \(right.map(\.title).joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    /// The newest word on each note, in the order given (which is newest first everywhere above).
    static func latestPerNote(_ sortedNewestFirst: [NoteFeedback]) -> [NoteFeedback] {
        var seen = Set<String>()
        return sortedNewestFirst.filter { seen.insert($0.path).inserted }
    }
    /// The wording that makes two reasons one: case, spacing and trailing punctuation put aside.
    static func key(_ reason: String) -> String {
        let folded = reason.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        let words = folded.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet(charactersIn: ".!,;:… "))
    }
}
