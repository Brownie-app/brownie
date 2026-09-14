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
        public init(store: any RunStore, knowledge: any KnowledgeStore, sources: [any Source], reader: (any LocalModel)?, brain: (any Brain)?,
                    policy: any SensitivityPolicy, clock: Clock = SystemClock(), calendarText: @escaping @Sendable () async -> String? = { nil }) {
            self.store = store; self.knowledge = knowledge; self.sources = sources; self.reader = reader; self.brain = brain
            self.policy = policy; self.clock = clock; self.calendarText = calendarText
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
                let builder = try KnowledgeBuilder(brain: brain, store: deps.knowledge, runStore: store)
                let readStats = stats
                var usage = try await builder.sync(summaries: summaries, progress: { p in var p = p; p.stats = readStats; onEvent(.progress(p)) }, onEvent: { e in if case .message(let m) = e { onEvent(.thought(m)) } })

                // welcome letter, once
                if (try await store.value(SettingKey.letter) ?? "").isEmpty, let readme = try await deps.knowledge.note(at: "README.md") {
                    do {
                        let (letter, u) = try await LetterWriter(brain: brain).write(readme: readme.body, numbers: "\(stats.read) read, \(stats.kept) kept, \(stats.sensitive) erased on sight")
                        try await store.setValue(SettingKey.letter, letter); usage = usage + u
                    } catch { log.warn("letter not written this run: \(error)") }
                }

                onEvent(.progress(RunProgress(stage: .judging, stats: stats)))
                let recent = try await store.summaries(since: deps.clock.now().addingTimeInterval(-7 * 86400))
                let instructions = try await store.value(SettingKey.standingInstructions) ?? ""
                let max = Int(try await store.value(SettingKey.cardsPerMorning) ?? "5") ?? 5
                let (candidates, u1) = try await Judge(brain: brain, clock: deps.clock).findActionItems(summaries: recent, calendar: await deps.calendarText(), instructions: instructions, max: 8)
                usage = usage + u1
                try await store.setValue(SettingKey.candidates, String(data: JSONEncoder().encode(candidates), encoding: .utf8))

                onEvent(.progress(RunProgress(stage: .preparing, stats: stats)))
                let (cards, u2) = try await Preparer(brain: brain, knowledge: deps.knowledge, clock: deps.clock).prepare(candidates: candidates, summaries: recent, instructions: instructions, max: max) { e in if case .message(let m) = e { onEvent(.thought(m)) } }
                usage = usage + u2
                try await Self.saveCards(cards, store: store)
                try await store.setValue("brain.lastUsage", String(data: JSONEncoder().encode(usage), encoding: .utf8))

                // 5. FINISH — summaries are disposable only after a fully successful chain
                try await store.wipeSummaries()
                outcome = .ran(cards: cards.count)
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
        catch { log.error("run failed: \(error)"); outcome = .failedBrain(.other) }

        try? await store.endRun(runID, outcome: outcome, stats: stats, at: deps.clock.now())
        log.info("run #\(runID) ended: \(outcome) · \(stats)")
        onEvent(.progress(RunProgress(stage: .done, stats: stats)))
        return outcome
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
