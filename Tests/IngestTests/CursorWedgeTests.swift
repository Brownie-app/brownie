import Testing
import Foundation
@testable import Ingest
import Domain
import Platform
import Privacy
import Support

/// A chat-shaped source whose history can grow between runs, the way a live WhatsApp chat does: with no mark it lists
/// the newest `cap` items, with a mark only what is newer. The slice therefore slides up as messages arrive.
final class SlidingHistorySource: Source, @unchecked Sendable {
    static let descriptor = SourceDescriptor(id: "sliding", name: "Sliding", detail: "", door: .localDatabase)
    static let bucket = BucketID("sliding:chat")
    private let lock = NSLock()
    private var all: [Candidate]   // newest first
    let cap: Int
    private(set) var listed: [Int] = []

    init(all: [Candidate], cap: Int) { self.all = all; self.cap = cap }
    func arrive(_ c: Candidate) { lock.lock(); all.insert(c, at: 0); lock.unlock() }
    func availability() async -> Availability { .available }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        lock.lock(); defer { lock.unlock() }
        let items = marks[Self.bucket].map { m in all.filter { $0.key > m } } ?? Array(all.prefix(cap))
        listed.append(items.count)
        return [Bucket(id: Self.bucket, name: "Chat", items: items, deferred: marks[Self.bucket] == nil ? max(0, all.count - cap) : 0)]
    }
    func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "text for \(c.id)") }
}

/// A folder-shaped source the way Files, Notes and Voice Memos list: with no mark, only what falls inside the
/// first-read window; with a mark, everything, for the core to filter above the mark.
final class WindowedSource: Source, @unchecked Sendable {
    static let descriptor = SourceDescriptor(id: "windowed", name: "Windowed", detail: "", door: .localDatabase)
    static let bucket = BucketID("windowed:root")
    private let lock = NSLock()
    private var all: [Candidate]   // newest first
    let edge: Date

    init(all: [Candidate], edge: Date) { self.all = all; self.edge = edge }
    func arrive(_ c: Candidate) { lock.lock(); all.insert(c, at: 0); lock.unlock() }
    func availability() async -> Availability { .available }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        lock.lock(); defer { lock.unlock() }
        let items = marks[Self.bucket] == nil ? all.filter { ($0.itemDate ?? .distantPast) >= edge } : all
        return [Bucket(id: Self.bucket, name: "Root", items: items)]
    }
    func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "text for \(c.id)") }
}

/// A source that lists nothing at all this run, under the same id as `CappedHistorySource`.
struct SilentCappedSource: Source {
    static let descriptor = CappedHistorySource.descriptor
    func availability() async -> Availability { .available }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] { [] }
    func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "") }
}

