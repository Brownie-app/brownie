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

    /// Notes a brain without file tools proposed this sync that the vault's rules turned away. A brain with tools
    /// hears a refusal and writes again; one without gets no second turn, so what it lost is counted here and
    /// the coordinator carries the number into the night's stats.
    public private(set) var refusals = 0

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
    private let instructions: String
    private let selfNames: [String]

    /// `coverage` renders the "how far back each source has been read" lines for the brain's header; nil skips them.
    /// `people` is the registry's roster, so the brain knows which file each person already has. `instructions` is what
    /// the user's ratings of the notes taught (the note feedback digest), given to both prompts at `{{instructions}}`.
    /// `selfNames` are the user's own, so the tools refuse a People or Groups note about them.
    public init(brain: any Brain, store: any KnowledgeStore, runStore: any RunStore, bundle: Bundle? = nil,
                partBudget: Int = BrainLimits.corpusPartBudget, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
                coverage: @escaping @Sendable () async -> String? = { nil }, people: @escaping @Sendable () async -> [Person] = { [] }, instructions: String = "", selfNames: [String] = []) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.store = store; self.runStore = runStore
        self.partBudget = partBudget; self.now = now; self.timeZone = timeZone; self.coverage = coverage; self.people = people; self.instructions = instructions; self.selfNames = SelfNames.clean(selfNames)
        buildPrompt = try String(contentsOf: bundle.url(forResource: "build", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "build", withExtension: "md")!, encoding: .utf8)
        updatePrompt = try String(contentsOf: bundle.url(forResource: "update", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "update", withExtension: "md")!, encoding: .utf8)
    }

    /// Build or update depending on whether a KB exists. `summaries` are the rows not yet in the notes;
    /// a fresh sync plans its parts from them, oldest first, while a resumed sync ignores them and
    /// feeds exactly the ids it froze. Returns usage. The caller deletes merged rows after the swap.
    public func sync(summaries: [SummaryRecord], progress: @escaping @Sendable (RunProgress) -> Void, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Usage {
        let fm = FileManager.default
        refusals = 0
        var token = try await loadToken()
        if let t = token, !fm.fileExists(atPath: t.stagingPath) { token = nil }
        var parts: [[SummaryRecord]] = []
        if let t = token {
            // Exactly the rows planned then, by id. Anything that arrived since waits for the next sync; a
            // row already marked merged (a crash between a part's mark and its token save) is not fed twice.
            let byID = Dictionary(try await runStore.unmergedSummaries().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            parts = t.parts.map { $0.compactMap { byID[$0] } }
            if parts[t.nextPart...].allSatisfy(\.isEmpty), !Self.hasNotes(URL(fileURLWithPath: t.stagingPath, isDirectory: true)) {
                // Nothing left to feed and nothing to swap: a token like this (a build whose every row was marked
                // but whose brain never wrote a note) would wedge every later sync, so it is dropped and tonight plans afresh.
                log.warn("resume token has no parts left and no notes in staging — starting over")
                try? fm.removeItem(atPath: t.stagingPath); token = nil; try await saveToken(nil)
            } else {
                log.info("resuming at part \(t.nextPart + 1)/\(parts.count)")
            }
        }
        if token == nil {
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
            // Stop (the run's cancellation) is honoured between parts as well as inside one.
            try Task.checkCancellation()
            let part = parts[i]
            if !part.isEmpty {
                progress(RunProgress(stage: .synthesising, partIndex: i + 1, partCount: parts.count))
                // A part that fails leaves no half-written notes behind: staging goes back to how it was.
                let snapshot = try snapshot(of: staging)
                do {
                    usage = usage + (try await runPart(isBuild: t.isBuild, corpus: CorpusSlicer.render(part: part, timeZone: timeZone), in: staging, onEvent: onEvent))
                    // A part is done only when notes exist to show for it: a brain that answered without writing
                    // has not done the part, so its rows are not marked and the same part is fed again next time.
                    guard Self.hasNotes(staging) else { throw Failure.nothingWritten }
                } catch { try? restore(snapshot, to: staging); throw error }
                try? fm.removeItem(at: snapshot)
                // Mark first, then advance: a crash between the two makes the resumed part empty rather than fed twice.
                try await runStore.markMerged(ids: part.map(\.id), at: now())
            }
            t.nextPart = i + 1
            try await saveToken(t)
        }
        // verify + swap; nothing to swap means this token must not survive to wedge the next sync
        guard Self.hasNotes(staging) else { try? fm.removeItem(at: staging); try await saveToken(nil); throw Failure.nothingWritten }
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
        // What the user's ratings taught goes in at the prompt's `{{instructions}}` — an empty string when nothing has been said.
        let system = (isBuild ? buildPrompt : updatePrompt).replacingOccurrences(of: "{{instructions}}", with: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        let input = await header() + "Working directory: the knowledge base root (use relative paths).\n\nSUMMARIES:\n\n" + corpus
        // One set of tools per part: the roster it checks People/ paths against, the day it stamps, and what it has read.
        let part = FileTools.Part(root: staging, people: await people(), today: NoteMeta.day(now(), timeZone), selfNames: selfNames)
        if let agentic = brain as? AgenticBrain, brain.descriptor.capabilities.contains(.files) {
            let effort: Effort = isBuild ? .high : .medium   // first build thinks hard; nightly merges don't need to
            let ended = FinishBox()
            let tools = FileTools.make(part).map { tool -> Tool in
                switch tool.name {
                case "finish":
                    // finish is the last word: its output ends the brain's loop, which then returns normally with
                    // its usage and turns, so the send log and the cost line see a part that succeeded.
                    return Tool(name: tool.name, description: tool.description, parametersSchema: tool.parametersSchema) { (d: Data) async throws -> ToolOutput in
                        let out = try await tool.run(d); await ended.finish(); return ToolOutput(out.text, endsRun: true)
                    }
                case "write_file", "delete_file":
                    // A write the model still emits after saying it is done is refused, so nothing lands after finish.
                    return Tool(name: tool.name, description: tool.description, parametersSchema: tool.parametersSchema) { (d: Data) async throws -> ToolOutput in
                        if await ended.finished { throw NSError(domain: "FileTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "finish was already called; nothing more is written"]) }
                        return try await tool.run(d)
                    }
                default: return tool
                }
            }
            // Awaited in place, so Stop (the run's cancellation) reaches the brain's loop at its next turn.
            let r = try await agentic.run(AgentTask(system: system, input: input, effort: effort, maxTurns: 200, timeout: 2400), tools: tools) { e in
                switch e {
                case .toolCall(let name, let summary):
                    if name == "write_file", let path = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any], let p = path["path"] as? String { onEvent(.message("Writing \(p)")) }
                    else if name == "write_file" { onEvent(.message("Writing a note…")) }
                    else if name == "finish" { onEvent(.message("Finishing the knowledge base")) }
                    else if name == "read_file" || name == "list_dir" { onEvent(.message("Reading existing notes")) }
                default: onEvent(e)
                }
            }
            return r.usage
        }
        // Single-shot fallback for brains without file tools: emit a file map as JSON.
        let schema = #"{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},"required":["files"]}"#
        let existing = FileTools.listing(staging).prefix(200).joined(separator: "\n")
        let r = try await brain.complete(BrainRequest(system: system + "\n\nYou have no file tools. Reply with JSON {\"files\":[{\"path\":…,\"content\":…}]} containing every file to write or overwrite (full contents).",
                                                     input: "EXISTING FILES:\n\(existing)\n\n" + input, schema: schema, maxOutputTokens: 32_000))
        guard let data = r.jsonData, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let files = obj["files"] as? [[String: Any]] else { throw BrainError.badResponse("no file map") }
        // No read step exists here, so the read-first rule is waived; every other rule and the re-attached front-matter still apply.
        // A refusal is not swallowed: this brain cannot see the rules' state and gets no turn to write again, so each one
        // is logged, shown and counted — and a part whose every note was refused is not done, so its rows are fed again.
        var written = 0, refused = 0
        for f in files {
            guard let p = f["path"] as? String, let c = f["content"] as? String else { continue }
            do { try FileTools.write(part, path: p, content: c, requireRead: false); written += 1 }
            catch let refusal as FileTools.Refusal {
                refused += 1
                log.warn("refused \(p): \(refusal.description)")
                onEvent(.message("Refused \(FileTools.clean(p)): \(refusal.description)"))
            }
        }
        refusals += refused
        if written == 0, refused > 0 { throw Failure.nothingWritten }
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

    /// Whether a directory holds anything worth swapping live: a note, or a folder of them.
    static func hasNotes(_ dir: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.contains { $0.pathExtension == "md" || $0.hasDirectoryPath }
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

/// Whether the brain has said it is done.
private actor FinishBox {
    private(set) var finished = false
    func finish() { finished = true }
}

/// File tools scoped to one directory. Paths are relative; `..` is refused. The brain writes prose and code owns the
/// file: what `read_file` returns is the body with Brownie's front-matter and status block taken out, and what
/// `write_file` lands is that prose with both put back exactly as they were. A write that would break the vault's
/// shape — a blind overwrite, an eleventh root folder, a ninth note in a topic folder, a bloated README, a title
/// that is a period-stamped or near-duplicate copy of another, a second file for a known person — is refused with
/// one sentence saying what to do instead; the agent loop hands that sentence back as the tool's error.
enum FileTools {
    static let maxRootFolders = 10, maxNotesPerFolder = 8, readmeWords = 350
    static let months = "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
    /// The vault's own folders: one file per person or group, never deleted, never counted against the shape's caps.
    static let ownFolders = ["People", "Groups"]

    /// One sentence the brain can act on.
    struct Refusal: Error, CustomStringConvertible, Equatable { let description: String; init(_ s: String) { description = s } }

    /// What one part's tools know: the root, who exists (so `People/` never gets a second file for one person), the
    /// day, and which notes the brain has read so far — an existing note may only be overwritten after it was read.
    /// The roster follows a note the tools bring back from Archive/, so the rest of the part writes it where it now is.
    final class Part: @unchecked Sendable {
        let root: URL, today: String
        /// The user's own names: a People or Groups note titled with one is refused.
        let selfNames: [String]
        private let lock = NSLock()
        private var read = Set<String>()
        private var roster: [Person]
        init(root: URL, people: [Person], today: String, selfNames: [String] = []) { self.root = root; self.roster = people; self.today = today; self.selfNames = SelfNames.clean(selfNames) }
        var people: [Person] { lock.withLock { roster } }
        func markRead(_ p: String) { lock.withLock { _ = read.insert(p) } }
        func hasRead(_ p: String) -> Bool { lock.withLock { read.contains(p) } }
        func forget(_ p: String) { lock.withLock { _ = read.remove(p) } }
        func retarget(from: String, to: String) { lock.withLock { for i in roster.indices where roster[i].notePath == from { roster[i].notePath = to } } }
    }

    static func make(root: URL, people: [Person] = [], today: String = NoteMeta.day(Date(), .current), selfNames: [String] = []) -> [Tool] {
        make(Part(root: root, people: people, today: today, selfNames: selfNames))
    }
    static func make(_ part: Part) -> [Tool] {
        [
            Tool(name: "list_dir", description: "List the notes and folders under a relative path ('' for the root).", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":[]}"#) { data in
                let p = clean((arg(data)["path"] as? String) ?? "")
                return listing(part.root, sub: p).joined(separator: "\n").ifEmpty("(empty)")
            },
            Tool(name: "read_file", description: "Read a note's prose at a relative path. Brownie's front-matter and status block are kept out of what you see and put back when you write, so never write them yourself. An existing note must be read before write_file may overwrite it.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                try read(part, path: arg(data)["path"] as? String ?? "")
            },
            Tool(name: "write_file", description: "Create or overwrite a note at a relative path with its full prose (no front-matter, no status block). `sources` optionally names the apps the note draws on. Refused, with the reason, when the note was not read first, when it would be the eleventh root folder or the ninth note in a folder other than People/ or Groups/, when README.md would pass 350 words or read as an index of folders instead of a portrait of the user, when the title is period-stamped or differs from an existing note only by case or punctuation, when the folder is spelled in another case than the one that exists, when it would be a second People/ note for someone who already has one, or when it would be a People/ or Groups/ note about the user themselves.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}},"required":["path","content"]}"#) { data in
                let a = arg(data)
                return try write(part, path: a["path"] as? String ?? "", content: a["content"] as? String ?? "", sources: a["sources"] as? [String])
            },
            Tool(name: "delete_file", description: "Delete a note at a relative path. Nothing under People/ or Groups/ can be deleted.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                try delete(part, path: arg(data)["path"] as? String ?? "")
            },
            Tool(name: "finish", description: "Call when every note is written. Give a one-line summary.", parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { data in
                "finished: \(arg(data)["summary"] as? String ?? "")"
            },
        ]
    }

    static func arg(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    /// "./People/A.md" and "People/A.md" are one path.
    static func clean(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func resolve(_ root: URL, _ p: String) throws -> URL {
        guard !p.contains(".."), !p.hasPrefix("/"), !p.hasPrefix("~") else { throw Refusal("paths are relative to the knowledge base root; \(p) is not") }
        return root.appendingPathComponent(p)
    }

    /// "people" and "People" are one folder to the Mac's file system, so every rule keyed on a name compares this way.
    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
    static func isOwn(_ folder: String) -> Bool { ownFolders.contains { same(folder, $0) } }
    static func isToday(_ p: String) -> Bool { same(p, TodayNote.path) }

    /// A path whose folder is spelled in another case than the one on disk — or than the vault's own People/, Groups/ and
    /// README.md — is refused naming the spelling to use. The file system would fold "people/Arif.md" onto People/Arif.md,
    /// and every rule keyed on the folder (one file per person, never deleted, the caps, the note's kind) would look the other way.
    static func checkSpelling(_ p: String, parts: [String], root: URL) throws {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            if same(first, "README.md"), first != "README.md" { throw Refusal("the portrait is README.md; spell it so, not \(p)") }
            return
        }
        let rest = parts.dropFirst().joined(separator: "/")
        if let own = ownFolders.first(where: { same(first, $0) }), own != first {
            throw Refusal("the folder is spelled \(own)/; spell it \(own)/\(rest), not \(p)")
        }
        if let existing = rootFolders(of: root).first(where: { same(first, $0) }), existing != first {
            throw Refusal("\(existing)/ already exists and \(p) differs from it only by case; spell it \(existing)/\(rest)")
        }
    }

    /// The spellings a person's note carries as aliases: names only. A chat label's phone number or parenthesised suffix
    /// goes (PersonKey.displayName), and a label that is a handle rather than a name — an address, a JID, an @name, bare
    /// digits — is no alias at all; the registry keeps handles on its own. The title itself is not repeated.
    static func nameAliases(of person: Person, title: String) -> [String] {
        dedupe(([person.name] + person.aliases).map(PersonKey.displayName).filter { a in
            !a.contains("@") && !a.contains(":") && !PersonKey.normalise(a).isEmpty && !same(a, title)
        })
    }

    // MARK: read

    static func read(_ part: Part, path: String) throws -> String {
        let p = clean(path)
        let url = try resolve(part.root, p)
        guard !isToday(p) else { throw Refusal("Today.md is Brownie's own checklist for the phone, not a note; leave it alone") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Refusal("there is no file at \(p); list_dir shows what exists") }
        let raw = try String(contentsOf: url, encoding: .utf8)
        part.markRead(p)
        guard Vault.isNote(p) else { return raw }
        return NoteStatus.strip(NoteMeta.parse(raw, path: p).body)
    }

    // MARK: write

    /// The path a write lands on once the note it names is back from Archive/. The roster still sends the brain to
    /// `People/Archive/X.md` for a person archived since, and a brain that knows better writes `People/X.md`: either
    /// way the note comes back first — the file moved to its active path, the part's roster retargeted (the live
    /// registry follows at the seed after the swap, when the archived path is gone and the active one is claimed by
    /// its title), the brain's read of the archived spelling carried over — and the write goes on as an update of the
    /// one note. So no refusal ever names a path the tools would refuse: what is refused, if anything, is a write of
    /// the active path the brain has not read, and that path can be read.
    static func broughtBack(_ part: Part, _ p: String) throws -> String {
        let fm = FileManager.default
        func back(_ archived: String) throws -> String {
            let active = NoteArchive.activePath(archived)
            guard NoteArchive.move(archived, to: active, under: part.root) != nil else {
                throw Refusal("\(active) already exists beside the archived \(archived); write about them in \(active)")
            }
            part.retarget(from: archived, to: active)
            if part.hasRead(archived) { part.markRead(active); part.forget(archived) }
            return active
        }
        if NoteArchive.isArchived(p), fm.fileExists(atPath: try resolve(part.root, p).path) { return try back(p) }
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count == 2, same(parts[0], "People") else { return p }
        let title = String(parts[1].dropLast(3)), people = part.people
        if let id = PersonRegistry.resolve(label: title, handle: nil, among: people), let np = people.first(where: { $0.id == id })?.notePath,
           NoteArchive.isArchived(np), fm.fileExists(atPath: part.root.appendingPathComponent(np).path) { _ = try back(np) }
        return p
    }

    /// The guarded write. `requireRead` is off only for brains without file tools, which have no way to read first.
    @discardableResult
    static func write(_ part: Part, path: String, content: String, sources: [String]? = nil, requireRead: Bool = true) throws -> String {
        let fm = FileManager.default, named = clean(path)
        guard !isToday(named) else { throw Refusal("Today.md is Brownie's own checklist for the phone and is never written by the brain") }
        guard Vault.isNote(named) else { throw Refusal("notes are Markdown files (.md) in visible folders; \(named) is not one") }
        let p = try broughtBack(part, named)
        let url = try resolve(part.root, p)
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count <= 2 else { throw Refusal("notes live one level deep (Folder/Note.md); \(p) is nested deeper") }
        try checkSpelling(p, parts: parts, root: part.root)
        let folder = parts.count == 2 ? parts[0] : "", title = String(parts.last!.dropLast(3))
        // The user is never a person or a group in their own vault — said before any rule about the title's shape, since it is the reason that helps.
        if isOwn(folder), SelfNames.isSelf(title, among: part.selfNames) {
            throw Refusal("That is you — what is about you belongs in a topic note under Life/ or Work/, never in People/")
        }
        // Spelled exactly: the Mac's file system would say "invoices.md" exists when only "Invoices.md" does, and that is a duplicate, not an overwrite.
        let siblings = notes(in: folder, of: part.root)
        let exists = siblings.contains(title)

        // One note per subject: a period-stamped title, or one that differs from a neighbour only by case, punctuation or such a suffix, goes into the note that exists.
        if let bare = periodStripped(title), !exists {
            let existing = siblings.first { sameTitle($0, bare) || sameTitle($0, title) }.map { notePath(folder, $0) } ?? notePath(folder, bare)
            throw Refusal("\"\(title)\" is a period-stamped title; keep one note per subject and write the dated section into \(existing) instead")
        }
        if !exists, let dup = siblings.first(where: { $0 != title && sameTitle($0, title) }) {
            throw Refusal("\(p) differs from \(notePath(folder, dup)) only by case, punctuation or a date suffix; write into \(notePath(folder, dup)) instead")
        }
        // One file per person, whatever the spelling: the registry says where they are written.
        let person = same(folder, "People") ? PersonRegistry.resolve(label: title, handle: nil, among: part.people).flatMap { id in part.people.first { $0.id == id } } : nil
        if !exists, let person, let np = person.notePath, np != p, fm.fileExists(atPath: part.root.appendingPathComponent(np).path) {
            throw Refusal("\(person.name) already has a note at \(np); write about them there, not in \(p)")
        }
        // The vault's shape: ten root folders, eight notes in any folder — People/ and Groups/ are the vault's own and count towards neither.
        if !exists, !folder.isEmpty, !isOwn(folder), !fm.fileExists(atPath: part.root.appendingPathComponent(folder).path) {
            let have = rootFolders(of: part.root)
            if have.count >= maxRootFolders { throw Refusal("the knowledge base already has its \(maxRootFolders) root folders (\(have.joined(separator: ", "))); put this note in one of them instead of creating \(folder)/") }
        }
        if !exists, !isOwn(folder), siblings.count >= maxNotesPerFolder {
            throw Refusal("\(folder.isEmpty ? "the root" : folder + "/") already holds \(maxNotesPerFolder) notes (\(siblings.sorted().joined(separator: ", "))); fold this into one of them instead of adding a ninth")
        }
        // The map stays short: what lives where and the last few updates, never a growing log.
        if same(p, "README.md") {
            let words = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            if words > readmeWords { throw Refusal("README.md would be \(words) words; the map stays under \(readmeWords) — keep one line per folder and three to five recent updates") }
        }
        // Never a blind overwrite: the brain must have seen the note it replaces in this part.
        if exists, requireRead, !part.hasRead(p) { throw Refusal("read \(p) before overwriting it") }

        // The brain's prose only — front-matter or a status block it wrote anyway are dropped; code puts the real ones back.
        let body = NoteStatus.strip(NoteMeta.parse(content, path: p).body)
        let text: String
        if exists {
            let (old, oldBody) = NoteMeta.parse(try String(contentsOf: url, encoding: .utf8), path: p)
            var meta = old ?? NoteMeta(brownie: NoteMeta.kind(forPath: p), created: part.today, updated: part.today)
            if meta.created.isEmpty { meta.created = part.today }
            if meta.bodyDiffers(oldBody) { meta.userEdited = true }   // an outside edit noticed now is remembered
            if let sources { meta.sources = dedupe(sources) }
            let hash = NoteMeta.hash(body)
            if hash != meta.contentHash || meta.updated.isEmpty { meta.updated = part.today }
            meta.contentHash = hash
            text = meta.render() + (NoteStatus.extract(from: oldBody).map { NoteStatus.insert($0, into: body) } ?? body)
        } else {
            let aliases = person.map { nameAliases(of: $0, title: title) } ?? []
            text = NoteMeta.fresh(path: p, body: body, today: part.today, id: person?.id, aliases: aliases, sources: dedupe(sources ?? [])).render() + body
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        part.markRead(p)
        return "wrote \(p) (\(body.utf8.count) bytes)"
    }

    // MARK: delete

    static func delete(_ part: Part, path: String) throws -> String {
        let p = clean(path)
        let url = try resolve(part.root, p)
        guard Vault.isNote(p), !isToday(p) else { throw Refusal("only notes can be deleted; \(p) is not one") }
        let parts = p.split(separator: "/").map(String.init)
        // Whatever case the path is spelled in: the file system would find the note under its real folder.
        if let folder = parts.first, parts.count > 1, isOwn(folder) {
            throw Refusal("notes under People/ and Groups/ are never deleted by the brain; leave \(p) and write in the note that fits, or fold the facts in and leave the file")
        }
        try checkSpelling(p, parts: parts, root: part.root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Refusal("there is no note at \(p)") }
        try FileManager.default.removeItem(at: url)
        part.forget(p)
        return "deleted \(p)"
    }


    // MARK: titles and shape

    /// "Invoices (Sep–Nov 2026)" → "Invoices", "Goa (2026)" → "Goa"; nil when the title carries no period.
    static func periodStripped(_ title: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"\s*\((\#(months)[–-]\w{3} \d{4}|\#(months) \d{4}|\d{4})\)\s*$"#)
        let r = NSRange(title.startIndex..., in: title)
        guard let m = re.firstMatch(in: title, range: r), let range = Range(m.range, in: title) else { return nil }
        let bare = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? nil : bare
    }
    /// Case, punctuation and a period suffix fold away; what is left is what a title is.
    static func titleKey(_ t: String) -> String {
        let bare = periodStripped(t) ?? t
        return bare.lowercased().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
    static func sameTitle(_ a: String, _ b: String) -> Bool { let ka = titleKey(a); return !ka.isEmpty && ka == titleKey(b) }
    static func notePath(_ folder: String, _ title: String) -> String { folder.isEmpty ? title + ".md" : folder + "/" + title + ".md" }
    static func dedupe(_ xs: [String]) -> [String] { xs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    /// The titles of the notes directly in a folder ("" for the root).
    static func notes(in folder: String, of root: URL) -> [String] {
        let dir = folder.isEmpty ? root : root.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { Vault.isNote(notePath(folder, String($0.dropLast(3)))) && $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
    }
    static func rootFolders(of root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") && (try? root.appendingPathComponent($0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted()
    }

    static func listing(_ root: URL, sub: String = "") -> [String] {
        // Standardised on both sides: the enumerator may spell a symlinked root (/var → /private/var) differently.
        let root = root.standardizedFileURL
        let base = root.appendingPathComponent(sub)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if rel == TodayNote.path { continue }   // Brownie's checklist for the phone is not knowledge
            if NoteArchive.isArchived(rel) || NoteArchive.isArchived(rel + "/") { continue }   // quiet people rest out of the brain's sight until named again
            out.append((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? rel + "/" : rel)
        }
        return out.sorted()
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }
