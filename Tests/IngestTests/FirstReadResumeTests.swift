import Testing
import Foundation
@testable import Ingest
import Domain
import Platform
import Privacy
import Support

/// A chat-shaped source over a long history, the way WhatsApp or iMessage list: with no mark handed in it applies its
/// first-read cap (the newest `cap` items); with a mark it lists only what is newer. It records every listing so a
/// test can see whether the whole history was ever asked for.
final class CappedHistorySource: Source, @unchecked Sendable {
    static let descriptor = SourceDescriptor(id: "capped", name: "Capped", detail: "", door: .localDatabase)
    static let bucket = BucketID("capped:chat")
    let all: [Candidate]   // newest first
    let cap: Int
    private let lock = NSLock()
    private(set) var listed: [Int] = []
    private(set) var marksSeen: [[BucketID: ItemKey]] = []

    init(all: [Candidate], cap: Int) { self.all = all; self.cap = cap }
    func availability() async -> Availability { .available }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let items: [Candidate]
        if let mark = marks[Self.bucket] { items = all.filter { $0.key > mark } } else { items = Array(all.prefix(cap)) }
        lock.lock(); marksSeen.append(marks); listed.append(items.count); lock.unlock()
        return [Bucket(id: Self.bucket, name: "Chat", items: items, deferred: marks[Self.bucket] == nil ? max(0, all.count - cap) : 0)]
    }
    func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "text for \(c.id)") }
}

/// A reader that answers until its `failAt`th call, which is cancelled — the way a user stopping a run looks to the core.
actor StoppingReader: LocalModel {
    var calls = 0
    let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    var isLoaded: Bool { true }
    func load() async throws {}
    func generate(_ r: GenerateRequest) async throws -> GenerateResult {
        calls += 1
        if calls == failAt { throw LocalModelError.cancelled }
        return GenerateResult(text: #"{"summary":"ok","title":"t","keep":true}"#, duration: 0)
    }
    func reload() async throws {}
    func unload() async {}
}

@Suite struct FirstReadResumeTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)
    /// 5,000 messages spread evenly over three years, newest first.
    var history: [Candidate] {
        (0..<5_000).map { i in
            let t = now.timeIntervalSince1970 - Double(i) * (3 * 365 * 86_400 / 5_000)
            return Candidate(source: "capped", bucket: CappedHistorySource.bucket, key: ItemKey(order: t, tiebreak: "m\(i)"), kind: .directMessage, id: "m\(i)", itemDate: Date(timeIntervalSince1970: t))
        }
    }

    @Test func onlyCompleteBucketsHandTheirMarkBack() {
        let done = BucketCursor(bucket: BucketID("a"), source: "s", mark: ItemKey(order: 5), floor: nil)
        let midway = BucketCursor(bucket: BucketID("b"), source: "s", mark: ItemKey(order: 9), floor: ItemKey(order: 7))
        let untouched = BucketCursor(bucket: BucketID("c"), source: "s", mark: nil, floor: nil)
        #expect(IngestRun.marks(of: [done, midway, untouched]) == [BucketID("a"): ItemKey(order: 5)])
    }

    @Test func aRunStoppedMidFirstReadListsTheCapAgainAndNeverTheWholeHistory() async throws {
        let store = try SQLiteRunStore.inMemory()
        let source = CappedHistorySource(all: history, cap: 50)
        let runID = try await store.beginRun(trigger: .test, at: now)

        // Run 1: stopped after two items.
        let stopped = IngestRun(store: store, reader: StoppingReader(failAt: 3), triage: try Triage(), policy: DefaultSensitivityPolicy())
        await #expect(throws: IngestRun.Failure.self) { try await stopped.read(source, enabledBuckets: nil, runID: runID, progress: { _ in }) }
        let mid = try #require(try await store.cursor(CappedHistorySource.bucket))
        #expect(mid.mark == history[0].key && mid.floor == history[1].key, "the mark was set on the first item; the floor sits at the second")
        #expect(!mid.isComplete)

        // Run 2: the bucket is not complete, so the source is told nothing and applies its cap again; the resume walks below the floor.
        let steady = IngestRun(store: store, reader: StoppingReader(failAt: .max), triage: try Triage(), policy: DefaultSensitivityPolicy())
        let s2 = try await steady.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(source.marksSeen[1].isEmpty, "a half-read bucket hands no mark back")
        #expect(source.listed[1] == 50, "the cap applies again, not the whole chat")
        #expect(s2.read == 48, "the two items already read are not read again")
        let done = try #require(try await store.cursor(CappedHistorySource.bucket))
        #expect(done.isComplete && done.mark == history[0].key)

        // Run 3: complete now, so the mark goes back and only newer items are listed — none.
        let s3 = try await steady.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(source.marksSeen[2] == [CappedHistorySource.bucket: history[0].key])
        #expect(source.listed[2] == 0 && s3.read == 0)
        #expect(source.listed.max() == 50, "at no point was the three-year history listed")
        #expect(try await store.summaries(since: nil).count == 50, "every item inside the cap was read exactly once")
    }

    @Test func whatASourceSetsAsideCountsAsDeferred() async throws {
        let store = try SQLiteRunStore.inMemory()
        let source = CappedHistorySource(all: history, cap: 10)
        let runID = try await store.beginRun(trigger: .test, at: now)
        let run = IngestRun(store: store, reader: StoppingReader(failAt: .max), triage: try Triage(), policy: DefaultSensitivityPolicy())
        let s = try await run.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s.read == 10 && s.deferred == 4_990, "the bucket's own deferred count joins the run's")
        let again = try await run.read(source, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(again.deferred == 0, "once complete, nothing is set aside")
    }

    @Test func resettingASourcesCursorsMakesItsBucketsFirstReadsAgain() async throws {
        let store = try SQLiteRunStore.inMemory()
        let runID = try await store.beginRun(trigger: .test, at: now)
        let mine = Candidate(source: "capped", bucket: CappedHistorySource.bucket, key: ItemKey(order: 1), kind: .directMessage, id: "x", itemDate: now)
        let theirs = Candidate(source: "other", bucket: BucketID("other:1"), key: ItemKey(order: 1), kind: .document, id: "y", itemDate: now)
        for c in [mine, theirs] {
            try await store.commit(runID: runID, cursor: BucketCursor(bucket: c.bucket, source: c.source, mark: c.key, floor: nil), bucketName: "b", candidate: c, outcome: Outcome(reason: .modelDrop), at: now)
        }
        try await store.resetCursors(for: "capped")
        #expect(try await store.cursors(for: "capped").isEmpty)
        #expect(try await store.cursors(for: "other").count == 1, "another source's cursors stay")
    }
}
