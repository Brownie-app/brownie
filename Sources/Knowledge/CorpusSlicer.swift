import Foundation
import Domain

/// Feeds summaries to the brain as byte-budgeted parts. Deterministic: identical input always
/// re-derives identical parts, which mid-sequence resume depends on. Entries are never split.
public enum CorpusSlicer {
    public static func render(_ s: SummaryRecord, index: Int) -> String {
        let date = s.itemDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "undated"
        return "#\(index) · [\(s.source.rawValue)/\(s.kind.rawValue)] \(s.bucketName) · \(date)\n\(s.title) — \(s.text)\n"
    }

    public static func slice(_ summaries: [SummaryRecord], budget: Int = BrainLimits.corpusPartBudget) -> [String] {
        var parts: [String] = [], current = "", bytes = 0
        for (i, s) in summaries.enumerated() {
            let entry = render(s, index: i + 1)
            let n = entry.utf8.count + 1
            if bytes + n > budget, !current.isEmpty { parts.append(current); current = ""; bytes = 0 }
            current += entry + "\n"; bytes += n
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
