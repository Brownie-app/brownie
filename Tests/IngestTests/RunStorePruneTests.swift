import Testing
import Foundation
import Domain
@testable import Platform

/// The store's retention, judged at a fixed clock: runs and drops past 90 days, sends past 30, Sunday letters past
/// 26 weeks — and never the pointer keys beside the letters.
@Suite struct RunStorePruneTests {
    // 2026-09-16 UTC, a Wednesday.
    let now = Date(timeIntervalSince1970: 1_789_560_000)
    func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86400) }

    @Test func rowsPastTheirWindowGoAndTheRestStay() async throws {
        let store = try SQLiteRunStore.inMemory()
        let old = try await store.beginRun(trigger: .test, at: days(91))
        let recent = try await store.beginRun(trigger: .test, at: days(89))
        let c = Candidate(source: "fixture", bucket: BucketID("fixture:a"), key: ItemKey(order: 1, tiebreak: "a"), kind: .document, id: "a", itemDate: days(91))
        try await store.commit(runID: old, cursor: BucketCursor(bucket: c.bucket, source: c.source, mark: c.key, floor: nil), bucketName: "A", candidate: c, outcome: Outcome(reason: .modelDrop), at: days(91))
        let c2 = Candidate(source: "fixture", bucket: BucketID("fixture:b"), key: ItemKey(order: 2, tiebreak: "b"), kind: .document, id: "b", itemDate: days(89))
        try await store.commit(runID: recent, cursor: BucketCursor(bucket: c2.bucket, source: c2.source, mark: c2.key, floor: nil), bucketName: "B", candidate: c2, outcome: Outcome(reason: .modelDrop), at: days(89))
        _ = try await store.logSend(purpose: "old", model: "m", bytes: 1, detail: "", cameBack: "", payload: "", at: days(31))
        _ = try await store.logSend(purpose: "recent", model: "m", bytes: 1, detail: "", cameBack: "", payload: "", at: days(29))

        try await store.prune(now: now)
        #expect(try await store.recentRuns(limit: 10).map(\.id) == [recent])
        #expect(try await store.drops(since: .distantPast).map(\.bucketName) == ["B"])
        #expect(try await store.sendLog(since: .distantPast).map(\.purpose) == ["recent"])
    }

    @Test func lettersOlderThanTwentySixWeeksGoAndThePointersStay() async throws {
        let store = try SQLiteRunStore.inMemory()
        for k in ["2026-W10", "2026-W11", "2026-W12", "2026-W30", "2025-W52", "latest", "seen"] { try await store.setValue("proactive.weekly.\(k)", "x") }
        try await store.setValue("proactive.weekly.2026-W37", "this week")
        #expect(try await store.keys(withPrefix: "proactive.weekly.").count == 8)
        try await store.prune(now: now)
        // 26 weeks before 16 Sep 2026 is 18 Mar: W12 (16 Mar) is just past it, W13 would not be.
        #expect(try await store.keys(withPrefix: "proactive.weekly.") == ["proactive.weekly.2026-W30", "proactive.weekly.2026-W37", "proactive.weekly.latest", "proactive.weekly.seen"])
        #expect(try await store.keys(withPrefix: "nothing.").isEmpty)
        try await store.deleteValue("proactive.weekly.seen")
        #expect(try await store.value("proactive.weekly.seen") == nil, "deleteValue is setValue nil")
    }

    @Test func aKeyThatIsNotAWeekIsNeverOld() {
        #expect(SQLiteRunStore.weekIsOlder("proactive.weekly.2026-W01", than: 26, at: now))
        #expect(!SQLiteRunStore.weekIsOlder("proactive.weekly.2026-W13", than: 26, at: now))
        #expect(!SQLiteRunStore.weekIsOlder("proactive.weekly.latest", than: 26, at: now))
        #expect(!SQLiteRunStore.weekIsOlder("proactive.weekly.2026-W1", than: 26, at: now), "not the eight-character form the letters use")
    }
}
