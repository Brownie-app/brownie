import Foundation

/// A kept summary, tagged with where it came from (the KB builder's trust tier). `sid` is the stable
/// id the notes cite (a short hash of source, bucket, kind and item key); rows written before it
/// existed carry nil. `mergedAt` is set once the builder has folded the row into the notes.
public struct SummaryRecord: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let runID: Int64
    public let source: SourceID
    public let bucket: BucketID
    public let bucketName: String
    public let kind: SourceKind
    public let title: String
    public let text: String
    public let itemDate: Date?
    public let createdAt: Date
    public let sid: String?
    public let mergedAt: Date?
    public init(id: Int64, runID: Int64, source: SourceID, bucket: BucketID, bucketName: String, kind: SourceKind,
                title: String, text: String, itemDate: Date?, createdAt: Date, sid: String? = nil, mergedAt: Date? = nil) {
        self.id = id; self.runID = runID; self.source = source; self.bucket = bucket; self.bucketName = bucketName
        self.kind = kind; self.title = title; self.text = text; self.itemDate = itemDate; self.createdAt = createdAt
        self.sid = sid; self.mergedAt = mergedAt
    }
    /// The date the notes should file it under: when the item happened, else when it was read.
    public var effectiveDate: Date { itemDate ?? createdAt }
}

/// Per-bucket cursor. `mark` is the high-water mark; `floor` exists only mid-way through a first
/// run (the oldest item done so far) and collapses into `mark` when the bottom is reached.
public struct BucketCursor: Sendable, Equatable {
    public let bucket: BucketID
    public let source: SourceID
    public var mark: ItemKey?
    public var floor: ItemKey?
    public init(bucket: BucketID, source: SourceID, mark: ItemKey?, floor: ItemKey?) {
        self.bucket = bucket; self.source = source; self.mark = mark; self.floor = floor
    }
    public var isMidInitial: Bool { floor != nil }
    public var isComplete: Bool { mark != nil && floor == nil }
}

public enum RunTrigger: String, Codable, Sendable { case overnight, manual, catchUp, firstRun, test, daytime }

public enum RunOutcome: Codable, Sendable, Equatable {
    case ran(cards: Int)
    case skippedOnBattery, skippedAppClosed, skippedNotUnlocked
    case failedReader(String)
    case failedBrain(BrainFailure)
    case cancelled
    case partial(stage: String)
    public enum BrainFailure: String, Codable, Sendable { case usageLimit, unauthorized, notConfigured, other }
}

public struct RunStats: Sendable, Equatable, Codable {
    public var read = 0, kept = 0, dropped = 0, sensitive = 0, failed = 0, deferred = 0
    public init() {}
    public mutating func record(_ reason: VerdictReason) {
        read += 1
        switch reason.verdict {
        case .keep: kept += 1
        case .drop: if reason == .loadFailed || reason == .readerFailed { failed += 1 } else { dropped += 1 }
        case .sensitive: sensitive += 1
        }
    }
}

public struct RunRecord: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let trigger: RunTrigger
    public let startedAt: Date
    public let endedAt: Date?
    public let outcome: RunOutcome?
    public let stats: RunStats
    public init(id: Int64, trigger: RunTrigger, startedAt: Date, endedAt: Date?, outcome: RunOutcome?, stats: RunStats) {
        self.id = id; self.trigger = trigger; self.startedAt = startedAt; self.endedAt = endedAt; self.outcome = outcome; self.stats = stats
    }
}

public struct DropRecord: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let runID: Int64
    public let source: SourceID
    public let bucketName: String
    public let reason: VerdictReason
    public let at: Date
    public init(id: Int64, runID: Int64, source: SourceID, bucketName: String, reason: VerdictReason, at: Date) {
        self.id = id; self.runID = runID; self.source = source; self.bucketName = bucketName; self.reason = reason; self.at = at
    }
}

/// The app's store. Every implementation must make `commit` atomic: the summary (if any) and the
/// cursor advance land in ONE transaction, so a crash can never duplicate or skip an item.
public protocol RunStore: Sendable {
    // runs
    func beginRun(trigger: RunTrigger, at: Date) async throws -> Int64
    func endRun(_ id: Int64, outcome: RunOutcome, stats: RunStats, at: Date) async throws
    func recentRuns(limit: Int) async throws -> [RunRecord]
    func lastRun() async throws -> RunRecord?
    // cursors
    func cursor(_ bucket: BucketID) async throws -> BucketCursor?
    func cursors(for source: SourceID) async throws -> [BucketCursor]
    func commit(runID: Int64, cursor: BucketCursor, bucketName: String, candidate: Candidate, outcome: Outcome, at: Date) async throws
    func clearBucket(_ bucket: BucketID) async throws
    /// Forgets every cursor of one source, so its next run is a first read again (the way "Read further back" widens a window).
    func resetCursors(for source: SourceID) async throws
    // summaries (ephemeral): fed to the notes exactly once, oldest first, then deleted
    func summaries(since: Date?) async throws -> [SummaryRecord]
    /// Rows the notes have not absorbed yet, ordered by when the item happened (read time when undated), then id.
    func unmergedSummaries() async throws -> [SummaryRecord]
    /// Records that these rows are now in the notes, so no later run feeds them again.
    func markMerged(ids: [Int64], at: Date) async throws
    /// Drops every row that is already in the notes; unmerged rows wait for the next sync.
    func deleteMerged() async throws
    /// The panic path only: throws away every summary, merged or not.
    func wipeSummaries() async throws
    // drop log
    func drops(since: Date) async throws -> [DropRecord]
    // what left the Mac
    func logSend(purpose: String, model: String, bytes: Int, detail: String, cameBack: String, payload: String, at: Date) async throws -> Int64
    func setSendResult(_ id: Int64, cameBack: String) async throws
    func sendLog(since: Date) async throws -> [SendRecord]
    // key/value
    func value(_ key: String) async throws -> String?
    func setValue(_ key: String, _ value: String?) async throws
    // nuclear
    func factoryReset() async throws
}
