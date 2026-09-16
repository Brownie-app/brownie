import Foundation
import Domain
import Ingest
import Knowledge
import Proactive
import Support

/// One run, end to end: read (on-device) → synthesise (brain) → judge → prepare → finish.
/// Only one run at a time. A failed cloud stage keeps the summaries for the next run.
public actor RunCoordinator {
    public struct Dependencies: Sendable {
        public var store: any RunStore
        public var knowledge: any KnowledgeStore
        public var sources: [any Source]
        public var reader: (any LocalModel)?
        public var brain: (any Brain)?
        public var policy: any SensitivityPolicy
        public var clock: Clock
        public var calendarText: @Sendable () async -> String?
        /// Names the stage about to talk to the brain, for the "What left your Mac" log.
        public var stage: @Sendable (_ purpose: String, _ detail: String) -> Void
        /// FINISH also tidies what lives outside the store — the transcript cache and the log files, at their real paths;
        /// tests run against their own folders and turn this off.
        public var diskHousekeeping = true
        public init(store: any RunStore, knowledge: any KnowledgeStore, sources: [any Source], reader: (any LocalModel)?, brain: (any Brain)?,
                    policy: any SensitivityPolicy, clock: Clock = SystemClock(), calendarText: @escaping @Sendable () async -> String? = { nil },
                    stage: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
            self.store = store; self.knowledge = knowledge; self.sources = sources; self.reader = reader; self.brain = brain
            self.policy = policy; self.clock = clock; self.calendarText = calendarText; self.stage = stage
        }
    }

    public enum Event: Sendable { case progress(RunProgress), thought(String), finished(RunOutcome) }

    private let deps: Dependencies
    private let log = Log("run")
    private var current: Task<RunOutcome, Never>?
    public private(set) var isRunning = false

    public init(_ deps: Dependencies) { self.deps = deps }

    public func cancel() { current?.cancel() }

    /// Starts a run if none is active. Returns the outcome when done.
    @discardableResult
    public func run(trigger: RunTrigger, onEvent: @escaping @Sendable (Event) -> Void) async -> RunOutcome {
        if let current { return await current.value }
        isRunning = true
        let task = Task { await self.perform(trigger: trigger, onEvent: onEvent) }
        current = task
        let outcome = await task.value
        current = nil; isRunning = false
        onEvent(.finished(outcome))
        return outcome
    }

    private func perform(trigger: RunTrigger, onEvent: @escaping @Sendable (Event) -> Void) async -> RunOutcome {
        let store = deps.store
        let started = deps.clock.now()
        var stats = RunStats()
        var skipped: [String] = []
        var readable = 0
        var outcome: RunOutcome = .cancelled
        let runID: Int64
        do { runID = try await store.beginRun(trigger: trigger, at: started) } catch { log.error("beginRun: \(error)"); return .failedReader("store") }
        try? await store.setValue("run.lastError", nil)
        log.info("run #\(runID) \(trigger.rawValue) started")

        do {
            // 1. READ (on-device)
            if let reader = deps.reader, !deps.sources.isEmpty {
                let triage = try Triage()
                let ingest = IngestRun(store: store, reader: reader, triage: triage, policy: deps.policy, clock: deps.clock)
                if !(await reader.isLoaded) { try await reader.load() }
                var coverage = SourceCoverage.decode(try? await store.value(SettingKey.coverage))
                for source in deps.sources {
                    if Task.isCancelled { throw CancellationError() }
                    // A source that can't be read is skipped with a reason — it never kills the run.
                    let availability = await source.availability()
                    guard availability == .available else {
                        skipped.append("\(source.descriptor.name): \(Self.describe(availability))"); continue
                    }
                    let enabled = try await enabledBuckets(for: source, store: store)
                    let base = stats
                    readable += 1
                    do {
                        let s = try await ingest.read(source, enabledBuckets: enabled, runID: runID) { p in
                            var p = p; p.stats = base + p.stats
                            onEvent(.progress(p))
                        }
                        stats = stats + s
                        if let c = await ingest.coverage(of: source.id) { coverage = SourceCoverage.merge(coverage, with: c); try? await store.setValue(SettingKey.coverage, SourceCoverage.encode(coverage)) }
                    } catch is CancellationError { throw CancellationError() }
                    catch IngestRun.Failure.cancelled { throw IngestRun.Failure.cancelled }
                    catch IngestRun.Failure.readerStuck { throw IngestRun.Failure.readerStuck }
                    catch {
                        log.warn("\(source.descriptor.name) failed: \(error)")
                        skipped.append("\(source.descriptor.name): couldn't be read (\(Self.short(error)))")
                    }
                }
                // Asks in direct chats, judged on-device while the reader is up: did the user's reply actually answer?
                await Self.scanAsks(deps: deps, store: store, reader: reader, log: log)
                await reader.unload()
            }

            // 2–4. CLOUD
            // Only summaries the notes have not absorbed yet, oldest first; a resumed sync feeds the ids it froze.
            let summaries = try await store.unmergedSummaries()
            let weekAgo = deps.clock.now().addingTimeInterval(-7 * 86400)
            // Rows the notes already hold are kept until FINISH, so a night whose chain broke after the sync
            // still has them judged the next night — even one on which nothing new was read.
            let unjudged = try await store.summaries(since: weekAgo).contains { $0.mergedAt != nil }
            if let brain = deps.brain, !summaries.isEmpty || unjudged {
                // Who exists, from the People notes and every earlier run: the brain is told, so it writes each person in one file.
                let registry = PersonRegistry(vault: deps.knowledge.rootURL, now: { [clock = deps.clock] in clock.now() })
                await registry.load()
                // Anyone tonight's summaries, open asks or open loops name comes back from Archive/ before the brain writes, so it finds their one file where it expects it.
                let mentioned = summaries.map(\.bucketName) + Self.loadAsks(try await store.value(SettingKey.asks)).filter(\.isOpen).map(\.person) + (await LoopLedger.load(store)).filter { $0.status == .open }.map(\.person)
                await NoteArchive.unarchive(root: deps.knowledge.rootURL, registry: registry, mentioned: mentioned)
                await registry.seed(from: (try? await deps.knowledge.folders()) ?? [])
                var usage = Usage.zero
                if !summaries.isEmpty {
                    onEvent(.progress(RunProgress(stage: .synthesising, stats: stats)))
                    deps.stage("Update your notes", "\(summaries.count) summaries and the notes they touch")
                    let builder = try KnowledgeBuilder(brain: brain, store: deps.knowledge, runStore: store, now: { [clock = deps.clock] in clock.now() }, timeZone: deps.clock.timeZone,
                                                       coverage: { [tz = deps.clock.timeZone] in let all = SourceCoverage.decode(try? await store.value(SettingKey.coverage)); return all.isEmpty ? nil : CoverageLine.render(all, timeZone: tz) },
                                                       people: { await registry.people() })
                    let readStats = stats
                    usage = try await builder.sync(summaries: summaries, progress: { p in var p = p; p.stats = readStats; onEvent(.progress(p)) }, onEvent: { e in if case .message(let m) = e { onEvent(.thought(m)) } })
                }
                // The judge and the preparer see only what the notes hold: the rows merged tonight, or on an
                // earlier night whose chain broke before the judge. A row that arrived since and waits for the
                // next sync is not judged before the notes know it — and never twice, as merged rows go at FINISH.
                let recent = try await store.summaries(since: weekAgo).filter { $0.mergedAt != nil }

                // welcome letter, once
                if (try await store.value(SettingKey.letter) ?? "").isEmpty, let readme = try await deps.knowledge.note(at: "README.md") {
                    do {
                        deps.stage("Write the welcome letter", "your README and the night's numbers")
                        let (letter, u) = try await LetterWriter(brain: brain).write(readme: readme.body, numbers: "\(stats.read) read, \(stats.kept) kept, \(stats.sensitive) erased on sight")
                        try await store.setValue(SettingKey.letter, letter); usage = usage + u
                    } catch { log.warn("letter not written this run: \(error)") }
                }

                onEvent(.progress(RunProgress(stage: .judging, stats: stats)))
                let typed = try await store.value(SettingKey.standingInstructions) ?? ""
                let feedback = Self.loadFeedback(try await store.value(SettingKey.feedback))
                let learned = FeedbackDigest.instructions(feedback, now: deps.clock.now())
                // What the user typed, then what their thumbs-downs taught.
                let instructions = [typed, learned].filter { !$0.isEmpty }.joined(separator: "\n")
                let max = Int(try await store.value(SettingKey.cardsPerMorning) ?? "5") ?? 5
                // A loop that has waited its full term is let go now, before the judge sees the ledger: handed over as
                // open, it would come back with an item, be let go in the merge, and still get a card in the morning.
                var ledger = await LoopLedger.load(store)
                let letGo = StatusRules.lapse(loops: ledger, now: deps.clock.now())
                if letGo != ledger { log.info("\(zip(ledger, letGo).filter { $0.status != $1.status }.count) loop(s) let go for want of news"); ledger = letGo; await LoopLedger.save(ledger, store) }
                let openLoops = ledger.filter { $0.status == .open }
                let cal = await deps.calendarText()
                deps.stage("Judge what matters", "\(recent.count) summaries from the last 7 days\(cal == nil ? "" : ", the calendar for 8 days"), \(openLoops.count) open loops")
                let household = Self.loadHousehold(try await store.value(SettingKey.household))
                // Asks were scanned (and judged on-device) in the read phase; without a reader they are scanned here, unjudged.
                if deps.reader == nil { await Self.scanAsks(deps: deps, store: store, reader: nil, log: log) }
                let asks = Self.loadAsks(try await store.value(SettingKey.asks))
                let settled = AskLedger.closures(loops: openLoops, asks: asks, now: deps.clock.now())
                if settled != openLoops { var all = await LoopLedger.load(store); for l in settled where l.status == .closed { if let i = all.firstIndex(where: { $0.id == l.id }) { all[i] = l } }; await LoopLedger.save(all, store); log.info("\(settled.filter { $0.status == .closed }.count) loop(s) closed by the user's own replies") }
                let openNow = settled.filter { $0.status == .open }
                let (findings, u1) = try await Judge(brain: brain, clock: deps.clock).judge(summaries: recent, calendar: cal, instructions: instructions, openLoops: openNow, max: 8, household: household, asks: AskLedger.judgeLines(asks, loops: ledger, now: deps.clock.now()))
                usage = usage + u1
                // Promises said out loud: parsed from transcript summaries, deterministically, so none is missed.
                let spoken = recent.filter { $0.kind == .transcript }.flatMap { TranscriptPromises.parse(summary: $0.text, recording: $0.title.isEmpty ? $0.bucketName : $0.title, date: $0.itemDate ?? $0.createdAt, now: deps.clock.now()) }
                if !spoken.isEmpty { deps.stage("Promises said out loud", "\(spoken.count) from \(recent.filter { $0.kind == .transcript }.count) recording(s)"); log.info("\(spoken.count) spoken promise(s) found") }
                let already = await LoopLedger.load(store)
                let newSpoken = spoken.filter { f in !already.contains { $0.id == f.loop.id || ($0.status == .open && LoopLedger.same($0, f.loop)) } }
                let candidates = findings.items + TranscriptPromises.candidates(newSpoken)
                let allLoops = LoopLedger.merge(existing: already, found: findings.newLoops + newSpoken.map(\.loop), updates: findings.updates, items: candidates, now: deps.clock.now())
                await LoopLedger.save(allLoops, store)
                // Every ask and loop names someone: the registry learns each spelling and handle (the sync may have added
                // People notes, so it is seeded again first), and the app is told who looks like one person twice.
                await registry.seed(from: (try? await deps.knowledge.folders()) ?? [])
                for a in asks { await registry.register(label: a.person, handle: a.handle) }
                for l in allLoops { await registry.register(label: l.person, handle: nil) }
                do { try await registry.save() } catch { log.warn("people registry not saved: \(error)") }
                let suspects = await registry.suspects().map { [$0.0.id, $0.1.id] }
                try? await store.setValue(SettingKey.duplicatePeople, String(data: JSONEncoder().encode(suspects), encoding: .utf8))
                await Self.writeStatusBlock(asks: asks, loops: allLoops, knowledge: deps.knowledge, registry: registry, now: deps.clock.now(), timeZone: deps.clock.timeZone)
                // The gardener: every People and Groups note back in shape and aged, the lines that retired from the status block kept under Earlier, quiet notes archived.
                await VaultGardener.run(root: deps.knowledge.rootURL, registry: registry, now: deps.clock.now(), timeZone: deps.clock.timeZone,
                                        retiredLines: { [now = deps.clock.now(), tz = deps.clock.timeZone] in StatusBlock.retiredLines(person: $0, asks: asks, loops: allLoops, now: now, timeZone: tz) }, archive: true)
                try await store.setValue(SettingKey.candidates, String(data: JSONEncoder().encode(candidates), encoding: .utf8))

                onEvent(.progress(RunProgress(stage: .preparing, stats: stats)))
                deps.stage("Prepare the cards", "\(candidates.count) candidates, the summaries, and the notes the brain chose to read")
                let (cards, u2) = try await Preparer(brain: brain, knowledge: deps.knowledge, clock: deps.clock).prepare(candidates: candidates, summaries: recent, instructions: instructions, max: max) { e in if case .message(let m) = e { onEvent(.thought(m)) } }
                usage = usage + u2
                // Due-aware nudges: loops whose date is close get a card even when nothing new was said.
                var dueCards: [Card] = []
                let nudgeDays = Int(try await store.value(SettingKey.nudgeDays) ?? "1") ?? 1
                var loopsNow = allLoops
                var dueCal = Calendar.current; dueCal.timeZone = deps.clock.timeZone
                for l in DueNudger.due(loopsNow, now: deps.clock.now(), days: nudgeDays, calendar: dueCal) where !cards.contains(where: { $0.loopID == l.id }) {
                    deps.stage("Nudge before a deadline", "one loop with a date, and the note about \(l.person)")
                    do { let (c, u) = try await LoopNudger(brain: brain, knowledge: deps.knowledge, clock: deps.clock).card(for: l, dueAware: true); dueCards.append(c); usage = usage + u
                         if let i = loopsNow.firstIndex(where: { $0.id == l.id }) { loopsNow[i].nudgedForDue = true } }
                    catch { log.warn("due nudge for \(l.person) failed: \(error)") }
                }
                if !dueCards.isEmpty { await LoopLedger.save(loopsNow, store) }
                // New cards replace the ones still waiting; what the user already fired, snoozed or dismissed stays.
                let kept = try await Self.loadCards(store: store).filter { $0.state != .ready }
                var fresh = CardDedupe.dedupe(cards + dueCards)
                if fresh.count < cards.count + dueCards.count { log.info("\(cards.count + dueCards.count - fresh.count) duplicate card(s) folded") }
                // The quiet check: nothing stale or already handled reaches the morning.
                let staleDays = Int(try await store.value(SettingKey.staleDays) ?? "") ?? QuietCheck.defaultStaleDays
                var noteDates: [String: Date] = [:]
                for f in (try? await deps.knowledge.folders()) ?? [] { for n in f.notes { noteDates[n.relativePath] = n.updatedAt } }
                let checked = QuietCheck.run(cards: fresh, loops: loopsNow, past: kept, noteUpdated: { noteDates[$0] }, fileExists: { FileManager.default.fileExists(atPath: $0) }, now: deps.clock.now(), staleDays: staleDays)
                for d in checked.dropped { log.info("quiet check dropped “\(d.card.title)”: \(d.why)") }
                fresh = checked.kept
                try await Self.saveCards(kept + fresh, store: store)
                try await store.setValue("brain.lastUsage", String(data: JSONEncoder().encode(usage), encoding: .utf8))

                // Sunday: the week in a letter, once per week
                if let u = try await writeWeeklyIfDue(brain: brain, store: store, cards: cards, loops: allLoops, calendar: cal) { usage = usage + u }

                // 5. FINISH — the judge has seen the merged summaries, so they go now; what is unmerged waits for the next sync
                try await store.deleteMerged()
                let legacyMirror = try await store.value(SettingKey.icloudMirror) ?? "false"
                let mode = try await store.value(SettingKey.icloudMode) ?? (legacyMirror == "true" ? "mirror" : "off")
                // The household: shared notes go to the shared folder; what the others closed comes back.
                if let household, let root = (deps.knowledge as? FileKnowledgeStore)?.rootURL {
                    deps.stage("Sync the household", "Household/ notes and \(household.sharedBuckets.count) shared chat(s) with \(household.othersLine)")
                    do {
                        let r = try await Self.syncHousehold(household, root: root, store: store, now: deps.clock.now())
                        try await store.setValue(SettingKey.householdLastSync, String(data: JSONEncoder().encode(r), encoding: .utf8))
                    } catch { log.warn("household sync: \(error)") }
                }
                if let root = (deps.knowledge as? FileKnowledgeStore)?.rootURL {
                    // Today.md: the morning's cards as checkboxes, for the phone.
                    try? TodayNote.render(cards: kept + fresh, date: deps.clock.now()).write(to: root.appendingPathComponent(TodayNote.path), atomically: true, encoding: .utf8)
                }
                if mode != "off", let root = (deps.knowledge as? FileKnowledgeStore)?.rootURL, let dest = Vault.icloudFolder {
                    do {
                        if mode == "twoway" {
                            let r = try Vault.sync(root, to: dest); try await store.setValue(SettingKey.lastSync, String(data: JSONEncoder().encode(r), encoding: .utf8))
                            // What the phone ticked since last time comes back with the sync.
                            if let md = try? String(contentsOf: root.appendingPathComponent(TodayNote.path), encoding: .utf8) {
                                var all = try await Self.loadCards(store: store)
                                let done = TodayNote.apply(TodayNote.parse(md), to: &all, now: deps.clock.now())
                                if !done.isEmpty { try await Self.saveCards(all, store: store); log.info("\(done.count) card(s) ticked on the phone") }
                            }
                        }
                        else { _ = try Vault.mirror(root, to: dest) }
                    } catch { log.warn("iCloud \(mode): \(error)") }
                }
                outcome = .ran(cards: fresh.count)
            } else if deps.brain == nil {
                outcome = .failedBrain(.notConfigured)
                if !summaries.isEmpty { log.info("no brain: keeping \(summaries.count) summaries for later") }
                if stats.read > 0 { outcome = .partial(stage: "read only — no brain configured") }
            } else {
                outcome = .ran(cards: 0)
            }
            if readable == 0, !skipped.isEmpty, deps.reader != nil {
                outcome = .partial(stage: "nothing could be read — " + skipped.joined(separator: "; "))
            }
            // FINISH, every run: the vault measured and the night's record kept, and what has aged out let go —
            // the store's rows and dated settings, the transcript cache, the log files. None of it can fail the run.
            await Self.housekeep(deps: deps, store: store, log: log)
            try? await store.setValue("run.lastSkipped", skipped.isEmpty ? nil : skipped.joined(separator: "; "))
            if !skipped.isEmpty { log.warn("skipped: \(skipped.joined(separator: "; "))") }
            if deps.reader == nil { outcome = .failedReader("the reader isn't downloaded yet") }
        } catch is CancellationError { outcome = .cancelled }
        catch IngestRun.Failure.cancelled { outcome = .cancelled }
        catch BrainError.cancelled { outcome = .cancelled }   // Stop pressed while the brain was mid-loop
        catch IngestRun.Failure.readerStuck { outcome = .failedReader("the reader stopped responding") }
        catch let e as LocalModelError { outcome = .failedReader("\(e)") }
        catch BrainError.usageLimit { outcome = .failedBrain(.usageLimit) }
        catch BrainError.unauthorized { outcome = .failedBrain(.unauthorized) }
        catch BrainError.notConfigured { outcome = .failedBrain(.notConfigured) }
        catch KnowledgeBuilder.Failure.staleSwapAverted { outcome = .partial(stage: "you edited a note during the run; notes will merge next run") }
        catch {
            log.error("run failed: \(error)"); outcome = .failedBrain(.other)
            try? await store.setValue("run.lastError", Self.short(error))   // shown in plain words on For You
        }

        try? await store.endRun(runID, outcome: outcome, stats: stats, at: deps.clock.now())
        log.info("run #\(runID) ended: \(outcome) · \(stats)")
        onEvent(.progress(RunProgress(stage: .done, stats: stats)))
        return outcome
    }

    /// Sunday's letter. Written on the first run on or after Sunday for the ISO week that ends that Sunday.
    private func writeWeeklyIfDue(brain: any Brain, store: any RunStore, cards: [Card], loops: [Loop], calendar: String?, force: Bool = false) async throws -> Usage? {
        let now = deps.clock.now()
        var cal = Calendar.current; cal.timeZone = deps.clock.timeZone
        guard force || cal.component(.weekday, from: now) == 1 else { return nil }
        let week = WeeklyWriter.isoWeek(now)
        let existing = try await store.value(SettingKey.weekly(week)) ?? ""
        guard force || existing.isEmpty else { return nil }
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) ?? now
        let runs = (try await store.recentRuns(limit: 20)).filter { $0.startedAt >= weekStart }
        let read = runs.reduce(0) { $0 + $1.stats.read }, kept = runs.reduce(0) { $0 + $1.stats.kept }, erased = runs.reduce(0) { $0 + $1.stats.sensitive }
        let sends = try await store.sendLog(since: weekStart)
        let bytes = sends.reduce(0) { $0 + $1.bytes }
        let allCards = try await Self.loadCards(store: store) + cards
        let weekCards = allCards.filter { ($0.resolvedAt ?? $0.createdAt) >= weekStart }
        let weekLoops = loops.filter { $0.status == .open || ($0.closedAt ?? .distantPast) >= weekStart }
        let readme = try await deps.knowledge.note(at: "README.md")?.body ?? ""
        let f = DateFormatter(); f.dateFormat = "d MMM"
        deps.stage("Write the Sunday letter", "this week's numbers, \(weekCards.count) cards, \(weekLoops.count) loops, your README")
        let corrections = FeedbackDigest.weekLine(Self.loadFeedback(try await store.value(SettingKey.feedback)), since: weekStart)
        let (text, u) = try await WeeklyWriter(brain: brain).write(range: "\(f.string(from: weekStart))–\(f.string(from: now))", corrections: corrections,
            numbers: "\(runs.count) of 7 nights ran · \(read) read · \(kept) kept · \(erased) sensitive erased · \(weekCards.filter { $0.state == .fired }.count) cards fired by the user · \(weekLoops.filter { $0.status == .closed }.count) loops closed, \(weekLoops.filter { $0.status == .open && $0.openedAt >= weekStart }.count) opened",
            bytes: bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KB", Double(bytes) / 1024), cards: weekCards, loops: weekLoops, readme: readme, calendar: calendar)
        try await store.setValue(SettingKey.weekly(week), text)
        try await store.setValue(SettingKey.weeklyLatest, week)
        log.info("weekly letter written for \(week)")
        return u
    }

    /// The app's "Write my week now" button.
    public func writeWeeklyNow() async throws {
        guard let brain = deps.brain else { throw BrainError.notConfigured }
        let loops = await LoopLedger.load(deps.store)
        _ = try await writeWeeklyIfDue(brain: brain, store: deps.store, cards: [], loops: loops, calendar: await deps.calendarText(), force: true)
    }

    static func describe(_ a: Availability) -> String {
        switch a {
        case .available: return "available"
        case .notInstalled: return "not on this Mac"
        case .needsPermission(let p): return p == .fullDiskAccess ? "needs Full Disk Access (Settings → Privacy)" : "needs \(p.rawValue)"
        case .needsSignIn: return "needs sign-in"
        case .unavailable(let why): return why
        }
    }
    static func short(_ e: Error) -> String { let s = "\(e)"; return s.count > 120 ? String(s.prefix(120)) + "…" : s }

    private func enabledBuckets(for source: any Source, store: any RunStore) async throws -> Set<BucketID>? {
        guard source.descriptor.supportsPerBucketOptIn else { return nil }
        guard let json = try await store.value(SettingKey.enabledBuckets(source.id)), let d = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(ids.map(BucketID.init))
    }

    /// Direct chats → asks and the user's replies → judged (rules, then the on-device reader) → the local ledger.
    static func scanAsks(deps: Dependencies, store: any RunStore, reader: (any LocalModel)?, log: Log) async {
        let now = deps.clock.now()
        let existing = loadAsks(try? await store.value(SettingKey.asks))
        var found: [Ask] = []
        // Each chat is read back to its own oldest ask still waiting, so a late reply is found however late — and a
        // reply already judged off-topic is passed over for the user's next message. Other chats stay at three days.
        let scan = AskLedger.scan(existing: existing, now: now)
        for source in deps.sources {
            guard let scanner = source as? AskScanning, await source.availability() == .available else { continue }
            let enabled = try? await Self.enabledBucketsStatic(for: source, store: store)
            if let a = try? await scanner.recentAsks(enabled: enabled ?? nil, scan: scan) { found += a }
        }
        let merged = AskLedger.merge(existing: existing, found: found, now: now)
        let judged = await AskAnswering.judge(merged, reader: reader)
        let unsure = judged.filter { $0.answeredAt != nil && $0.addressed == nil }.count
        log.info("asks: \(judged.count) tracked · \(judged.filter(\.isOpen).count) open · \(judged.filter { $0.addressed == false }.count) replied-but-not-answered · \(unsure) not judged")
        try? await store.setValue(SettingKey.asks, String(data: JSONEncoder().encode(judged), encoding: .utf8))
    }
    static func enabledBucketsStatic(for source: any Source, store: any RunStore) async throws -> Set<BucketID>? {
        guard source.descriptor.supportsPerBucketOptIn else { return nil }
        guard let json = try await store.value(SettingKey.enabledBuckets(source.id)), let d = json.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(ids.map(BucketID.init))
    }
    public static func loadAsks(_ json: String?) -> [Ask] {
        guard let j = json, let d = j.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Ask].self, from: d)) ?? []
    }
    /// The status block ("Between you") on every People note that has asks or loops: written straight to the file, so it never counts as the user's edit.
    /// Each ask and loop goes to exactly one note — the registry's, or failing that a title with the very same key.
    /// A first name alone never claims a note by its title; that is how "Arjun" once leaked into "Arjun Mehta".
    public static func writeStatusBlock(asks: [Ask], loops: [Loop], knowledge: any KnowledgeStore, registry: PersonRegistry?, now: Date, timeZone: TimeZone = .current) async {
        guard let people = (try? await knowledge.folders())?.first(where: { $0.name == "People" }) else { return }
        func pick(_ label: String, _ handle: String?) async -> String? {
            if let registry { return await registry.notePath(forLabel: label, handle: handle, amongNotes: people.notes) }
            return people.notes.first { PersonKey.sameKey($0.title, label) }?.relativePath
        }
        var asksFor: [String: [Ask]] = [:], loopsFor: [String: [Loop]] = [:]
        for a in asks { if let p = await pick(a.person, a.handle) { asksFor[p, default: []].append(a) } }
        for l in loops { if let p = await pick(l.person, nil) { loopsFor[p, default: []].append(l) } }
        for n in people.notes {
            let block = StatusBlock.render(person: n.title, asks: asksFor[n.relativePath] ?? [], loops: loopsFor[n.relativePath] ?? [], now: now, timeZone: timeZone, routed: true)
            let url = knowledge.rootURL.appendingPathComponent(n.relativePath)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // keep the front-matter, work on the body
            let (head, body): (String, String) = raw.hasPrefix("---\n") && raw.range(of: "\n---\n") != nil ? { let r = raw.range(of: "\n---\n")!; return (String(raw[..<r.upperBound]), String(raw[r.upperBound...])) }() : ("", raw)
            let updated = StatusBlock.upsert(into: body, block: block)
            if updated != body { try? (head + updated).write(to: url, atomically: true, encoding: .utf8) }
        }
    }
    public static func loadHousehold(_ json: String?) -> Household? {
        guard let j = json, let d = j.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Household.self, from: d)
    }
    /// The FINISH housekeeping, in one place so a Mac that keeps Brownie open for months is pruned every night, not
    /// only at launch: the vault's health record, the store's retention, the transcript cache, the log files.
    static func housekeep(deps: Dependencies, store: any RunStore, log: Log) async {
        let now = deps.clock.now()
        if FileManager.default.fileExists(atPath: deps.knowledge.rootURL.path) {
            let h = await VaultHealth.nightly(root: deps.knowledge.rootURL, now: now, store: store, timeZone: deps.clock.timeZone)
            log.info("vault health: \(h.line)")
        }
        do { try await store.prune(now: now) } catch { log.warn("prune: \(error)") }
        guard deps.diskHousekeeping else { return }
        let transcripts = TranscriptCache.prune(now: now)
        let logs = Log.rotate()
        if transcripts > 0 || !logs.isEmpty { log.info("housekeeping: \(transcripts) old transcript(s) deleted, \(logs.count) log file(s) rotated") }
    }

    /// Notes out, ledger merged, closures by the others applied to my loops and cards. Returns the notes' sync report.
    public static func syncHousehold(_ h: Household, root: URL, store: any RunStore, now: Date) async throws -> SyncReport {
        let shared = URL(fileURLWithPath: h.folderPath, isDirectory: true)
        let groupNotes = Set(h.sharedBuckets.compactMap { b -> String? in nil }) // group-note paths are matched by name below
        let names = Set(try await Self.sharedGroupNotePaths(h, store: store))
        let report = try HouseholdVault.sync(root, to: shared, sharedGroupNotes: names.union(groupNotes), now: now)
        // the ledger
        var loops = await LoopLedger.load(store)
        let mine = HouseholdLedger.entries(from: loops, me: h.me?.id ?? "me", now: now)
        let ledgerURL = shared.appendingPathComponent(HouseholdLedger.file)
        let merged = HouseholdLedger.merge(HouseholdLedger.read(ledgerURL), mine, now: now, household: h)
        try HouseholdLedger.write(merged, to: ledgerURL)
        let closed = HouseholdLedger.closures(for: loops, ledger: merged, household: h, now: now)
        if closed != loops { loops = closed; await LoopLedger.save(loops, store) }
        var cards = try await loadCards(store: store)
        let marked = HouseholdLedger.markHandled(cards, ledger: merged, household: h)
        if marked != cards { cards = marked; try await saveCards(cards, store: store) }
        return report
    }
    /// The vault paths of the shared chats' notes: `Groups/<chat name>.md`, by the names the sources report.
    static func sharedGroupNotePaths(_ h: Household, store: any RunStore) async throws -> [String] {
        guard let json = try await store.value(SettingKey.householdBucketNames), let d = json.data(using: .utf8), let names = try? JSONDecoder().decode([String: String].self, from: d) else { return [] }
        return h.sharedBuckets.compactMap { names[$0] }.map { "Groups/\($0).md" }
    }
    public static func loadFeedback(_ json: String?) -> [CardFeedback] {
        guard let j = json, let d = j.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CardFeedback].self, from: d)) ?? []
    }
    public static func saveCards(_ cards: [Card], store: any RunStore) async throws {
        try await store.setValue(SettingKey.cards, String(data: JSONEncoder().encode(cards), encoding: .utf8))
    }
    public static func loadCards(store: any RunStore) async throws -> [Card] {
        guard let s = try await store.value(SettingKey.cards), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Card].self, from: d)) ?? []
    }
}

extension RunStats {
    static func + (a: RunStats, b: RunStats) -> RunStats {
        var r = RunStats(); r.read = a.read + b.read; r.kept = a.kept + b.kept; r.dropped = a.dropped + b.dropped
        r.sensitive = a.sensitive + b.sensitive; r.failed = a.failed + b.failed; r.deferred = a.deferred + b.deferred; r.badDated = a.badDated + b.badDated; return r
    }
}
