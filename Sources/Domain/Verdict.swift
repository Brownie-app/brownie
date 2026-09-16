import Foundation

/// The reader's decision about one item.
public enum Verdict: String, Codable, Sendable { case keep, drop, sensitive }

/// Why an item landed where it did. Counted separately so diagnostics can tell "the model dropped
/// it" from "the model garbled it". `badDate` is an item whose own date could not be believed (years
/// ahead or absurdly far back); it is dropped before the reader ever sees it.
public enum VerdictReason: String, Codable, Sendable, CaseIterable {
    case kept, modelDrop, emptySummary, parseFailed, modelSensitive, piiBackstop, loadFailed, readerFailed, badDate
    public var verdict: Verdict {
        switch self {
        case .kept: return .keep
        case .modelSensitive, .piiBackstop: return .sensitive
        default: return .drop
        }
    }
}

/// The raw parse of the reader's JSON. Not yet admitted — see `Survivor`.
public struct Judgement: Sendable, Equatable {
    public let summary: String
    public let title: String
    public let keep: Bool
    public let sensitive: Bool
    public init(summary: String, title: String, keep: Bool, sensitive: Bool) {
        self.summary = summary; self.title = title; self.keep = keep; self.sensitive = sensitive
    }
}

/// A summary that passed the sensitivity policy. Only `SensitivityPolicy` can create one — the
/// pipeline cannot store or forward a summary that didn't pass.
public struct Survivor: Sendable, Equatable {
    public let title: String
    public let summary: String
    public let sealed: Sealed
    public struct Sealed: Sendable, Equatable { fileprivate init() {} }
    /// Called only by `SensitivityPolicy` implementations.
    public init(_unchecked title: String, summary: String) {
        self.title = title; self.summary = summary; self.sealed = Sealed()
    }
}

public struct Outcome: Sendable {
    public let reason: VerdictReason
    public let survivor: Survivor?
    public var verdict: Verdict { reason.verdict }
    public init(reason: VerdictReason, survivor: Survivor? = nil) {
        precondition((survivor != nil) == (reason == .kept), "a survivor exists iff the item was kept")
        self.reason = reason; self.survivor = survivor
    }
}

public enum Sensitivity: Sendable, Equatable { case clean, highRisk(String) }

/// Deterministic backstop behind the model. Never instead of it.
public protocol SensitivityPolicy: Sendable {
    func classify(_ text: String) -> Sensitivity
    /// Admits a judgement into a `Survivor` or returns the reason it can't.
    func admit(_ judgement: Judgement) -> Outcome
}
