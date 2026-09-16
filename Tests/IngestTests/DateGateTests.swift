import Testing
import Foundation
@testable import Ingest
import Domain
import Platform
import Privacy
import Support

/// A single row dated 2033 must never be read, never become the cursor's mark, and must leave a trace in the drop log.
@Suite struct DateGateTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)   // 16 Sep 2026
    func cand(_ t: Double, _ id: String) -> Candidate {
        Candidate(source: "fixture", bucket: BucketID("fixture:a"), key: ItemKey(order: t, tiebreak: id), kind: .directMessage, id: id, itemDate: Date(timeIntervalSince1970: t), metadata: ["name": id])
    }

    @Test func aFutureCandidateIsDroppedBeforeReadingAndRecorded() async throws {
        let store = try SQLiteRunStore.inMemory()
        let reader = TableReader { _ in #"{"summary":"The user kept this.","title":"Kept","keep":true}"# }
        let run = IngestRun(store: store, reader: reader, triage: try Triage(), policy: DefaultSensitivityPolicy(), clock: FixedClock(now))
        let runID = try await store.beginRun(trigger: .test, at: now)
        let future = cand(2_001_513_725, "y2033"), real = cand(1_789_400_000, "real")
        let stats = try await run.read(FixtureSource(items: [future, real]), enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(stats.kept == 1 && stats.dropped == 1)
        #expect(await reader.calls == 1, "the 2033 window never reached the reader")
        let cursor = try await store.cursor(BucketID("fixture:a"))
        #expect(cursor?.mark == real.key && cursor?.floor == nil, "the mark is the real newest item, not the 2033 one")
        let drops = try await store.drops(since: now.addingTimeInterval(-60))
        #expect(drops.map(\.reason) == [.badDate])
        let coverage = await run.coverage(of: "fixture")
        #expect(coverage?.itemsRead == 1 && coverage?.notRead == 1 && coverage?.buckets == 1)
        #expect(coverage?.oldestRead == real.itemDate && coverage?.newestRead == real.itemDate && coverage?.lastRun == now)
    }

    @Test func theGateSplitsOnlyOnUnbelievableDates() {
        let undated = Candidate(source: "fixture", bucket: BucketID("fixture:a"), key: ItemKey(order: 1), kind: .document, id: "nodate", itemDate: nil)
        let (dated, bad) = IngestRun.gate([cand(2_001_513_725, "y2033"), cand(1_789_400_000, "real"), undated, cand(1_000_000_000, "y2001")], now: now)
        #expect(dated.map(\.id) == ["real", "nodate"], "an item without a date is left for the reader to judge")
        #expect(bad.map(\.id) == ["y2033", "y2001"])
    }
}
