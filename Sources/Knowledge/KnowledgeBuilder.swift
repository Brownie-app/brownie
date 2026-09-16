import Foundation
import Domain
import Platform
import Support

/// Builds (first time) or updates (every run) the KB with the brain, in a staging directory that is
/// atomically swapped into place on success. Resumable across usage limits and restarts: the parts
/// are planned once, each part's summary ids are frozen in the resume token, and a part's rows are
/// marked merged the moment it lands, so no summary is ever fed twice and none is skipped.
public actor KnowledgeBuilder {
    public struct ResumeToken: Codable, Sendable, Equatable {
        public var stagingPath: String
        /// The summary ids of every part, fixed when the sync was planned. A resumed sync feeds exactly these.
        public var parts: [[Int64]]
        public var nextPart: Int
        public var fingerprint: String
        public var isBuild: Bool
        /// Every live note when staging was seeded, as "size|mtime", so a user's edit mid-sync can be told from the brain's.
        public var seeded: [String: String]
        public init(stagingPath: String, parts: [[Int64]], nextPart: Int, fingerprint: String, isBuild: Bool, seeded: [String: String]) {
            self.stagingPath = stagingPath; self.parts = parts; self.nextPart = nextPart; self.fingerprint = fingerprint; self.isBuild = isBuild; self.seeded = seeded
        }
    }
    public enum Failure: Error { case brainMissing, staleSwapAverted, nothingWritten }

    private let brain: any Brain
    private let store: any KnowledgeStore
    private let runStore: any RunStore
    private let log = Log("kb.builder")
    private let buildPrompt: String, updatePrompt: String
    private let partBudget: Int
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let coverage: @Sendable () async -> String?
    private let people: @Sendable () async -> [Person]

    /// `coverage` renders the "how far back each source has been read" lines for the brain's header; nil skips them.
    /// `people` is the registry's roster, so the brain knows which file each person already has.
    public init(brain: any Brain, store: any KnowledgeStore, runStore: any RunStore, bundle: Bundle? = nil,
                partBudget: Int = BrainLimits.corpusPartBudget, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
                coverage: @escaping @Sendable () async -> String? = { nil }, people: @escaping @Sendable () async -> [Person] = { [] }) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.store = store; self.runStore = runStore
        self.partBudget = partBudget; self.now = now; self.timeZone = timeZone; self.coverage = coverage; self.people = people
        buildPrompt = try String(contentsOf: bundle.url(forResource: "build", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "build", withExtension: "md")!, encoding: .utf8)
        updatePrompt = try String(contentsOf: bundle.url(forResource: "update", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "update", withExtension: "md")!, encoding: .utf8)
    }

    /// Build or update depending on whether a KB exists. `summaries` are the rows not yet in the notes;
    /// a fresh sync plans its parts from them, oldest first, while a resumed sync ignores them and
    /// feeds exactly the ids it froze. Returns usage. The caller deletes merged rows after the swap.
    public func sync(summaries: [SummaryRecord], progress: @escaping @Sendable (RunProgress) -> Void, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Usage {
        let fm = FileManager.default
        var token = try await loadToken()
        if let t = token, !fm.fileExists(atPath: t.stagingPath) { token = nil }
        let parts: [[SummaryRecord]]
        if let t = token {
            // Exactly the rows planned then, by id. Anything that arrived since waits for the next sync; a
            // row already marked merged (a crash between a part's mark and its token save) is not fed twice.
            let byID = Dictionary(try await runStore.unmergedSummaries().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            parts = t.parts.map { $0.compactMap { byID[$0] } }
            log.info("resuming at part \(t.nextPart + 1)/\(parts.count)")
        } else {
            guard !summaries.isEmpty else { return .zero }
            let isBuild = !(await store.exists())
            let ordered = summaries.sorted { ($0.effectiveDate, $0.id) < ($1.effectiveDate, $1.id) }
            parts = CorpusSlicer.plan(ordered, budget: partBudget, timeZone: timeZone)
            let seeded = isBuild ? [:] : Self.stamps(store.rootURL)
            let staging = try newStagingDir(seedFromLive: !isBuild)
            token = ResumeToken(stagingPath: staging.path, parts: parts.map { $0.map(\.id) }, nextPart: 0,
                                fingerprint: isBuild ? "" : (try await store.fingerprint()), isBuild: isBuild, seeded: seeded)
            try await saveToken(token)
        }
        var t = token!
        let staging = URL(fileURLWithPath: t.stagingPath, isDirectory: true)
        var usage = Usage.zero
        for i in t.nextPart..<parts.count {
            let part = parts[i]
            if !part.isEmpty {
                progress(RunProgress(stage: .synthesising, partIndex: i + 1, partCount: parts.count))
                // A part that fails leaves no half-written notes behind: staging goes back to how it was.
                let snapshot = try snapshot(of: staging)
                do { usage = usage + (try await runPart(isBuild: t.isBuild, corpus: CorpusSlicer.render(part: part, timeZone: timeZone), in: staging, onEvent: onEvent)) }
                catch { try? restore(snapshot, to: staging); throw error }
                try? fm.removeItem(at: snapshot)
                // Mark first, then advance: a crash between the two makes the resumed part empty rather than fed twice.
                try await runStore.markMerged(ids: part.map(\.id), at: now())
            }
            t.nextPart = i + 1
            try await saveToken(t)
        }
        // verify + swap
        let written = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" || $0.hasDirectoryPath }
        guard !written.isEmpty else { throw Failure.nothingWritten }
        if !t.isBuild, try await store.fingerprint() != t.fingerprint {
            // The user edited notes while the sync ran: their files win, the brain's work stands everywhere else.
            let kept = try Self.keepUserEdits(live: store.rootURL, staging: staging, seeded: t.seeded)
            log.warn("user edited \(kept) note(s) during the run — theirs kept, the rest taken from tonight's work")
        }
        try swap(staging)
        try await saveToken(nil)
        log.info("KB \(t.isBuild ? "built" : "updated"): \(parts.count) part(s)")
        return usage
    }

    // MARK: agent turn

    /// What the brain is told before the summaries: the date, so nothing in the notes is relative to an
    /// unknown "today"; how far back each source has been read, when the app knows; and who exists, with the
    /// one file each person is written in, so a name in a new spelling never opens a second file.
    func header() async -> String {
        let today = now()
        var lines = ["Today: \(CorpusSlicer.isoDay(today, timeZone)) (\(Self.weekday(today, timeZone)))"]
        if let c = await coverage()?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            lines.append("Coverage (how far back each source has been read):\n" + c.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        let roster = PersonRegistry.headerLines(await people(), cap: Self.peopleCap)
        if !roster.isEmpty {
            lines.append("PEOPLE (one file per person; write about each only in the file listed, whatever spelling the summaries use):\n" + roster.map { "  " + $0 }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n") + "\n\n"
    }
    /// The roster stops here: past it, the header would crowd out the summaries.
    static let peopleCap = 200

    static func weekday(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    private func runPart(isBuild: Bool, corpus: String, in staging: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Usage {
        let system = isBuild ? buildPrompt : updatePrompt
        let input = await header() + "Working directory: the knowledge base root (use relative paths).\n\nSUMMARIES:\n\n" + corpus
        if let agentic = brain as? AgenticBrain, brain.descriptor.capabilities.contains(.files) {
            let effort: Effort = isBuild ? .high : .medium   // first build thinks hard; nightly merges don't need to
            let ended = FinishBox()
            let tools = FileTools.make(root: staging).map { tool in
                guard tool.name == "finish" else { return tool }
                // finish ends the loop: the brain's task is cancelled the moment it is called, so the
                // model cannot keep writing after saying it is done. That cancellation is success.
                return Tool(name: tool.name, description: tool.description, parametersSchema: tool.parametersSchema) { d in
                    let out = try await tool.run(d); await ended.finish(); return out
                }
            }
            let task = Task { try await agentic.run(AgentTask(system: system, input: input, effort: effort, maxTurns: 200, timeout: 2400), tools: tools) { e in
                switch e {
                case .toolCall(let name, let summary):
                    if name == "write_file", let path = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any], let p = path["path"] as? String { onEvent(.message("Writing \(p)")) }
                    else if name == "write_file" { onEvent(.message("Writing a note…")) }
                    else if name == "finish" { onEvent(.message("Finishing the knowledge base")) }
                    else if name == "read_file" || name == "list_dir" { onEvent(.message("Reading existing notes")) }
                default: onEvent(e)
                }
            } }
            await ended.hold(task)
            do { return try await task.value.usage }
            catch {
                // A part ended by finish never reports its usage; it counts as nothing rather than failing the part.
                if await ended.finished, error is CancellationError || (error as? BrainError) == .cancelled { return .zero }
                throw error
            }
        }
        // Single-shot fallback for brains without file tools: emit a file map as JSON.
        let schema = #"{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},"required":["files"]}"#
        let existing = FileTools.listing(staging).prefix(200).joined(separator: "\n")
        let r = try await brain.complete(BrainRequest(system: system + "\n\nYou have no file tools. Reply with JSON {\"files\":[{\"path\":…,\"content\":…}]} containing every file to write or overwrite (full contents).",
                                                     input: "EXISTING FILES:\n\(existing)\n\n" + input, schema: schema, maxOutputTokens: 32_000))
        guard let data = r.jsonData, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let files = obj["files"] as? [[String: Any]] else { throw BrainError.badResponse("no file map") }
        for f in files { if let p = f["path"] as? String, let c = f["content"] as? String { _ = try? FileTools.write(root: staging, path: p, content: c) } }
        return r.usage
    }

    // MARK: staging, snapshots, swap

    private func newStagingDir(seedFromLive: Bool) throws -> URL {
        let fm = FileManager.default
        let parent = store.rootURL.deletingLastPathComponent()
        // sweep orphans
        for u in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where u.lastPathComponent.hasPrefix(".brownie-kb-staging-") || u.lastPathComponent.hasPrefix(".brownie-kb-snapshot-") { try? fm.removeItem(at: u) }
        let dir = parent.appendingPathComponent(".brownie-kb-staging-\(UUID().uuidString)", isDirectory: true)
        if seedFromLive, fm.fileExists(atPath: store.rootURL.path) { try fm.copyItem(at: store.rootURL, to: dir) }
        else { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    private func snapshot(of staging: URL) throws -> URL {
        let dir = staging.deletingLastPathComponent().appendingPathComponent(".brownie-kb-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: staging, to: dir)
        return dir
    }

    private func restore(_ snapshot: URL, to staging: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.moveItem(at: snapshot, to: staging)
    }

    private func swap(_ staging: URL) throws {
        let fm = FileManager.default
        let live = store.rootURL
        if fm.fileExists(atPath: live.path) {
            _ = try fm.replaceItemAt(live, withItemAt: staging, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: staging, to: live)
        }
    }

    /// Every note under root as relpath → "size|mtime": the cheapest thing that changes on any edit.
    static func stamps(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        for rel in FileTools.listing(root) where rel.hasSuffix(".md") {
            if let a = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(rel).path) {
                out[rel] = "\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
        }
        return out
    }

    /// Merges a mid-sync user edit file by file: a note the user changed or added wins over the brain's
    /// version; a note the user deleted stays gone unless the brain rewrote it; the rest is staging.
    /// Returns how many of the user's changes were honoured.
    static func keepUserEdits(live: URL, staging: URL, seeded: [String: String]) throws -> Int {
        let fm = FileManager.default
        let liveNow = stamps(live), stagingNow = stamps(staging)
        var kept = 0
        for (rel, stamp) in liveNow where seeded[rel] != stamp {
            let dest = staging.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: live.appendingPathComponent(rel), to: dest)
            kept += 1
        }
        for (rel, stamp) in seeded where liveNow[rel] == nil && stagingNow[rel] == stamp {
            try? fm.removeItem(at: staging.appendingPathComponent(rel)); kept += 1
        }
        return kept
    }

    private func loadToken() async throws -> ResumeToken? {
        guard let s = try await runStore.value(SettingKey.kbResume), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResumeToken.self, from: d)
    }
    private func saveToken(_ t: ResumeToken?) async throws {
        try await runStore.setValue(SettingKey.kbResume, t.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) })
    }
}

/// Whether the brain has said it is done, and the task to stop when it does.
private actor FinishBox {
    private(set) var finished = false
    private var task: Task<AgentResult, Error>?
    func hold(_ t: Task<AgentResult, Error>) { task = t; if finished { t.cancel() } }
    func finish() { finished = true; task?.cancel() }
}

/// File tools scoped to one directory. Paths are relative; `..` is refused.
enum FileTools {
    static func make(root: URL) -> [Tool] {
        [
            Tool(name: "list_dir", description: "List files and folders under a relative path ('' for the root).", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":[]}"#) { data in
                let p = (arg(data)["path"] as? String) ?? ""
                return listing(root, sub: p).joined(separator: "\n").ifEmpty("(empty)")
            },
            Tool(name: "read_file", description: "Read a file at a relative path.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                let p = arg(data)["path"] as? String ?? ""
                let url = try resolve(root, p)
                return try String(contentsOf: url, encoding: .utf8)
            },
            Tool(name: "write_file", description: "Create or overwrite a file at a relative path with the full content.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#) { data in
                let a = arg(data)
                return try write(root: root, path: a["path"] as? String ?? "", content: a["content"] as? String ?? "")
            },
            Tool(name: "delete_file", description: "Delete a file at a relative path.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                try FileManager.default.removeItem(at: try resolve(root, arg(data)["path"] as? String ?? "")); return "deleted"
            },
            Tool(name: "finish", description: "Call when every note is written. Give a one-line summary.", parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { data in
                "finished: \(arg(data)["summary"] as? String ?? "")"
            },
        ]
    }

    static func arg(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    static func resolve(_ root: URL, _ p: String) throws -> URL {
        guard !p.contains(".."), !p.hasPrefix("/") else { throw NSError(domain: "FileTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "path must be relative"]) }
        return root.appendingPathComponent(p)
    }

    @discardableResult
    static func write(root: URL, path: String, content: String) throws -> String {
        let url = try resolve(root, path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "wrote \(path) (\(content.utf8.count) bytes)"
    }

    static func listing(_ root: URL, sub: String = "") -> [String] {
        // Standardised on both sides: the enumerator may spell a symlinked root (/var → /private/var) differently.
        let root = root.standardizedFileURL
        let base = root.appendingPathComponent(sub)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.path.count + 1))
            out.append((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? rel + "/" : rel)
        }
        return out.sorted()
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }
