import Foundation
import Domain

/// Turns thumbs-downs into the lines the judge and preparer read, and into the Sunday letter's confession.
public enum FeedbackDigest {
    public static let horizon: TimeInterval = 90 * 86400
    public static let maxLines = 24

    /// Standing instructions learned from feedback, newest lessons first. Empty when there is nothing to say.
    public static func instructions(_ all: [CardFeedback], now: Date) -> String {
        let recent = all.filter { now.timeIntervalSince($0.at) < horizon }.sorted { $0.at > $1.at }
        guard !recent.isEmpty else { return "" }
        var lines: [String] = []
        var seen = Set<String>()
        func add(_ key: String, _ line: String) { if seen.insert(key).inserted { lines.append(line) } }
        let f = DateFormatter(); f.dateFormat = "d MMM"

        // People the user disowned outright: never again.
        for fb in recent where fb.verdict == .notMine { if let p = fb.person { add("notmine:\(p.lowercased())", "Anything involving \(p) is not the user's — never make a card about it.") } else { add("notmine:\(fb.cardTitle)", "“\(fb.cardTitle)” was not the user's; skip items like it.") } }
        // Not important: once is a hint, twice is a rule.
        let unimportant = Dictionary(grouping: recent.filter { $0.verdict == .notImportant }, by: { $0.person?.lowercased() ?? "" })
        for (k, fbs) in unimportant {
            if let p = fbs.first?.person, fbs.count >= 2 { add("unimp:\(k)", "Cards about \(p) only when there is a promise or a deadline — the user marked \(fbs.count) of them not important.") }
            else if let p = fbs.first?.person { add("unimp1:\(k)", "The user marked a card about \(p) (“\(fbs[0].cardTitle)”) not important; raise the bar for that person.") }
            else { for fb in fbs { add("unimp:\(fb.cardTitle)", "“\(fb.cardTitle)” was not important to the user; skip items like it.") } }
        }
        // Voice.
        let formal = recent.filter { $0.verdict == .tooFormal }
        if formal.count >= 2 { add("formal:all", "Every draft was too formal for this user: write like their own messages — short, first name, no sign-off.") }
        for fb in formal { if let p = fb.person { add("formal:\(p.lowercased())", "Drafts to \(p): plain and casual, the way the user writes to them.") } }
        // Done, wrong, or mistimed: specific to the card.
        for fb in recent where fb.verdict == .alreadyDone { add("done:\(fb.cardTitle)", "“\(fb.cardTitle)” was already done (the user said so on \(f.string(from: fb.at))) — do not bring it back unless something new is said.") }
        for fb in recent where fb.verdict == .wrongPerson { add("who:\(fb.cardTitle)", "“\(fb.cardTitle)” named the wrong person\(fb.person.map { " (it was addressed to \($0))" } ?? ""); match identities carefully there.") }
        for fb in recent where fb.verdict == .wrongTiming { add("when:\(fb.cardTitle)", "“\(fb.cardTitle)” came too early; wait for a date or a new message before raising it again.") }
        for fb in recent where fb.verdict == .other && !fb.note.isEmpty { add("note:\(fb.note)", "About “\(fb.cardTitle)” the user said: “\(fb.note.trimmingCharacters(in: .whitespacesAndNewlines))”.") }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    /// One paragraph for the Sunday letter: what was corrected this week and what changed because of it.
    public static func weekLine(_ all: [CardFeedback], since: Date) -> String {
        let week = all.filter { $0.at >= since }
        guard !week.isEmpty else { return "" }
        let counts = Dictionary(grouping: week, by: \.verdict).mapValues(\.count)
        let parts = Verdict.allCases.compactMap { v -> String? in
            guard let n = counts[v], n > 0 else { return nil }
            switch v {
            case .notMine: return "\(n) \(n == 1 ? "wasn't" : "weren't") yours (\(names(week, v)))"
            case .alreadyDone: return "\(n) already done"
            case .tooFormal: return "\(n) too formal"
            case .wrongPerson: return "\(n) named the wrong person"
            case .notImportant: return "\(n) not important"
            case .wrongTiming: return "\(n) too early"
            case .other: return "\(n) with a note"
            }
        }
        return "You corrected \(week.count) card\(week.count == 1 ? "" : "s") this week: " + parts.joined(separator: " · ") + ". Those lessons are now in Brownie's standing instructions."
    }
    private typealias Verdict = CardFeedback.Verdict
    private static func names(_ fbs: [CardFeedback], _ v: Verdict) -> String {
        let ps = Array(Set(fbs.filter { $0.verdict == v }.compactMap(\.person))).sorted()
        return ps.isEmpty ? "—" : ps.joined(separator: ", ")
    }
}
