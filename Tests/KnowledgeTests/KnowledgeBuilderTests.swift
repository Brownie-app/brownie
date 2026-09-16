import Testing
import Foundation
import Domain
import Platform
@testable import Knowledge

/// The builder feeds every summary exactly once, in the order things happened, and tells the brain what
/// day it is. A scripted brain plays the model: it writes files through the tools and does what each
/// test needs on a given call.
@Suite struct KnowledgeBuilderTests {
    /// An agentic brain driven by a script: call number in, tool calls out. Records every task it was given.
    final class ScriptedBrain: AgenticBrain, @unchecked Sendable {
        let descriptor = BrainDescriptor(id: "scripted", name: "Scripted", capabilities: [.json, .tools, .files], costLine: "")
        private let lock = NSLock()
        private var calls = 0
        private var tasks: [AgentTask] = []
        let script: @Sendable (Int, [Tool]) async throws -> Void
        init(_ script: @escaping @Sendable (Int, [Tool]) async throws -> Void) { self.script = script }
        func validate() async throws {}
        func complete(_ r: BrainRequest) async throws -> BrainResult { throw BrainError.badResponse("the scripted brain only runs with tools") }
        func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
            let n: Int = lock.withLock { calls += 1; tasks.append(task); return calls }
            try await script(n, tools)
            return AgentResult(finalText: "ok", usage: Usage(inputTokens: 10, outputTokens: 1), turns: 1)
        }
        var recorded: [AgentTask] { lock.withLock { tasks } }
    }

    static func call(_ tools: [Tool], _ name: String, _ args: [String: Any] = [:]) async throws -> String {
        let t = tools.first { $0.name == name }!
        return try await t.run(try JSONSerialization.data(withJSONObject: args)).text
    }
    static func write(_ tools: [Tool], _ path: String, _ content: String) async throws { _ = try await call(tools, "write_file", ["path": path, "content": content]) }

    // 2026-09-16 12:00 UTC, a Wednesday.
    static let today = Date(timeIntervalSince1970: 1_789_560_000)
    static let utc = TimeZone(identifier: "UTC")!
    static func day(_ d: Int) -> Date { Date(timeIntervalSince1970: 1_788_264_000 + Double(d) * 86400) }   // 2026-09-01 + d days, at noon UTC

    struct World {
        let dir: URL
        let kb: FileKnowledgeStore
        let store: SQLiteRunStore
        var live: URL { kb.rootURL }
        func builder(_ brain: any Brain, budget: Int = BrainLimits.corpusPartBudget, coverage: @escaping @Sendable () async -> String? = { nil }, people: @escaping @Sendable () async -> [Person] = { [] }) throws -> KnowledgeBuilder {
            try KnowledgeBuilder(brain: brain, store: kb, runStore: store, partBudget: budget, now: { KnowledgeBuilderTests.today }, timeZone: KnowledgeBuilderTests.utc, coverage: coverage, people: people)
        }
        func token() async throws -> KnowledgeBuilder.ResumeToken? {
            guard let s = try await store.value(SettingKey.kbResume) else { return nil }
            return try JSONDecoder().decode(KnowledgeBuilder.ResumeToken.self, from: Data(s.utf8))
        }
        func read(_ rel: String, in root: URL? = nil) -> String? { try? String(contentsOf: (root ?? live).appendingPathComponent(rel), encoding: .utf8) }
        func put(_ text: String, _ rel: String) throws {
            let u = live.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        /// `n` kept summaries, one per day from `from`, each about `bytes` long, committed as the reader would.
        @discardableResult
        func seed(_ n: Int, from: Int, bytes: Int = 120, tag: String = "a") async throws -> [SummaryRecord] {
            let run = try await store.beginRun(trigger: .test, at: KnowledgeBuilderTests.today)
            let before = Set(try await store.summaries(since: nil).map(\.id))
            for i in 0..<n {
                let key = ItemKey(order: Double(from + i), tiebreak: "\(tag)\(i)")
                let c = Candidate(source: "fixture", bucket: BucketID("fixture:\(tag)"), key: key, kind: .document, id: "\(tag)\(i)", itemDate: KnowledgeBuilderTests.day(from + i))
                let text = "Summary \(tag)\(i) " + String(repeating: "x", count: max(0, bytes - 12))
                try await store.commit(runID: run, cursor: BucketCursor(bucket: c.bucket, source: c.source, mark: key, floor: nil), bucketName: "Bucket \(tag)",
                                       candidate: c, outcome: Outcome(reason: .kept, survivor: Survivor(_unchecked: "T\(tag)\(i)", summary: text)), at: KnowledgeBuilderTests.today)
            }
            return try await store.summaries(since: nil).filter { !before.contains($0.id) }.sorted { $0.id < $1.id }
        }
    }

    static func world() throws -> World {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kb = try FileKnowledgeStore(root: dir.appendingPathComponent("KB", isDirectory: true), indexPath: dir.appendingPathComponent("index.sqlite").path)
        return World(dir: dir, kb: kb, store: try SQLiteRunStore.inMemory())
    }

    static func sids(in input: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "^#([0-9a-f]{12}) ", options: [.anchorsMatchLines])
        return re.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { String(input[Range($0.range(at: 1), in: input)!]) }
    }

    // MARK: (a) resume feeds exactly the frozen part, never what arrived since

    @Test func resumeFeedsTheFrozenPartAndNothingThatArrivedSince() async throws {
        let w = try Self.world()
        let first = try await w.seed(30, from: 0)
        let budget = 2000
        let planned = CorpusSlicer.plan(try await w.store.unmergedSummaries(), budget: budget, timeZone: Self.utc)
        #expect(planned.count == 3, "the fixture is sized for three parts")

        let brain = ScriptedBrain { n, tools in
            if n == 3 { throw BrainError.usageLimit(retryAfter: nil) }   // the night ends after part 2
            try await Self.write(tools, "Notes/part\(n).md", "# Part \(n)\nwritten on call \(n)")
        }
        await #expect(throws: BrainError.self) { try await w.builder(brain, budget: budget).sync(summaries: try await w.store.unmergedSummaries(), progress: { _ in }, onEvent: { _ in }) }
        let t = try #require(try await w.token())
        #expect(t.nextPart == 2 && t.parts.count == 3 && t.parts[2] == planned[2].map(\.id))
        let mergedSoFar = try await w.store.summaries(since: nil).filter { $0.mergedAt != nil }.map(\.id)
        #expect(Set(mergedSoFar) == Set(planned[0].map(\.id) + planned[1].map(\.id)), "parts 1 and 2 are marked the moment they land")

        // Forty more arrive: some older than everything, some newer.
        let late = try await w.seed(40, from: -20, tag: "b")
        #expect(late.count == 40)
        let unmerged = try await w.store.unmergedSummaries()
        #expect(unmerged.count == 40 + planned[2].count)
        _ = try await w.builder(brain, budget: budget).sync(summaries: unmerged, progress: { _ in }, onEvent: { _ in })

        let resumed = brain.recorded
        #expect(resumed.count == 4)
        let fed = Self.sids(in: resumed[3].input)
        #expect(fed == planned[2].map { $0.sid! }, "exactly the part-3 rows, in their planned order")
        #expect(Set(fed).isDisjoint(with: late.map { $0.sid! }))
        #expect(try await w.token() == nil)
        #expect(w.read("Notes/part1.md") != nil && w.read("Notes/part2.md") != nil && w.read("Notes/part4.md") != nil, "all three parts' notes are live")
        let leftover = try await w.store.unmergedSummaries().map(\.id)
        #expect(Set(leftover) == Set(late.map(\.id)), "the forty wait for the next sync")
        #expect(Set(first.map(\.id)).isSubset(of: Set(try await w.store.summaries(since: nil).filter { $0.mergedAt != nil }.map(\.id))))
    }

    // MARK: (b) a part that throws leaves staging as it was

    @Test func failedPartLeavesNoHalfWrittenNotes() async throws {
        let w = try Self.world()
        try await w.seed(20, from: 0)
        let brain = ScriptedBrain { n, tools in
            try await Self.write(tools, "Notes/call\(n).md", "# \(n)")
            if n == 2 { try await Self.write(tools, "Notes/half.md", "# half"); throw BrainError.timeout }
        }
        await #expect(throws: BrainError.self) { try await w.builder(brain, budget: 1500).sync(summaries: try await w.store.unmergedSummaries(), progress: { _ in }, onEvent: { _ in }) }
        let t = try #require(try await w.token())
        let staging = URL(fileURLWithPath: t.stagingPath)
        #expect(t.nextPart == 1)
        #expect(w.read("Notes/call1.md", in: staging) == "# 1", "part 1's work stays")
        #expect(w.read("Notes/call2.md", in: staging) == nil && w.read("Notes/half.md", in: staging) == nil, "part 2's writes are gone")
        #expect(!FileManager.default.fileExists(atPath: w.live.path), "nothing was swapped live")
        let orphans = try FileManager.default.contentsOfDirectory(atPath: w.dir.path).filter { $0.hasPrefix(".brownie-kb-snapshot-") }
        #expect(orphans.isEmpty, "the snapshot was folded back, not left behind")
    }

    // MARK: (c) merged rows are marked; deleteMerged removes only them

    @Test func mergedRowsAreMarkedAndOnlyTheyAreDeleted() async throws {
        let w = try Self.world()
        let rows = try await w.seed(5, from: 0)
        let brain = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# Portrait") }
        _ = try await w.builder(brain).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        let all = try await w.store.summaries(since: nil)
        #expect(all.count == 5 && all.allSatisfy { $0.mergedAt == Self.today }, "the builder marks, it does not delete")
        let later = try await w.seed(2, from: 10, tag: "c")
        try await w.store.deleteMerged()
        #expect(Set(try await w.store.summaries(since: nil).map(\.id)) == Set(later.map(\.id)))
        #expect(try await w.store.unmergedSummaries().map(\.id) == later.map(\.id))
    }

    @Test func storeMarksAndDeletesExactlyTheGivenIds() async throws {
        let w = try Self.world()
        let rows = try await w.seed(3, from: 0)
        try await w.store.markMerged(ids: [rows[0].id, rows[2].id], at: Self.today)
        #expect(try await w.store.unmergedSummaries().map(\.id) == [rows[1].id])
        try await w.store.deleteMerged()
        #expect(try await w.store.summaries(since: nil).map(\.id) == [rows[1].id])
        try await w.store.markMerged(ids: [], at: Self.today)
        #expect(try await w.store.summaries(since: nil).count == 1, "an empty list is a no-op")
    }

    @Test func unmergedSummariesComeOldestFirstByItemDateThenId() async throws {
        let w = try Self.world()
        let newer = try await w.seed(2, from: 5, tag: "n")
        let older = try await w.seed(2, from: 0, tag: "o")
        #expect(try await w.store.unmergedSummaries().map(\.id) == [older[0].id, older[1].id, newer[0].id, newer[1].id])
    }

    // MARK: (d) finish ends the loop

    @Test func finishEndsTheLoopEvenWhenTheBrainWouldKeepGoing() async throws {
        let w = try Self.world()
        let rows = try await w.seed(3, from: 0)
        let after = Counter()
        let brain = ScriptedBrain { _, tools in
            try await Self.write(tools, "README.md", "# Done before finish")
            _ = try await Self.call(tools, "finish", ["summary": "all written"])
            for i in 0..<500 {
                try Task.checkCancellation()   // a real brain stops at its next await once its task is cancelled
                try await Self.write(tools, "Notes/after\(i).md", "# should not land")
                await after.bump()
            }
        }
        let usage = try await w.builder(brain).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        #expect(usage == .zero, "a part ended by finish reports no usage")
        #expect(await after.count == 0)
        #expect(w.read("README.md") == "# Done before finish")
        #expect(try await w.token() == nil)
        #expect(try await w.store.unmergedSummaries().isEmpty, "the part counts as merged")
    }
    actor Counter { var count = 0; func bump() { count += 1 } }

    @Test func aCancelledRunThatDidNotFinishIsStillAFailure() async throws {
        let w = try Self.world()
        let rows = try await w.seed(3, from: 0)
        let brain = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# x"); throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await w.builder(brain).sync(summaries: rows, progress: { _ in }, onEvent: { _ in }) }
        #expect(try await w.store.unmergedSummaries().count == 3, "nothing is marked merged")
    }

    // MARK: (e) the header: Today, coverage, ISO dates, stable ids

    @Test func inputCarriesTodayCoverageAndIsoDates() async throws {
        let w = try Self.world()
        let rows = try await w.seed(3, from: 0)
        let brain = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# x") }
        _ = try await w.builder(brain, coverage: { "WhatsApp: 3 chats · read back to 2026-06-14\nGmail: 120 emails" }).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        let input = try #require(brain.recorded.first?.input)
        #expect(input.hasPrefix("Today: 2026-09-16 (Wednesday)\n"))
        #expect(input.contains("Coverage (how far back each source has been read):\n  WhatsApp: 3 chats · read back to 2026-06-14\n  Gmail: 120 emails\n"))
        #expect(input.contains("#\(rows[0].sid!) · [fixture/document] Bucket a · 2026-09-01\n"))
        #expect(input.contains("· 2026-09-03\n"))
        #expect(!input.contains("Sep 1,") && !input.contains("1 Sep"), "no locale dates")
        #expect(Self.sids(in: input) == rows.sorted { $0.effectiveDate < $1.effectiveDate }.map { $0.sid! }, "oldest first")
    }

    @Test func headerListsWhoExistsAndWhereTheyAreWritten() async throws {
        let w = try Self.world()
        let rows = try await w.seed(1, from: 0)
        let brain = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# x") }
        let t = Self.today
        let people = [Person(id: "p-1", name: "Kanika Pandey", aliases: ["Kanika Pandey Loadmill"], notePath: "People/Kanika Pandey.md", firstSeen: t, lastSeen: t),
                      Person(id: "p-2", name: "Nitesh", aliases: ["Nitesh (+919540752593)"], firstSeen: t, lastSeen: t)]
        _ = try await w.builder(brain, people: { people }).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        let input = try #require(brain.recorded.first?.input)
        #expect(input.contains("\nPEOPLE (one file per person; write about each only in the file listed, whatever spelling the summaries use):\n  Kanika Pandey — People/Kanika Pandey.md (also: Kanika Pandey Loadmill)\n  Nitesh — no note yet\n\nWorking directory:"))
        #expect(!input.contains("+919540752593"), "an alias is shown as a name, never as a number")
        let none = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# x") }
        _ = try await w.builder(none).sync(summaries: try await w.seed(1, from: 5, tag: "b"), progress: { _ in }, onEvent: { _ in })
        #expect(!(try #require(none.recorded.first?.input)).contains("PEOPLE"), "no registry, no roster")
    }

    @Test func headerSkipsCoverageWhenThereIsNone() async throws {
        let w = try Self.world()
        let rows = try await w.seed(1, from: 0)
        let brain = ScriptedBrain { _, tools in try await Self.write(tools, "README.md", "# x") }
        _ = try await w.builder(brain, coverage: { "  \n" }).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        let input = try #require(brain.recorded.first?.input)
        #expect(!input.contains("Coverage"))
        #expect(input.hasPrefix("Today: 2026-09-16 (Wednesday)\n\nWorking directory:"))
    }

    @Test func corpusLinesUseTheRowIdWhenThereIsNoStableId() {
        let s = SummaryRecord(id: 7, runID: 1, source: "gmail", bucket: BucketID("gmail"), bucketName: "Inbox", kind: .mail, title: "T", text: "body", itemDate: nil, createdAt: Self.today)
        #expect(CorpusSlicer.render(s, timeZone: Self.utc) == "#7 · [gmail/mail] Inbox · undated\nT — body\n")
        let dated = SummaryRecord(id: 8, runID: 1, source: "gmail", bucket: BucketID("gmail"), bucketName: "Inbox", kind: .mail, title: "T", text: "body", itemDate: Self.day(2), createdAt: Self.today, sid: "0123456789ab")
        #expect(CorpusSlicer.render(dated, timeZone: Self.utc).hasPrefix("#0123456789ab · [gmail/mail] Inbox · 2026-09-03\n"))
    }

    // MARK: build.md for every part of a first build, update.md after

    @Test func firstBuildUsesTheBuildPromptForEveryPart() async throws {
        let w = try Self.world()
        try await w.seed(30, from: 0)
        let brain = ScriptedBrain { n, tools in try await Self.write(tools, "Notes/p\(n).md", "# \(n)") }
        _ = try await w.builder(brain, budget: 2000).sync(summaries: try await w.store.unmergedSummaries(), progress: { _ in }, onEvent: { _ in })
        let tasks = brain.recorded
        #expect(tasks.count == 3)
        #expect(tasks.allSatisfy { $0.system.hasPrefix("You are building") && $0.effort == .high })
        // The next night the KB exists: every part is an update.
        try await w.seed(30, from: 40, tag: "u")
        _ = try await w.builder(brain, budget: 2000).sync(summaries: try await w.store.unmergedSummaries(), progress: { _ in }, onEvent: { _ in })
        #expect(brain.recorded.dropFirst(3).allSatisfy { $0.system.hasPrefix("You are updating") && $0.effort == .medium })
        #expect(brain.recorded.count == 6)
    }

    // MARK: a user's edit during the sync is kept, file by file

    @Test func userEditsDuringTheSyncSurviveAndTheRestIsTheBrains() async throws {
        let w = try Self.world()
        try w.put("# Me\nportrait", "README.md")
        try w.put("# A\nold", "People/A.md")
        try w.put("# D\nwill be deleted", "People/D.md")
        let rows = try await w.seed(2, from: 0)
        let brain = ScriptedBrain { _, tools in
            try await Self.write(tools, "People/A.md", "# A\nthe brain's A")
            try await Self.write(tools, "People/B.md", "# B\nthe brain's B")
            // Meanwhile the user edits A, adds C and deletes D in the live vault.
            try w.put("# A\nthe user's A, with more words than before", "People/A.md")
            try w.put("# C\nthe user's C", "People/C.md")
            try FileManager.default.removeItem(at: w.live.appendingPathComponent("People/D.md"))
        }
        _ = try await w.builder(brain).sync(summaries: rows, progress: { _ in }, onEvent: { _ in })
        #expect(w.read("People/A.md") == "# A\nthe user's A, with more words than before", "the user's edit wins")
        #expect(w.read("People/B.md") == "# B\nthe brain's B", "the brain's new note lands")
        #expect(w.read("People/C.md") == "# C\nthe user's C", "the user's new note survives the swap")
        #expect(w.read("People/D.md") == nil, "a note the user deleted and the brain left alone stays deleted")
        #expect(w.read("README.md") == "# Me\nportrait")
        #expect(try await w.token() == nil)
    }
}
