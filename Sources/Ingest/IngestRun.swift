import Foundation
import Domain
import Support

/// Drives any `Source` through the reader and commits results. Crash-safe: every item commits its
/// optional survivor AND its cursor advance in ONE store write. See `docs/spec/03-ingest.md`.
public actor IngestRun {
    public enum Mode: Sendable { case auto, initial, incremental }
    public struct Limits: Sendable {
        public var initialPerBucket = 500
        public var incrementalPerBucket = 400
        public var preemptiveReloadEvery = 40
        public var failuresBeforeReload = 3
        public var maxReloadsWithoutProgress = 4
        public init() {}
    }
    public enum Failure: Error { case readerStuck, cancelled }

    private let store: RunStore
    private let reader: LocalModel
    private let triage: Triage
    private let policy: SensitivityPolicy
    private let clock: Clock
    private let limits: Limits
    private let log = Log("ingest")
    /// What each source read this run, by source, for the coverage line the user sees. Overwritten per `read`.
    private var coverages: [SourceID: SourceCoverage] = [:]

    /// How far this run got with a source: the date range and count of what was read, and what was left.
    public func coverage(of source: SourceID) -> SourceCoverage? { coverages[source] }

    public init(store: RunStore, reader: LocalModel, triage: Triage, policy: SensitivityPolicy, clock: Clock = SystemClock(), limits: Limits = Limits()) {
        self.store = store; self.reader = reader; self.triage = triage; self.policy = policy; self.clock = clock; self.limits = limits
    }

    /// Reads one source. Returns the stats for this source. Progress is per item.
    @discardableResult
    public func read(_ source: any Source, enabledBuckets: Set<BucketID>?, runID: Int64, mode: Mode = .auto,
                     progress: @escaping @Sendable (RunProgress) -> Void) async throws -> RunStats {
        var stats = RunStats()
        let name = source.descriptor.name
        let cursors = try await store.cursors(for: source.id)
        let buckets = try await source.buckets(since: Self.marks(of: cursors), enabled: enabledBuckets)
        var itemsSinceReload = 0, failureStreak = 0, reloadsWithoutProgress = 0
        var lastTitle: String?, lastSummary: String?
        var oldest: Date?, newest: Date?, itemsRead = 0, notRead = 0
        defer { coverages[source.id] = SourceCoverage(source: source.id, oldestRead: oldest, newestRead: newest, itemsRead: itemsRead, notRead: notRead + stats.deferred, lastRun: clock.now(), buckets: buckets.count) }

        for (bi, bucket) in buckets.enumerated() {
            let existing = try await store.cursor(bucket.id)
            var cursor = existing ?? BucketCursor(bucket: bucket.id, source: source.id, mark: nil, floor: nil)
            if mode == .initial { cursor = BucketCursor(bucket: bucket.id, source: source.id, mark: nil, floor: nil) }
            // The date gate, before any planning: an item dated years ahead or absurdly far back is never read and never
            // becomes a cursor mark. The ones this pass would otherwise have read are logged as drops, against the stored
            // cursor as it stands, so the log shows they went and nothing else moves.
            let (dated, undated) = Self.gate(bucket.items, now: clock.now())
            for item in Self.plan(undated, cursor: cursor, mode: mode, limits: limits, now: clock.now()).items {
                stats.record(.badDate); notRead += 1
                log.warn("\(name)/\(bucket.name): \(item.id) dated \(item.itemDate.map { "\($0)" } ?? "?") is not believable — dropped before reading")
                try await store.commit(runID: runID, cursor: existing ?? cursor, bucketName: bucket.name, candidate: item, outcome: Outcome(reason: .badDate), at: clock.now())
            }
            let plan = Self.plan(dated, cursor: cursor, mode: mode, limits: limits, now: clock.now())
            for d in plan.items.compactMap(\.itemDate) { oldest = min(oldest ?? d, d); newest = max(newest ?? d, d) }
            itemsRead += plan.items.count
            if plan.kind == .incremental, let m = cursor.mark, Self.isFutureDateKey(m, now: clock.now()) { log.warn("\(bucket.name): cursor mark was in the future (\(m.order)) — re-reading the newest item to heal it") }
            stats.deferred += plan.deferred + bucket.deferred
            log.info("\(name)/\(bucket.name): \(plan.items.count) items (\(plan.kind)), deferred \(plan.deferred + bucket.deferred)")

            for (ii, item) in plan.items.enumerated() {
                if Task.isCancelled { throw Failure.cancelled }
                var p = RunProgress(stage: .reading, sourceName: name, bucketName: bucket.name, bucketIndex: bi + 1, bucketCount: buckets.count,
                                    itemIndex: ii + 1, itemCount: plan.items.count, stats: stats, lastTitle: lastTitle, lastSummary: lastSummary)
                progress(p)

                // load
                let artifact: Artifact
                do { artifact = try await source.load(item) }
                catch {
                    log.warn("load failed \(item.id): \(error)")
                    stats.record(.loadFailed)
                    cursor = Self.advance(cursor, past: item.key, kind: plan.kind, isLast: ii == plan.items.count - 1 && plan.deferred == 0)
                    try await store.commit(runID: runID, cursor: cursor, bucketName: bucket.name, candidate: item, outcome: Outcome(reason: .loadFailed), at: clock.now())
                    continue
                }

                // judge (with wedge recovery)
                if itemsSinceReload >= limits.preemptiveReloadEvery {
                    try await reader.reload(); itemsSinceReload = 0
                }
                var result: GenerateResult?
                var attempt = 0
                while result == nil && attempt < 2 {
                    attempt += 1
                    do {
                        result = try await reader.generate(GenerateRequest(prompt: triage.prompt(for: artifact, now: clock.now()), imageJPEG: artifact.imageJPEG))
                        failureStreak = 0; reloadsWithoutProgress = 0
                    } catch LocalModelError.cancelled { throw Failure.cancelled }
                    catch {
                        failureStreak += 1
                        log.warn("reader failed (\(failureStreak)): \(error)")
                        if failureStreak >= limits.failuresBeforeReload {
                            reloadsWithoutProgress += 1
                            if reloadsWithoutProgress > limits.maxReloadsWithoutProgress { throw Failure.readerStuck }
                            try await reader.reload(); itemsSinceReload = 0; failureStreak = 0
                        } else { break }
                    }
                }
                itemsSinceReload += 1

                var outcome: Outcome
                if let r = result {
                    if let j = Triage.parse(r.text) { outcome = policy.admit(j) }
                    else {
                        // One strict retry before failing closed: small models occasionally break the JSON on long windows.
                        let strict = triage.prompt(for: artifact, now: clock.now()) + "\n\nYour previous reply was not valid JSON. Reply with ONLY the JSON object on one line, no prose, no code fences, and escape any quotes inside the strings."
                        let again = try? await reader.generate(GenerateRequest(prompt: strict, imageJPEG: artifact.imageJPEG))
                        outcome = again.flatMap { Triage.parse($0.text) }.map(policy.admit) ?? Outcome(reason: .parseFailed)
                    }
                } else {
                    outcome = Outcome(reason: .readerFailed)
                }
                stats.record(outcome.reason)

                cursor = Self.advance(cursor, past: item.key, kind: plan.kind, isLast: ii == plan.items.count - 1 && plan.deferred == 0)
                let bucketLabel = (item.metadata["phone"] ?? "").isEmpty ? bucket.name : "\(bucket.name) (+\(item.metadata["phone"]!))"
                try await store.commit(runID: runID, cursor: cursor, bucketName: bucketLabel, candidate: item, outcome: outcome, at: clock.now())

                // Sensitive items publish nothing but the count.
                p.stats = stats
                if outcome.verdict == .sensitive { /* nothing about it is shown */ }
                else if let sv = outcome.survivor { lastTitle = sv.title; lastSummary = sv.summary }
                else { lastTitle = artifact.metadata["name"]; lastSummary = "Not worth keeping" }
                p.lastTitle = lastTitle; p.lastSummary = lastSummary
                progress(p)
            }
        }
        return stats
    }

    // MARK: the date gate

    /// Splits a bucket into the items whose dates can be believed (or that carry none) and the ones that cannot.
    static func gate(_ items: [Candidate], now: Date) -> (dated: [Candidate], undated: [Candidate]) {
        var dated: [Candidate] = [], undated: [Candidate] = []
        for c in items {
            if let d = c.itemDate, DateSanity.item(d, now: now) == nil { undated.append(c) } else { dated.append(c) }
        }
        return (dated, undated)
    }

    // MARK: planning

    /// The marks a source is told about: only buckets read to the bottom once. A bucket still mid-way through
    /// its first read (a floor exists) is deliberately left out, so the source applies its first-read window
    /// and cap again and the resume walks below the floor inside that same bounded slice. Handing back a
    /// half-read bucket's mark would make WhatsApp or iMessage list the chat's entire history, and Slack or
    /// Teams list only what is newer than the mark, which the resume then filters to nothing.
    static func marks(of cursors: [BucketCursor]) -> [BucketID: ItemKey] {
        Dictionary(uniqueKeysWithValues: cursors.compactMap { c in c.isComplete ? c.mark.map { (c.bucket, $0) } : nil })
    }

    enum PlanKind: String { case initial, resume, incremental, none }
    struct Plan { let items: [Candidate]; let kind: PlanKind; let deferred: Int }

    /// A key that reads as a Unix date more than a day ahead. Row-id keys (Messages) are far too small to trip this.
    static func isFutureDateKey(_ k: ItemKey, now: Date) -> Bool { k.order > now.timeIntervalSince1970 + 86400 && k.order < 4_000_000_000 }

    /// Newest-first input. Initial (and resume): walk newest→oldest below the floor. Incremental:
    /// items above the mark, oldest→newest.
    static func plan(_ newestFirst: [Candidate], cursor: BucketCursor, mode: Mode, limits: Limits, now: Date? = nil) -> Plan {
        let wantInitial = mode == .initial || (mode == .auto && !cursor.isComplete)
        if wantInitial {
            var items = newestFirst
            if let floor = cursor.floor { items = items.filter { $0.key < floor } }
            let deferred = max(0, items.count - limits.initialPerBucket)
            return Plan(items: Array(items.prefix(limits.initialPerBucket)), kind: cursor.floor == nil ? .initial : .resume, deferred: deferred)
        }
        guard let mark = cursor.mark else { return Plan(items: [], kind: .none, deferred: 0) }
        // A mark that sits in the future (a source once keyed by a bogus date) would hide every real item for good:
        // heal by re-reading the newest item, whose key then becomes the mark.
        if let now, Self.isFutureDateKey(mark, now: now), let newest = newestFirst.first, newest.key < mark {
            return Plan(items: [newest], kind: .incremental, deferred: 0)
        }
        let fresh = newestFirst.filter { $0.key > mark }.reversed()   // oldest → newest
        let deferred = max(0, fresh.count - limits.incrementalPerBucket)
        return Plan(items: Array(fresh.prefix(limits.incrementalPerBucket)), kind: .incremental, deferred: deferred)
    }

    /// Initial: the floor sinks per item; the mark is set to the newest item at the start and the
    /// floor collapses when the bottom is reached. Incremental: the mark climbs per item.
    static func advance(_ c: BucketCursor, past key: ItemKey, kind: PlanKind, isLast: Bool) -> BucketCursor {
        var n = c
        switch kind {
        case .initial, .resume:
            if n.mark == nil { n.mark = key }              // the newest item we will ever have seen this pass
            n.floor = isLast ? nil : key                    // bottom reached ⇒ floor collapses into mark
        case .incremental:
            n.mark = key
        case .none: break
        }
        return n
    }
}