/// A first read that stops mid-way must finish on a later run even when the listing no longer reaches below the
/// floor, what a cap set aside must stay "not read" on the quiet nights after it, and an item with an unbelievable
/// date must be recorded once, not every night.
@Suite struct CursorWedgeTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)   // 16 Sep 2026
    func message(_ i: Int, source: SourceID = "sliding", bucket: BucketID = SlidingHistorySource.bucket, daysAgo: Double) -> Candidate {
        let t = now.timeIntervalSince1970 - daysAgo * 86_400
        return Candidate(source: source, bucket: bucket, key: ItemKey(order: t, tiebreak: "m\(i)"), kind: .directMessage, id: "m\(i)", itemDate: Date(timeIntervalSince1970: t))
    }
    func run(_ store: SQLiteRunStore, stopAt: Int = .max) throws -> IngestRun {
        IngestRun(store: store, reader: StoppingReader(failAt: stopAt), triage: try Triage(), policy: DefaultSensitivityPolicy(), clock: FixedClock(now))
    }

    @Test func aFirstReadStoppedOneShortCompletesOnceTheSliceSlidesAndReadsWhatArrived() async throws {
        let store = try SQLiteRunStore.inMemory()
        let history = (0..<40).map { message($0, daysAgo: Double($0)) }
        let source = SlidingHistorySource(all: history, cap: 10)
        let runID = try await store.beginRun(trigger: .test, at: now)

        // Night 1: the newest ten are listed; the run is stopped with one still to read, so the floor sits at the ninth.
        await #expect(throws: IngestRun.Failure.self) { try await run(store, stopAt: 10).read(source, enabledBuckets: nil, runID: runID, progress: { _ in }) }
        let mid = try #require(try await store.cursor(SlidingHistorySource.bucket))
        #expect(mid.mark == history[0].key && mid.floor == history[8].key && !mid.isComplete)

        // Overnight a message arrives, so the newest ten now start above the old floor: nothing lies below it any more.
        source.arrive(message(100, daysAgo: -0.1))
        let s2 = try await run(store).read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s2.read == 0 && source.listed[1] == 10, "the cap applied again and everything listed was above the floor")
        let done = try #require(try await store.cursor(SlidingHistorySource.bucket))
        #expect(done.isComplete && done.mark == history[0].key, "the floor collapsed into the mark instead of waiting for ever")
        #expect(done.setAside == 31, "what the cap set aside is on the cursor: forty-one messages, ten listed")

        // Night 3: the mark goes back, only the new message is listed, and it is read.
        let s3 = try await run(store).read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s3.read == 1 && source.listed[2] == 1)
        let after = try #require(try await store.cursor(SlidingHistorySource.bucket))
        #expect(after.isComplete && after.mark?.tiebreak == "m100")
        #expect(try await store.summaries(since: nil).map(\.title).count == 10, "nine from night 1 and the one that arrived")
    }

    @Test func aWindowBoundRootWithAFloorOlderThanTheWindowCompletesAndReadsNewFiles() async throws {
        let store = try SQLiteRunStore.inMemory()
        let bucket = WindowedSource.bucket
        let files = (0..<20).map { message($0, source: "windowed", bucket: bucket, daysAgo: Double($0) * 10) }   // 0 … 190 days back
        let source = WindowedSource(all: files, edge: now.addingTimeInterval(-180 * 86_400))
        // The old build listed every file and walked 500 a night: mark = newest, floor = a file added 300 days ago.
        let floor = message(999, source: "windowed", bucket: bucket, daysAgo: 300)
        try await store.setCursor(BucketCursor(bucket: bucket, source: "windowed", mark: files[0].key, floor: floor.key), at: now)
        let runID = try await store.beginRun(trigger: .test, at: now)

        let night1 = try run(store)
        let s1 = try await night1.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s1.read == 0 && s1.deferred == 0, "every file in the window is newer than the floor, so nothing is read again")
        let done = try #require(try await store.cursor(bucket))
        #expect(done.isComplete && done.mark == files[0].key, "the floor collapsed; the root is no longer wedged")
        #expect(await night1.coverage(of: "windowed")?.notRead == 0)

        source.arrive(message(100, source: "windowed", bucket: bucket, daysAgo: -0.1))
        let s2 = try await run(store).read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s2.read == 1, "the file downloaded today is read on the next run")
        #expect(try await store.cursor(bucket)?.mark?.tiebreak == "m100")
    }

    @Test func whatACapSetAsideStaysNotReadOnTheNightsAfter() async throws {
        let store = try SQLiteRunStore.inMemory()
        let history = (0..<100).map { message($0, source: "capped", bucket: CappedHistorySource.bucket, daysAgo: Double($0)) }
        let source = CappedHistorySource(all: history, cap: 10)
        let runID = try await store.beginRun(trigger: .test, at: now)

        let night1 = try run(store)
        _ = try await night1.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        let c1 = try #require(await night1.coverage(of: "capped"))
        #expect(c1.itemsRead == 10 && c1.notRead == 90)

        // Night 2: the mark goes back, nothing new is listed, and the ninety are still not read.
        let night2 = try run(store)
        let s2 = try await night2.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        let c2 = try #require(await night2.coverage(of: "capped"))
        #expect(s2.read == 0 && s2.deferred == 0, "this run set nothing aside itself")
        #expect(c2.notRead == 90, "the cap's leftover is remembered on the cursor")
        let merged = SourceCoverage.merge(c1, with: c2)
        #expect(CoverageLine.render(merged, timeZone: TimeZone(identifier: "UTC")!).hasSuffix("older not read"))

        // Night 3: the source lists no buckets at all; the count still stands.
        let night3 = try run(store)
        _ = try await night3.read(SilentCappedSource(), enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(await night3.coverage(of: "capped")?.notRead == 90)

        // A first read from scratch is the newest word: fewer messages, fewer set aside.
        try await store.resetCursors(for: "capped")
        let again = try run(store)
        _ = try await again.read(CappedHistorySource(all: Array(history.prefix(30)), cap: 10), enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(await again.coverage(of: "capped")?.notRead == 20)
    }

    @Test func aResumedFirstReadReplacesTheSetAsideCountRatherThanAddingToIt() async throws {
        let store = try SQLiteRunStore.inMemory()
        let history = (0..<100).map { message($0, source: "capped", bucket: CappedHistorySource.bucket, daysAgo: Double($0)) }
        let source = CappedHistorySource(all: history, cap: 10)
        let runID = try await store.beginRun(trigger: .test, at: now)
        var limits = IngestRun.Limits(); limits.initialPerBucket = 6
        let night1 = IngestRun(store: store, reader: StoppingReader(failAt: .max), triage: try Triage(), policy: DefaultSensitivityPolicy(), clock: FixedClock(now), limits: limits)
        _ = try await night1.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(await night1.coverage(of: "capped")?.notRead == 94, "four below the per-run limit and ninety past the cap")
        let night2 = IngestRun(store: store, reader: StoppingReader(failAt: .max), triage: try Triage(), policy: DefaultSensitivityPolicy(), clock: FixedClock(now), limits: limits)
        let s2 = try await night2.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s2.read == 4)
        #expect(await night2.coverage(of: "capped")?.notRead == 90, "the four are read now; only the cap's ninety remain")
        #expect(try await store.cursor(CappedHistorySource.bucket)?.setAside == 90)
    }

    @Test func aFutureDatedItemIsRecordedOnceAndDoesNotKeepTheSourceAtOlderNotRead() async throws {
        let store = try SQLiteRunStore.inMemory()
        let bucket = BucketID("fixture:a")
        let future = message(1, source: "fixture", bucket: bucket, daysAgo: -3_000), real = message(2, source: "fixture", bucket: bucket, daysAgo: 1)
        let runID = try await store.beginRun(trigger: .test, at: now)
        var stats: [RunStats] = [], coverages: [SourceCoverage?] = []
        for _ in 0..<5 {
            let r = try run(store)
            stats.append(try await r.read(FixtureSource(items: [future, real]), enabledBuckets: nil, runID: runID, progress: { _ in }))
            coverages.append(await r.coverage(of: "fixture"))
        }
        #expect(stats.map(\.badDated) == [1, 0, 0, 0, 0], "recorded on the night it first appeared, then only mentioned")
        #expect(stats.map(\.read) == [1, 0, 0, 0, 0] && stats.map(\.dropped) == [0, 0, 0, 0, 0], "never counted as read or as not worth keeping")
        #expect(try await store.drops(since: now.addingTimeInterval(-60)).map(\.reason) == [.badDate], "one drop-log row in five nights")
        let cursor = try #require(try await store.cursor(bucket))
        #expect(cursor.mark == real.key && cursor.isComplete && cursor.gated == [future.key])
        #expect(coverages.compactMap { $0?.notRead } == [0, 0, 0, 0, 0], "a bad date alone is not unread history")
        #expect(CoverageLine.render(try #require(coverages[4]), timeZone: TimeZone(identifier: "UTC")!).hasSuffix("everything read"))
    }
}
