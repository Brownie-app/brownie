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
                    } catch is CancellationError { throw CancellationError() }
                    catch IngestRun.Failure.cancelled { throw IngestRun.Failure.cancelled }
                    catch IngestRun.Failure.readerStuck { throw IngestRun.Failure.readerStuck }
                    catch {
                        log.warn("\(source.descriptor.name) failed: \(error)")
                        skipped.append("\(source.descriptor.name): couldn't be read (\(Self.short(error)))")
                    }
                }
                await reader.unload()
            }

            // 2–4. CLOUD
            let summaries = try await store.summaries(since: nil)
            if let brain = deps.brain, !summaries.isEmpty {
                onEvent(.progress(RunProgress(stage: .synthesising, stats: stats)))
                deps.stage("Update your notes", "\(summaries.count) summaries and the notes they touch")
                let builder = try KnowledgeBuilder(brain: brain, store: deps.knowledge, runStore: store)
                let readStats = stats
                var usage = try await builder.sync(summaries: summaries, progress: { p in var p = p; p.stats = readStats; onEvent(.progress(p)) }, onEvent: { e in if case .message(let m) = e { onEvent(.thought(m)) } })

                // welcome letter, once
                if (try await store.value(SettingKey.letter) ?? "").isEmpty, let readme = try await deps.knowledge.note(at: "README.md") {
                    do {
                        deps.stage("Write the welcome letter", "your README and the night's numbers")
                        let (letter, u) = try await LetterWriter(brain: brain).write(readme: readme.body, numbers: "\(stats.read) read, \(stats.kept) kept, \(stats.sensitive) erased on sight")
                        try await store.setValue(SettingKey.letter, letter); usage = usage + u
                    } catch { log.warn("letter not written this run: \(error)") }
                }

                onEvent(.progress(RunProgress(stage: .judging, stats: stats)))
                let recent = try await store.summaries(since: deps.clock.now().addingTimeInterval(-7 * 86400))
                let instructions = try await store.value(SettingKey.standingInstructions) ?? ""
                let max = Int(try await store.value(SettingKey.cardsPerMorning) ?? "5") ?? 5
                let openLoops = await LoopLedger.load(store).filter { $0.status == .open }
                let cal = await deps.calendarText()
                deps.stage("Judge what matters", "\(recent.count) summaries from the last 7 days\(cal == nil ? "" : ", the calendar for 8 days"), \(openLoops.count) open loops")
                let (findings, u1) = try await Judge(brain: brain, clock: deps.clock).judge(summaries: recent, calendar: cal, instructions: instructions, openLoops: openLoops, max: 8)
                let candidates = findings.items
                usage = usage + u1
                let allLoops = LoopLedger.merge(existing: await LoopLedger.load(store), found: findings.newLoops, updates: findings.updates, items: candidates, now: deps.clock.now())
                await LoopLedger.save(allLoops, store)
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
                try await Self.saveCards(kept + cards + dueCards, store: store)
                try await store.setValue("brain.lastUsage", String(data: JSONEncoder().encode(usage), encoding: .utf8))

                // Sunday: the week in a letter, once per week
                if let u = try await writeWeeklyIfDue(brain: brain, store: store, cards: cards, loops: allLoops, calendar: cal) { usage = usage + u }

                // 5. FINISH — summaries are disposable only after a fully successful chain
                try await store.wipeSummaries()
                if (try await store.value(SettingKey.icloudMirror) ?? "false") == "true", let root = (deps.knowledge as? FileKnowledgeStore)?.rootURL {
                    do { _ = try Vault.mirror(root) } catch { log.warn("iCloud mirror: \(error)") }
                }
                outcome = .ran(cards: cards.count + dueCards.count)
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
            try? await store.setValue("run.lastSkipped", skipped.isEmpty ? nil : skipped.joined(separator: "; "))
            if !skipped.isEmpty { log.warn("skipped: \(skipped.joined(separator: "; "))") }
            if deps.reader == nil { outcome = .failedReader("the reader isn't downloaded yet") }
        } catch is CancellationError { outcome = .cancelled }
        catch IngestRun.Failure.cancelled { outcome = .cancelled }
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
        let (text, u) = try await WeeklyWriter(brain: brain).write(range: "\(f.string(from: weekStart))–\(f.string(from: now))",
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
        r.sensitive = a.sensitive + b.sensitive; r.failed = a.failed + b.failed; r.deferred = a.deferred + b.deferred; return r
    }
}
