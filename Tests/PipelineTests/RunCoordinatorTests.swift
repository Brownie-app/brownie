import Testing
import Foundation
import Domain
import Platform
import Knowledge
import Privacy
import Support
@testable import Pipeline

/// The judge sees a summary on the night the notes absorb it — never before, never twice — and the
/// rows the notes hold survive until the chain has finished with them.
@Suite struct RunCoordinatorTests {
    /// A plain brain (no tools): the builder's single-shot path writes one note per part, the judge finds
    /// nothing, the letter is a line. Any call can be told to hit a usage limit. Records the judge's inputs.
    final class Fake: Brain, @unchecked Sendable {
        let descriptor = BrainDescriptor(id: "fake", name: "Fake", capabilities: [.json], costLine: "")
        private let lock = NSLock()
        private var parts = 0
        private var inputs: [String] = []
        var failPart: Int?
        var failJudge = false
        func validate() async throws {}
        func complete(_ r: BrainRequest) async throws -> BrainResult {
            if r.schema?.contains("\"files\"") == true {
                let n: Int = lock.withLock { parts += 1; return parts }
                if n == failPart { throw BrainError.usageLimit(retryAfter: nil) }
                return BrainResult(text: "{\"files\":[{\"path\":\"Notes/part\(n).md\",\"content\":\"# part \(n)\"}]}", usage: Usage(inputTokens: 1, outputTokens: 1))
            }
            if r.schema?.contains("action_items") == true {
                if failJudge { throw BrainError.usageLimit(retryAfter: nil) }
                lock.withLock { inputs.append(r.input) }
                return BrainResult(text: #"{"action_items":[],"loops":[],"loop_updates":[]}"#, usage: Usage(inputTokens: 1, outputTokens: 1))
            }
            return BrainResult(text: "A letter.", usage: .zero)
        }
        var judged: [String] { lock.withLock { inputs } }
    }
    struct Reader: LocalModel {
        var isLoaded: Bool { true }
        func load() async throws {}
        func generate(_ r: GenerateRequest) async throws -> GenerateResult { throw LocalModelError.notLoaded }
        func reload() async throws {}
        func unload() async {}
    }

    // 2026-09-16 12:00 UTC, a Wednesday: no Sunday letter is due.
    static let today = Date(timeIntervalSince1970: 1_789_560_000)
    static let clock = FixedClock(today, timeZone: TimeZone(identifier: "UTC")!)

    struct World {
        let dir: URL, kb: FileKnowledgeStore, store: SQLiteRunStore
        func coordinator(_ brain: Fake) -> RunCoordinator {
            var deps = RunCoordinator.Dependencies(store: store, knowledge: kb, sources: [], reader: Reader(), brain: brain, policy: DefaultSensitivityPolicy(), clock: RunCoordinatorTests.clock)
            deps.diskHousekeeping = false
            return RunCoordinator(deps)
        }
        /// `n` kept summaries an hour apart inside the last day, each `bytes` long, titled "T<tag><i>".
        @discardableResult
        func seed(_ n: Int, bytes: Int = 120, tag: String) async throws -> [SummaryRecord] {
            let run = try await store.beginRun(trigger: .test, at: RunCoordinatorTests.today)
            let before = Set(try await store.summaries(since: nil).map(\.id))
            for i in 0..<n {
                let key = ItemKey(order: Double(1000 - i), tiebreak: "\(tag)\(i)")
                let c = Candidate(source: "fixture", bucket: BucketID("fixture:\(tag)"), key: key, kind: .document, id: "\(tag)\(i)", itemDate: RunCoordinatorTests.today.addingTimeInterval(-Double(i + 1) * 3600))
                let text = "Summary \(tag)\(i) " + String(repeating: "x", count: max(0, bytes - 12))
                try await store.commit(runID: run, cursor: BucketCursor(bucket: c.bucket, source: c.source, mark: key, floor: nil), bucketName: "Bucket \(tag)",
                                       candidate: c, outcome: Outcome(reason: .kept, survivor: Survivor(_unchecked: "T\(tag)\(i)", summary: text)), at: RunCoordinatorTests.today)
            }
            return try await store.summaries(since: nil).filter { !before.contains($0.id) }
        }
        func rows() async throws -> [SummaryRecord] { try await store.summaries(since: nil) }
    }
    static func world() throws -> World {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kb = try FileKnowledgeStore(root: dir.appendingPathComponent("KB", isDirectory: true), indexPath: dir.appendingPathComponent("index.sqlite").path)
        return World(dir: dir, kb: kb, store: try SQLiteRunStore.inMemory())
    }
    static func titles(_ tag: String, _ n: Int, in input: String) -> Int { (0..<n).filter { input.contains("T\(tag)\($0) — ") }.count }
    static func night(_ w: World, _ brain: Fake) async -> RunOutcome { await w.coordinator(brain).run(trigger: .test, onEvent: { _ in }) }

