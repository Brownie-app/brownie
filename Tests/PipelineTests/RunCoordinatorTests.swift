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
        /// What the judge answers, when a test wants loops back rather than nothing.
        var judgeReply = #"{"action_items":[],"loops":[],"loop_updates":[]}"#
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
                return BrainResult(text: judgeReply, usage: Usage(inputTokens: 1, outputTokens: 1))
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
        func coordinator(_ brain: Fake, selfNames: [String] = []) -> RunCoordinator {
            var deps = RunCoordinator.Dependencies(store: store, knowledge: kb, sources: [], reader: Reader(), brain: brain, policy: DefaultSensitivityPolicy(), clock: RunCoordinatorTests.clock, selfNames: selfNames)
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
        #expect(after2.filter { $0.mergedAt == nil }.count == 5 && after2.filter { $0.judgedAt == Self.today }.count == 30 && after2.count == 35, "the judged rows stay as evidence, stamped; the five wait")

        // Night 3: the five reach the notes and the judge — and the thirty are not judged a second time.
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 2)
        #expect(Self.titles("b", 5, in: brain.judged[1]) == 5 && Self.titles("a", 30, in: brain.judged[1]) == 0)
        let after3 = try await w.rows()
        #expect(after3.count == 35 && !after3.contains(where: \.awaitsJudge), "every row is evidence now, none is owed to the judge")
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

    /// The night the user's vault went wrong, replayed: the judge reports sentiments as promises, the same promise once per
    /// side, a due as "September6" and a loop with the user as the other party. The ledger takes the deliverables only, once,
    /// dated — and the judge was told who the user is.
    @Test func newLoopsClearTheBarBeforeTheyEnterTheLedger() async throws {
        let w = try Self.world()
        try await w.seed(2, tag: "a")
        let brain = Fake()
        brain.judgeReply = #"""
        {"action_items":[],"loop_updates":[],"loops":[
          {"person":"Kanika Pandey","direction":"mine","what":"Build a company with Kanika","quote":"q","source":"WhatsApp · Fri","due":null,"dueISO":null,"owner":null},
          {"person":"Kanika Pandey","direction":"mine","what":"Focus on her network","quote":"q","source":"WhatsApp · Fri","due":null,"dueISO":null,"owner":null},
          {"person":"Kanika Pandey","direction":"theirs","what":"Provide her sister's number and email for Loopsy","quote":"q","source":"WhatsApp · Fri","due":null,"dueISO":null,"owner":null},
          {"person":"Kanika Pandey","direction":"mine","what":"Provide Vivek's sister's number and email for Loopsy","quote":"q","source":"WhatsApp · Fri","due":null,"dueISO":null,"owner":null},
          {"person":"Vivek Upreti","direction":"mine","what":"Close one more deal after SBI","quote":"q","source":"WhatsApp · Fri","due":null,"dueISO":null,"owner":null},
          {"person":"Arif","direction":"mine","what":"Send Arif the final proposal for comments on slides 6–11","quote":"q","source":"Mail · Tue","due":"September6","dueISO":null,"owner":null}
        ]}
        """#
        #expect(await w.coordinator(brain, selfNames: ["Vivek Upreti", "vivek"]).run(trigger: .test, onEvent: { _ in }) == .ran(cards: 0))
        #expect(brain.judged.first?.contains("THE USER IS Vivek Upreti (also written vivek).") == true, "the judge is told who the user is")
        let ledger = try JSONDecoder().decode([Loop].self, from: Data((try await w.store.value(SettingKey.loops) ?? "").utf8))
        #expect(ledger.map(\.what) == ["Provide her sister's number and email for Loopsy", "Send Arif the final proposal for comments on slides 6–11"], "two deliverables, the mirror folded, the sentiments and the user's own loop gone")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.clock.timeZone
        #expect(ledger.last?.due == "September6" && ledger.last?.dueDate == cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9)), "the words stay; the date is read from them")
        let registry = PersonRegistry(vault: w.kb.rootURL); await registry.load()
        #expect(await registry.people().map(\.name).sorted() == ["Arif", "Kanika Pandey"], "no record was opened for the user")
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
        let stamped = try await w.rows()
        #expect(stamped.count == 6 && !stamped.contains(where: \.awaitsJudge), "judged, then stamped at FINISH — kept as evidence, owed to nobody")
        #expect(try await w.kb.note(at: "Notes/part2.md") == nil, "nothing was fed to the notes twice")

        // Another quiet night: nothing to sync, nothing to judge.
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(brain.judged.count == 1)
    }

    /// A People note with Brownie's front-matter, in shape, last written on `updated`.
    static func putNote(_ rel: String, body: String, updated: String, in w: World) throws {
        var m = NoteMeta.fresh(path: rel, body: body, today: updated); m.updated = updated
        let u = w.kb.rootURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (m.render() + body).write(to: u, atomically: true, encoding: .utf8)
    }
    static func body(_ rel: String, in w: World) throws -> String { NoteMeta.parse(try String(contentsOf: w.kb.rootURL.appendingPathComponent(rel), encoding: .utf8), path: rel).body }

    /// The lines that retire from a status block are kept in the note the registry routed the block to — never re-derived
    /// from a title: a promise under a bare first name two people share lands in neither note, and an ask under a chat
    /// name the registry ties by handle to another spelling keeps its trace in that person's note.
    @Test func retiredLinesFollowTheRegistrysRoutingNotTheTitle() async throws {
        let w = try Self.world()
        try await w.seed(1, tag: "a")
        for t in ["Arjun Mehta", "Arjun Rao", "Kanika Pandey"] { try Self.putNote("People/\(t).md", body: "# \(t)\n\n## About\n- x\n", updated: "2026-09-01", in: w) }
        let registry = PersonRegistry(vault: w.kb.rootURL, now: { Self.today })
        for t in ["Arjun Mehta", "Arjun Rao"] { let id = await registry.register(label: t, handle: nil); await registry.setNotePath("People/\(t).md", for: id) }
        let kp = await registry.register(label: "Kanika Pandey", handle: "whatsapp:+3"); await registry.register(label: "KP Loadmill", handle: "whatsapp:+3")
        await registry.setNotePath("People/Kanika Pandey.md", for: kp)
        try await registry.save()
        let day = 86400.0
        let promise = Loop(id: "BOOK0001-x", direction: .mine, person: "Arjun", what: "send the book", quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, status: .closed,
                           openedAt: Self.today.addingTimeInterval(-30 * day), closedAt: Self.today.addingTimeInterval(-14.5 * day), closedHow: "you replied", closedBy: "reply")
        try await w.store.setValue(SettingKey.loops, String(data: try JSONEncoder().encode([promise]), encoding: .utf8))
        let lunch = Ask(id: "lunch", person: "KP Loadmill", bucket: BucketID("w:3"), askedAt: Self.today.addingTimeInterval(-20 * day), question: "lunch?",
                        answeredAt: Self.today.addingTimeInterval(-14.5 * day), reply: "yes", addressed: true, handle: "whatsapp:+3")
        try await w.store.setValue(SettingKey.asks, String(data: try JSONEncoder().encode([lunch]), encoding: .utf8))
        #expect(await Self.night(w, Fake()) == .ran(cards: 0))
        let mehta = try Self.body("People/Arjun Mehta.md", in: w), rao = try Self.body("People/Arjun Rao.md", in: w), kanika = try Self.body("People/Kanika Pandey.md", in: w)
        #expect(!mehta.contains("send the book") && !rao.contains("send the book"), "two Arjuns: the registry pins the promise on neither, so neither note keeps a promise one of them never received")
        #expect(kanika.contains("- 2026-09 — they asked: “lunch?” — you replied 2 Sep 00:00"), "routed by handle under another chat name: the trace lands where the block was")
    }

    /// Asked on WhatsApp, answered on Slack: the judge is handed the open ask by id, says in `ask_updates` that the summaries
    /// show it answered elsewhere, and the ask closes tonight — the note says so, the loop it came from goes with it, and
    /// the judge's word the night after changes nothing, nor can it reopen one.
    @Test func anAskTheJudgeSeesAnsweredElsewhereClosesWithItsLoop() async throws {
        let w = try Self.world()
        try await w.seed(1, tag: "a")
        try Self.putNote("People/Nitesh.md", body: "# Nitesh\n\n## About\n- x\n", updated: "2026-09-01", in: w)
        let registry = PersonRegistry(vault: w.kb.rootURL, now: { Self.today })
        let id = await registry.register(label: "Nitesh", handle: "whatsapp:+919540752593"); await registry.setNotePath("People/Nitesh.md", for: id)
        try await registry.save()
        let day = 86400.0
        let ask = Ask(id: "ask-a1b2c3d4e5f6", person: "Nitesh", bucket: BucketID("whatsapp:507"), askedAt: Self.today.addingTimeInterval(-2 * day), question: "postgres ka url kaise milega?", handle: "whatsapp:+919540752593",
                      window: [AskLine(at: Self.today.addingTimeInterval(-2 * day + 60), mine: false, text: "urgent hai")])
        let settled = Ask(id: "ask-ffff000011112222", person: "Nitesh", bucket: BucketID("whatsapp:507"), askedAt: Self.today.addingTimeInterval(-3 * day), question: "beer?", answeredAt: Self.today.addingTimeInterval(-3 * day + 600), reply: "sure", addressed: true, handle: "whatsapp:+919540752593", outcome: .answered, outcomeAt: Self.today.addingTimeInterval(-3 * day + 600), outcomeBy: "rules")
        try await w.store.setValue(SettingKey.asks, String(data: try JSONEncoder().encode([ask, settled]), encoding: .utf8))
        let loop = Loop(id: "URL00001-x", direction: .mine, person: "Nitesh", what: "Send Nitesh the postgres url", quote: "q", sourceLabel: "WhatsApp · Mon", due: nil, openedAt: Self.today.addingTimeInterval(-day))
        let other = Loop(id: "DECK0001-x", direction: .mine, person: "Nitesh", what: "Send Nitesh the deck", quote: "q", sourceLabel: "WhatsApp · Mon", due: nil, openedAt: Self.today.addingTimeInterval(-day))
        try await w.store.setValue(SettingKey.loops, String(data: try JSONEncoder().encode([loop, other]), encoding: .utf8))
        let brain = Fake()
        brain.judgeReply = #"{"action_items":[],"loops":[],"loop_updates":[],"ask_updates":[{"askID":"ask-a1b2c3d4e5f6","status":"answered","how":"on Slack"},{"askID":"ask-ffff000011112222","status":"open","how":"never mind"}]}"#
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        let input = try #require(brain.judged.first)
        #expect(input.contains("- ask ask-a1b2c3d4e5f6 · Nitesh asked the user something on") && input.contains("NO REPLY YET (2 days ago)"), "the open ask is handed over by id")
        #expect(!input.contains("- ask ask-ffff") && input.contains("the user replied") && !input.contains("kaise milega") && !input.contains("beer"), "the settled one without, and never the words")
        #expect(input.contains("ask_updates"), "and the judge is told what to do with it")
        let asks = RunCoordinator.loadAsks(try await w.store.value(SettingKey.asks))
        let closed = try #require(asks.first { $0.id == ask.id })
        #expect(closed.outcome == .answered && closed.outcomeBy == "judge" && closed.outcomeHow == "on Slack" && closed.outcomeAt == Self.today && closed.answeredAt == Self.today && closed.addressed == true && !closed.isOpen, "closed tonight, by the judge's word")
        #expect(asks.first { $0.id == settled.id } == settled, "the judge's 'open' touches nothing")
        let note = try Self.body("People/Nitesh.md", in: w)
        #expect(note.contains("- ✅ 14 Sep — they asked: “postgres ka url kaise milega?” — answered on Slack, 16 Sep (the judge)"), "the note says where")
        let ledger = try JSONDecoder().decode([Loop].self, from: Data((try await w.store.value(SettingKey.loops) ?? "").utf8))
        let followed = try #require(ledger.first { $0.id == loop.id })
        #expect(followed.status == .closed && followed.closedBy == "ask" && followed.closedHow == "the ask it came from was answered" && followed.closedAt == Self.today, "the loop about the very thing asked for goes with it")
        #expect(ledger.first { $0.id == other.id }?.status == .open, "the other deliverable stays")
        #expect(note.contains("- ✅ you promised (15 Sep): Send Nitesh the postgres url — done 16 Sep (the ask it came from was answered)"))

        // the night after: the judge repeats itself, and nothing moves
        #expect(await Self.night(w, brain) == .ran(cards: 0))
        #expect(RunCoordinator.loadAsks(try await w.store.value(SettingKey.asks)).first { $0.id == ask.id } == closed)
    }

    /// The same name on two chats, not yet answered: an ask from the Slack handle lands in the Slack record's note and never in
    /// the WhatsApp namesake's; a promise under the bare name, with both notes on file, lands in neither. The night saves the
    /// pending pair as the first question for the banner.
    @Test func anAskFromTheSecondChatLandsInItsOwnNoteNotTheNamesakes() async throws {
        let w = try Self.world()
        try await w.seed(1, tag: "a")
        try Self.putNote("People/Nitesh Kumar.md", body: "# Nitesh Kumar\n\n## About\n- on WhatsApp\n", updated: "2026-09-01", in: w)
        try Self.putNote("People/Nitesh Kumar (Slack).md", body: "# Nitesh Kumar (Slack)\n\n## About\n- on Slack\n", updated: "2026-09-01", in: w)
        let registry = PersonRegistry(vault: w.kb.rootURL, now: { Self.today })
        let wa = await registry.register(label: "Nitesh Kumar", handle: "whatsapp:+919540752593")
        await registry.setNotePath("People/Nitesh Kumar.md", for: wa)
        let sl = await registry.register(label: "Nitesh Kumar", handle: "slack:U1")
        let pending = await registry.person(sl)?.pending
        #expect(sl != wa && pending == [wa], "the name alone did not join them")
        try await registry.save()
        let day = 86400.0
        let deck = Ask(id: "deck", person: "Nitesh Kumar", bucket: BucketID("slack:U1"), askedAt: Self.today.addingTimeInterval(-2 * day), question: "deck?", handle: "slack:U1")
        let lunch = Ask(id: "lunch", person: "Nitesh Kumar", bucket: BucketID("w:1"), askedAt: Self.today.addingTimeInterval(-3 * day), question: "lunch?", handle: "whatsapp:+919540752593")
        try await w.store.setValue(SettingKey.asks, String(data: try JSONEncoder().encode([deck, lunch]), encoding: .utf8))
        let promise = Loop(id: "BOOK0001-x", direction: .mine, person: "Nitesh Kumar", what: "send the book", quote: "q", sourceLabel: "Slack · Fri", due: nil, openedAt: Self.today.addingTimeInterval(-1 * day))
        try await w.store.setValue(SettingKey.loops, String(data: try JSONEncoder().encode([promise]), encoding: .utf8))
        #expect(await Self.night(w, Fake()) == .ran(cards: 0))
        let whatsapp = try Self.body("People/Nitesh Kumar.md", in: w), slack = try Self.body("People/Nitesh Kumar (Slack).md", in: w)
        #expect(slack.contains("deck?") && !slack.contains("lunch?"), "the Slack ask is in the Slack note: \(slack)")
        #expect(whatsapp.contains("lunch?") && !whatsapp.contains("deck?"), "the WhatsApp ask is in the WhatsApp note, and the Slack one never crossed: \(whatsapp)")
        #expect(!whatsapp.contains("send the book") && !slack.contains("send the book"), "a promise under the bare name, two notes on file: pinned on neither")
        let after = PersonRegistry(vault: w.kb.rootURL, now: { Self.today }); await after.load()
        let (people, slackPath, pairs) = (await after.people().count, await after.notePath(for: sl), await after.suspects())
        #expect(people == 2 && slackPath == "People/Nitesh Kumar (Slack).md", "the Slack note is his; no third record was opened")
        #expect(pairs.count == 1 && Set([pairs[0].0.id, pairs[0].1.id]) == [wa, sl] && PeopleQuestion.isPending(pairs[0]))
        let stored = try JSONDecoder().decode([[String]].self, from: Data((try await w.store.value(SettingKey.duplicatePeople) ?? "").utf8))
        #expect(stored.count == 1 && Set(stored[0]) == [wa, sl], "the question is saved for the banner")
    }

    /// The address book comes first in the night's registry work: a pending pair whose two fall on one card is one person
    /// before the status blocks are written, so both asks land in the one note.
    @Test func contactsAreLinkedBeforeTheNightWritesAnyone() async throws {
        let w = try Self.world()
        try await w.seed(1, tag: "a")
        try Self.putNote("People/Nitesh Kumar.md", body: "# Nitesh Kumar\n\n## About\n- x\n", updated: "2026-09-01", in: w)
        let registry = PersonRegistry(vault: w.kb.rootURL, now: { Self.today })
        let wa = await registry.register(label: "Nitesh Kumar", handle: "whatsapp:+919540752593")
        await registry.setNotePath("People/Nitesh Kumar.md", for: wa)
        let sl = await registry.register(label: "Nitesh Kumar", handle: "slack:U1", proofs: ["email:nitesh@loopsy.in"])
        try await registry.save()
        let day = 86400.0
        let deck = Ask(id: "deck", person: "Nitesh Kumar", bucket: BucketID("slack:U1"), askedAt: Self.today.addingTimeInterval(-2 * day), question: "deck?", handle: "slack:U1")
        try await w.store.setValue(SettingKey.asks, String(data: try JSONEncoder().encode([deck]), encoding: .utf8))
        var deps = RunCoordinator.Dependencies(store: w.store, knowledge: w.kb, sources: [], reader: Reader(), brain: Fake(), policy: DefaultSensitivityPolicy(), clock: Self.clock,
                                                contacts: { [ContactCard(name: "Nitesh Kumar", phones: ["+91 95407 52593"], emails: ["nitesh@loopsy.in"])] })
        deps.diskHousekeeping = false
        #expect(await RunCoordinator(deps).run(trigger: .test, onEvent: { _ in }) == .ran(cards: 0))
        #expect(try Self.body("People/Nitesh Kumar.md", in: w).contains("deck?"), "one card, one person: the Slack ask is in his note")
        let after = PersonRegistry(vault: w.kb.rootURL, now: { Self.today }); await after.load()
        let (people, kept, gone, pairs) = (await after.people().count, await after.person(wa), await after.person(sl), await after.suspects())
        #expect(people == 1 && gone == nil && kept?.handles == ["whatsapp:+919540752593", "slack:U1"] && kept?.pending == [] && pairs.isEmpty)
    }

    /// Tonight's mentions carry the chat's handle: a summary has none of its own, but the ask ledger knows the chat's.
    @Test func mentionsCarryTheChatsHandleFromTheAskLedger() {
        let bucket = BucketID("w:9")
        let summary = SummaryRecord(id: 1, runID: 1, source: SourceID("whatsapp"), bucket: bucket, bucketName: "+91 98765 43210", kind: .directMessage, title: "t", text: "x", itemDate: nil, createdAt: Self.today)
        let old = Ask(id: "old", person: "+91 98765 43210", bucket: bucket, askedAt: Self.today.addingTimeInterval(-40 * 86400), question: "q", answeredAt: Self.today.addingTimeInterval(-39 * 86400), addressed: true, handle: "whatsapp:+919876543210")
        let open = Ask(id: "open", person: "Meera", bucket: BucketID("w:2"), askedAt: Self.today, question: "q", handle: "whatsapp:+2")
        let loop = Loop(id: "L", direction: .mine, person: "Karan", what: "x", quote: "q", sourceLabel: "s", due: nil, openedAt: Self.today)
        let m = RunCoordinator.mentions(summaries: [summary], asks: [old, open], loops: [loop])
        #expect(m == [NoteArchive.Mention("+91 98765 43210", handle: "whatsapp:+919876543210"), NoteArchive.Mention("Meera", handle: "whatsapp:+2"), NoteArchive.Mention("Karan")],
                "the summary's chat by the handle a settled ask left behind; the open ask by its own; the loop by name")
    }

    /// A shared group chat's note is the household's: however quiet, the night never archives it — the sync would take an
    /// archived note off the shared folder for everyone, and the other Mac would bring it back beside the archived copy.
    @Test func aHouseholdSharedGroupNoteIsNeverArchived() async throws {
        let w = try Self.world()
        try await w.seed(1, tag: "a")
        try Self.putNote("Groups/Building Chat.md", body: "# Building Chat\n\n## About\n- the building\n", updated: "2026-01-01", in: w)
        try Self.putNote("Groups/Old Club.md", body: "# Old Club\n\n## About\n- the club\n", updated: "2026-01-01", in: w)
        let shared = w.dir.appendingPathComponent("Shared", isDirectory: true)
        let h = Household(members: [HouseholdMember(name: "Vivek", isMe: true), HouseholdMember(name: "Priya", isMe: false)], folderPath: shared.path, sharedBuckets: ["whatsapp:building"], since: Self.today)
        try await w.store.setValue(SettingKey.household, String(data: try JSONEncoder().encode(h), encoding: .utf8))
        try await w.store.setValue(SettingKey.householdBucketNames, #"{"whatsapp:building":"Building Chat"}"#)
        #expect(await Self.night(w, Fake()) == .ran(cards: 0))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: w.kb.rootURL.appendingPathComponent("Groups/Building Chat.md").path) && !fm.fileExists(atPath: w.kb.rootURL.appendingPathComponent("Groups/Archive/Building Chat.md").path), "shared: stays")
        #expect(fm.fileExists(atPath: w.kb.rootURL.appendingPathComponent("Groups/Archive/Old Club.md").path), "the other quiet group goes")
        #expect(fm.fileExists(atPath: shared.appendingPathComponent("Groups/Building Chat.md").path), "and it went out to the household")
    }
}
