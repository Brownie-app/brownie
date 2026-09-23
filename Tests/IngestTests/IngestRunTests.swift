import Testing
import Foundation
@testable import Ingest
import Domain
import Platform
import Privacy
import Support

/// A source with a fixed list of items, newest-first, and a reader that answers from a table.
struct FixtureSource: Source {
    static let descriptor = SourceDescriptor(id: "fixture", name: "Fixture", detail: "", door: .localDatabase)
    let items: [Candidate]
    func availability() async -> Availability { .available }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        [Bucket(id: BucketID("fixture:a"), name: "A", items: items)]
    }
    func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "text for \(c.id)") }
}

actor TableReader: LocalModel {
    var loaded = false
    var calls = 0
    let answer: @Sendable (String) -> String
    init(_ answer: @escaping @Sendable (String) -> String) { self.answer = answer }
    var isLoaded: Bool { loaded }
    func load() async throws { loaded = true }
    func generate(_ r: GenerateRequest) async throws -> GenerateResult { calls += 1; return GenerateResult(text: answer(r.prompt), duration: 0) }
    func reload() async throws { loaded = true }
    func unload() async { loaded = false }
}

@Suite struct IngestRunTests {
    func item(_ n: Int) -> Candidate {
        Candidate(source: "fixture", bucket: BucketID("fixture:a"), key: ItemKey(order: Double(n), tiebreak: "i\(n)"), kind: .document, id: "i\(n)", itemDate: nil, metadata: ["name": "i\(n)"])
    }

    @Test func testInitialThenIncrementalNeverDuplicates() async throws {
        let store = try SQLiteRunStore.inMemory()
        let reader = TableReader { _ in #"{"summary":"The user kept this.","title":"Kept","keep":true}"# }
        let run = IngestRun(store: store, reader: reader, triage: try Triage(), policy: DefaultSensitivityPolicy())
        let runID = try await store.beginRun(trigger: .test, at: Date())

        // first run: 5 items, newest first
        let first = FixtureSource(items: (1...5).reversed().map(item))
        let s1 = try await run.read(first, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s1.read == 5); #expect(s1.kept == 5)
        let c1 = try await store.cursor(BucketID("fixture:a"))
        #expect(c1?.mark == item(5).key); #expect(c1?.floor == nil)

        // second run: two new items arrived
        let second = FixtureSource(items: (1...7).reversed().map(item))
        let s2 = try await run.read(second, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s2.read == 2)
        let all = try await store.summaries(since: nil)
        #expect(all.count == 7)
        let calls = await reader.calls
        #expect(calls == 7)
    }

    @Test func testResumeBelowFloorAfterInterruptedInitial() async throws {
        let store = try SQLiteRunStore.inMemory()
        let reader = TableReader { _ in #"{"summary":"ok","title":"t","keep":true}"# }
        var limits = IngestRun.Limits(); limits.initialPerBucket = 3
        let run = IngestRun(store: store, reader: reader, triage: try Triage(), policy: DefaultSensitivityPolicy(), limits: limits)
        let runID = try await store.beginRun(trigger: .test, at: Date())
        let src = FixtureSource(items: (1...5).reversed().map(item))
        let s1 = try await run.read(src, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s1.read == 3); #expect(s1.deferred == 2)
        let mid = try await store.cursor(BucketID("fixture:a"))
        #expect(mid?.floor == item(3).key, "floor is the oldest done so far")
        let s2 = try await run.read(src, enabledBuckets: nil, runID: runID, progress: { _ in })
        #expect(s2.read == 2, "resumes strictly below the floor")
        let done = try await store.cursor(BucketID("fixture:a"))
        #expect(done?.floor == nil); #expect(done?.mark == item(5).key)
    }

    @Test func testSensitiveLeavesNoTrace() async throws {
        let store = try SQLiteRunStore.inMemory()
        let reader = TableReader { _ in #"{"summary":"SSN 123-45-6789","title":"ID","keep":true}"# }
        let run = IngestRun(store: store, reader: reader, triage: try Triage(), policy: DefaultSensitivityPolicy())
        let runID = try await store.beginRun(trigger: .test, at: Date())
        var sawContent = false
        let s = try await run.read(FixtureSource(items: [item(1)]), enabledBuckets: nil, runID: runID) { p in if p.lastSummary != nil { sawContent = true } }
        #expect(s.sensitive == 1); #expect(!(sawContent))
        let remaining = try await store.summaries(since: nil)
        #expect(remaining.count == 0)
        let drops = try await store.drops(since: Date(timeIntervalSinceNow: -60))
        #expect(drops.first?.reason == .piiBackstop)
    }

    @Test func testParseFailsClosed() {
        #expect(Triage.parse("I cannot judge this") == nil)
        #expect(Triage.parse(#"garbage {"summary":"x","title":"y","keep":"yes"} trailing"#)?.keep == true)
        #expect(Triage.parse(#"{"summary":"x","title":"y","keep":true,}"#)?.summary == "x")
        #expect(Triage.parse(#"{"summary":"x","title":"y","keep":true,"sensitive":true}"#)?.sensitive == true)
    }
}
