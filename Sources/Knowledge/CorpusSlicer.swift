import Foundation
import Domain

/// Feeds summaries to the brain as byte-budgeted parts. Entries are never split. The builder plans
/// the parts once and freezes each part's ids in its resume token, so a resumed sync renders exactly
/// the rows it planned, whatever arrived since. Every line carries the item's stable id and an
/// absolute ISO date, so a note can cite the item and never has to guess the year.
public enum CorpusSlicer {
    public static func render(_ s: SummaryRecord, timeZone: TimeZone = .current) -> String {
        let date = s.itemDate.map { isoDay($0, timeZone) } ?? "undated"
        return "#\(s.sid ?? String(s.id)) · [\(s.source.rawValue)/\(s.kind.rawValue)] \(s.bucketName) · \(date)\n\(s.title) — \(s.text)\n"
    }

    /// One part's corpus, in the order given.
    public static func render(part: [SummaryRecord], timeZone: TimeZone = .current) -> String {
        part.map { render($0, timeZone: timeZone) + "\n" }.joined()
    }

    /// Groups summaries into parts under the byte budget, keeping their order.
    public static func plan(_ summaries: [SummaryRecord], budget: Int = BrainLimits.corpusPartBudget, timeZone: TimeZone = .current) -> [[SummaryRecord]] {
        var parts: [[SummaryRecord]] = [], current: [SummaryRecord] = [], bytes = 0
        for s in summaries {
            let n = render(s, timeZone: timeZone).utf8.count + 1
            if bytes + n > budget, !current.isEmpty { parts.append(current); current = []; bytes = 0 }
            current.append(s); bytes += n
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    public static func slice(_ summaries: [SummaryRecord], budget: Int = BrainLimits.corpusPartBudget, timeZone: TimeZone = .current) -> [String] {
        plan(summaries, budget: budget, timeZone: timeZone).map { render(part: $0, timeZone: timeZone) }
    }

    /// `YYYY-MM-DD` in the given zone; the year is always there.
    public static func isoDay(_ d: Date, _ timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