    @Test func theJudgeSeesRowsOnTheNightTheNotesAbsorbThemAndNeverAgain() async throws {
        let w = try Self.world()
        // Night 1: the sync hits a usage limit, so the thirty are planned and frozen but not in the notes.
        try await w.seed(30, tag: "a")
        let brain = Fake(); brain.failPart = 1
        #expect(await Self.night(w, brain) == .failedBrain(.usageLimit))
        #expect(brain.judged.isEmpty, "the judge did not run")
        let after1 = try await w.rows()
        #expect(after1.count == 30 && after1.allSatisfy { $0.mergedAt == nil })

        // Night 2: five new rows arrive. The sync resumes with the frozen thirty; the five wait for the next
        // sync — so the judge sees all thirty and none of the five.
        try await w.seed(5, tag: "b")
        brain.failPart = nil
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 1)
        #expect(Self.titles("a", 30, in: brain.judged[0]) == 30, "every row the notes now hold")
        #expect(Self.titles("b", 5, in: brain.judged[0]) == 0, "not one row the notes have not seen")
        let after2 = try await w.rows()
        #expect(after2.count == 5 && after2.allSatisfy { $0.mergedAt == nil }, "the judged rows are gone; the five wait")

        // Night 3: the five reach the notes and the judge — and the thirty are not judged a second time.
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 2)
        #expect(Self.titles("b", 5, in: brain.judged[1]) == 5 && Self.titles("a", 30, in: brain.judged[1]) == 0)
        #expect(try await w.rows().isEmpty)
    }

    @Test func finishMeasuresTheVaultAndPrunesTheStoreEvenOnAQuietNight() async throws {
        let w = try Self.world()
        try FileManager.default.createDirectory(at: w.kb.rootURL.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "# Priya\n\nA note.\n".write(to: w.kb.rootURL.appendingPathComponent("People/Priya.md"), atomically: true, encoding: .utf8)
        try await w.store.setValue(SettingKey.weekly("2026-W01"), "an old letter")
        try await w.store.setValue(SettingKey.weekly("2026-W36"), "last week's letter")
        #expect(await Self.night(w, Fake()) == .ran(cards: 0))
        let h = try #require(VaultHealth.latest(from: try await w.store.value(SettingKey.vaultHealth)))
        #expect(h.at == Self.today && h.notes >= 1 && h.notesPerFolder["People"] == 1, "measured at the clock's now, over the vault the run wrote")
        let old = try await w.store.value(SettingKey.weekly("2026-W01")), recent = try await w.store.value(SettingKey.weekly("2026-W36"))
        #expect(old == nil && recent != nil, "the store's retention ran")
    }

    @Test func aLoopThatLapsesTonightIsLetGoBeforeTheJudgeSeesIt() async throws {
        let w = try Self.world()
        try await w.seed(2, tag: "a")
        let old = Loop(id: "LETGO001-x", direction: .mine, person: "Karan", what: "send the villa share", quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: Self.today.addingTimeInterval(-91 * 86400))
        let young = Loop(id: "YOUNG001-x", direction: .mine, person: "Karan", what: "cricket tickets", quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: Self.today.addingTimeInterval(-10 * 86400))
        try await w.store.setValue(SettingKey.loops, String(data: try JSONEncoder().encode([old, young]), encoding: .utf8))
        let brain = Fake()
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 1)
        let input = brain.judged.first ?? ""
        #expect(input.contains("loop YOUNG001 · the user → Karan · cricket tickets · said WhatsApp"), "the loop with time left is handed over as open")
        #expect(!input.contains("loop LETGO001 · the user → Karan · send the villa share · said"), "the one that lapses tonight is not")
        #expect(input.contains("loop LETGO001 · the user → Karan · send the villa share · let go"), "it is listed as let go instead, so the judge neither reports it nor finds it again")
        let after = try JSONDecoder().decode([Loop].self, from: Data((try await w.store.value(SettingKey.loops) ?? "").utf8))
        #expect(after.first { $0.id == old.id }?.status == .lapsed && after.first { $0.id == old.id }?.lapsedAt == Self.today, "let go, dated tonight, before the judge ran")
        #expect(after.first { $0.id == young.id }?.status == .open)
    }

    @Test func mergedRowsSurviveAJudgeThatFailsAndAreJudgedTheNextNightEvenWithNothingNew() async throws {
        let w = try Self.world()
        try await w.seed(6, tag: "a")
        let brain = Fake(); brain.failJudge = true
        #expect(await Self.night(w, brain) == .failedBrain(.usageLimit))
        let kept = try await w.rows()
        #expect(kept.count == 6 && kept.allSatisfy { $0.mergedAt != nil }, "the notes have them, the judge has not — they stay")
        #expect(try await w.kb.note(at: "Notes/part1.md") != nil, "the notes went live")

        // A quiet night: nothing new was read, yet the six are owed a judgement.
        brain.failJudge = false
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 1 && Self.titles("a", 6, in: brain.judged[0]) == 6)
        #expect(try await w.rows().isEmpty, "judged, then deleted at FINISH")
        #expect(try await w.kb.note(at: "Notes/part2.md") == nil, "nothing was fed to the notes twice")

        // Another quiet night: nothing to sync, nothing to judge.
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 1)
    }
}
