import Foundation
import Domain

/// The one place a `Survivor` is born. Fail closed everywhere.
public struct DefaultSensitivityPolicy: SensitivityPolicy {
    public init() {}

    public func classify(_ text: String) -> Sensitivity {
        PIIScan.highRiskHit(text).map { .highRisk($0) } ?? .clean
    }

    public func admit(_ judgement: Judgement) -> Outcome {
        if judgement.sensitive { return Outcome(reason: .modelSensitive) }
        if !judgement.keep { return Outcome(reason: .modelDrop) }
        let summary = judgement.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = judgement.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty { return Outcome(reason: .emptySummary) }
        if case .highRisk = classify(summary) { return Outcome(reason: .piiBackstop) }
        if case .highRisk = classify(title) { return Outcome(reason: .piiBackstop) }
        return Outcome(reason: .kept, survivor: Survivor(_unchecked: title.isEmpty ? String(summary.prefix(48)) : title, summary: summary))
    }
}
