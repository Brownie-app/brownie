import Testing
import Foundation
@testable import Domain

/// The run's tallies: an item turned away at the date gate was never read, so it is neither "read" nor
/// "not worth keeping", and stats saved before the gate had its own count still decode.
@Suite struct RunStatsTests {
    @Test func aBadDatedItemHasItsOwnTallyAndIsNotRead() {
        var s = RunStats()
        s.record(.badDate); s.record(.kept); s.record(.modelDrop); s.record(.loadFailed)
        #expect(s.badDated == 1 && s.read == 3 && s.kept == 1 && s.dropped == 1 && s.failed == 1)
    }

    @Test func statsWrittenBeforeTheGateHadATallyDecodeWithItAtZero() throws {
        let old = #"{"read":4,"kept":1,"dropped":1,"sensitive":0,"failed":0,"deferred":2}"#
        let s = try JSONDecoder().decode(RunStats.self, from: Data(old.utf8))
        #expect(s.read == 4 && s.kept == 1 && s.dropped == 1 && s.deferred == 2 && s.badDated == 0)
        var fresh = RunStats(); fresh.record(.badDate); fresh.record(.kept)
        let back = try JSONDecoder().decode(RunStats.self, from: try JSONEncoder().encode(fresh))
        #expect(back == fresh, "round-trips with the new tally")
    }
}

/// "Read further back" resets a source's cursors, and its coverage must start over with them: the next run reads
/// the old window again, and adding that to the stored count would report every message twice.
@Suite struct CoverageForgettingTests {
    let june = Date(timeIntervalSince1970: 1_781_395_200), sept = Date(timeIntervalSince1970: 1_789_500_000)

    @Test func forgettingASourceLetsItsNextFirstReadEstablishTheCountAfresh() {
        let whatsapp = SourceCoverage(source: "whatsapp", oldestRead: june, newestRead: sept, itemsRead: 1_240, notRead: 0, lastRun: sept, buckets: 6)
        let files = SourceCoverage(source: "files", oldestRead: june, newestRead: sept, itemsRead: 12, notRead: 0, lastRun: sept, buckets: 2)
        let kept = SourceCoverage.forgetting("whatsapp", in: [whatsapp, files])
        #expect(kept == [files], "only the widened source is forgotten")
        // The wider first read reads the 1,240 again plus 200 older ones.
        let wider = SourceCoverage(source: "whatsapp", oldestRead: june.addingTimeInterval(-90 * 86_400), newestRead: sept, itemsRead: 1_440, notRead: 0, lastRun: sept, buckets: 6)
        let merged = SourceCoverage.merge(kept, with: wider)
        #expect(merged.first { $0.source == "whatsapp" }?.itemsRead == 1_440, "not 2,680")
        #expect(SourceCoverage.merge([whatsapp, files], with: wider).first { $0.source == "whatsapp" }?.itemsRead == 2_680, "which is what merging without forgetting would say")
        #expect(SourceCoverage.forgetting("whatsapp", in: [whatsapp]).isEmpty)
    }
}
