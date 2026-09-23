import Testing
import Foundation
@testable import Ingest
import Domain

/// A message stamped years ahead must never become "the newest thing", and a cursor already poisoned by one heals itself.
@Suite struct FutureCursorTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)
    func cand(_ order: Double, _ id: String) -> Candidate { Candidate(source: "whatsapp", bucket: BucketID("whatsapp:507"), key: ItemKey(order: order, tiebreak: id), kind: .directMessage, id: id, itemDate: Date(timeIntervalSince1970: order)) }
    var limits: IngestRun.Limits { IngestRun.Limits() }

    @Test func aFutureMarkReReadsTheNewestItemInsteadOfHidingEverything() {
        let poisoned = BucketCursor(bucket: BucketID("whatsapp:507"), source: "whatsapp", mark: ItemKey(order: 2_001_513_725, tiebreak: "56231"), floor: nil)
        let items = [cand(1_789_490_000, "new"), cand(1_789_400_000, "older")]   // newest first, both "below" the poisoned mark
        #expect(IngestRun.plan(items, cursor: poisoned, mode: .auto, limits: limits).items.isEmpty, "without the clock nothing would ever be read again")
        let healed = IngestRun.plan(items, cursor: poisoned, mode: .auto, limits: limits, now: now)
        #expect(healed.kind == .incremental && healed.items.map(\.id) == ["new"], "the newest item is read once; its key then becomes the mark")
        let after = IngestRun.advance(poisoned, past: items[0].key, kind: .incremental, isLast: true)
        #expect(after.mark == items[0].key)
        #expect(IngestRun.plan(items, cursor: after, mode: .auto, limits: limits, now: now).items.isEmpty, "and from then on only new messages are fresh")
        #expect(IngestRun.plan([cand(1_789_495_000, "newer")] + items, cursor: after, mode: .auto, limits: limits, now: now).items.map(\.id) == ["newer"])
    }

    @Test func ordinaryMarksAreLeftAlone() {
        let fine = BucketCursor(bucket: BucketID("whatsapp:1"), source: "whatsapp", mark: ItemKey(order: 1_789_400_000, tiebreak: "seen"), floor: nil)
        #expect(IngestRun.plan([cand(1_789_490_000, "new"), cand(1_789_400_000, "seen")], cursor: fine, mode: .auto, limits: limits, now: now).items.map(\.id) == ["new"])
        let rowIDs = BucketCursor(bucket: BucketID("imessage:3"), source: "imessage", mark: ItemKey(rowID: 250_000), floor: nil)
        #expect(!IngestRun.isFutureDateKey(rowIDs.mark!, now: now), "Messages keys are row ids, never dates")
        #expect(IngestRun.isFutureDateKey(ItemKey(order: now.timeIntervalSince1970 + 2 * 86400), now: now))
        #expect(!IngestRun.isFutureDateKey(ItemKey(order: now.timeIntervalSince1970 + 3600), now: now), "an hour of clock skew is fine")
    }
}
