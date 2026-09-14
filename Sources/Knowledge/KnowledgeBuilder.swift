import Foundation
import Domain
import Platform
import Support

/// Builds (first time) or updates (every run) the KB with the brain, in a staging directory that is
/// atomically swapped into place on success. Resumable across usage limits and restarts.
public actor KnowledgeBuilder {
    public struct ResumeToken: Codable, Sendable, Equatable {
        public var stagingPath: String
        public var sliceIndex: Int
        public var fingerprint: String
        public var isBuild: Bool
    }
    public enum Failure: Error { case brainMissing, staleSwapAverted, nothingWritten }

    private let brain: any Brain
    private let store: any KnowledgeStore
    private let runStore: any RunStore
    private let log = Log("kb.builder")
    private let buildPrompt: String, updatePrompt: String

    public init(brain: any Brain, store: any KnowledgeStore, runStore: any RunStore, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.store = store; self.runStore = runStore
        buildPrompt = try String(contentsOf: bundle.url(forResource: "build", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "build", withExtension: "md")!, encoding: .utf8)
        updatePrompt = try String(contentsOf: bundle.url(forResource: "update", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "update", withExtension: "md")!, encoding: .utf8)
    }

    /// Build or update depending on whether a KB exists. Returns usage.
    public func sync(summaries: [SummaryRecord], progress: @escaping @Sendable (RunProgress) -> Void, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Usage {
        guard !summaries.isEmpty else { return .zero }
        let isBuild = !(await store.exists())
        let parts = CorpusSlicer.slice(summaries)
        let fm = FileManager.default

        // resume?
        var token = try await loadToken()
        if let t = token, !fm.fileExists(atPath: t.stagingPath) { token = nil }
        let staging: URL
        if let t = token { staging = URL(fileURLWithPath: t.stagingPath); log.info("resuming at part \(t.sliceIndex + 1)/\(parts.count)") }
        else {
            staging = try newStagingDir(seedFromLive: !isBuild)
            token = ResumeToken(stagingPath: staging.path, sliceIndex: 0, fingerprint: isBuild ? "" : (try await store.fingerprint()), isBuild: isBuild)
            try await saveToken(token)
        }
        var usage = Usage.zero
        for i in (token!.sliceIndex)..<parts.count {
            progress(RunProgress(stage: .synthesising, partIndex: i + 1, partCount: parts.count))
            let system = (isBuild && i == 0) ? buildPrompt : updatePrompt
            usage = usage + (try await runPart(system: system, corpus: parts[i], in: staging, onEvent: onEvent))
            token!.sliceIndex = i + 1
            try await saveToken(token)
        }
        // verify + swap
        let written = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" || $0.hasDirectoryPath }
        guard !written.isEmpty else { throw Failure.nothingWritten }
        if !isBuild, try await store.fingerprint() != token!.fingerprint {
            try? fm.removeItem(at: staging); try await saveToken(nil)
            log.warn("user edited the KB during the run — swap averted, will retry next run")
            throw Failure.staleSwapAverted
        }
        try swap(staging)
        try await saveToken(nil)
        log.info("KB \(isBuild ? "built" : "updated"): \(parts.count) part(s)")
        return usage
    }

    // MARK: agent turn

    private func runPart(system: String, corpus: String, in staging: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Usage {
        let input = "Working directory: the knowledge base root (use relative paths).\n\nSUMMARIES:\n\n" + corpus
        if let agentic = brain as? AgenticBrain, brain.descriptor.capabilities.contains(.files) {
            let effort: Effort = system == buildPrompt ? .high : .medium   // first build thinks hard; nightly merges don't need to
            let result = try await agentic.run(AgentTask(system: system, input: input, effort: effort, maxTurns: 200, timeout: 2400), tools: FileTools.make(root: staging)) { e in
                switch e {
                case .toolCall(let name, let summary):
                    if name == "write_file", let path = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any], let p = path["path"] as? String { onEvent(.message("Writing \(p)")) }
                    else if name == "write_file" { onEvent(.message("Writing a note…")) }
                    else if name == "finish" { onEvent(.message("Finishing the knowledge base")) }
                    else if name == "read_file" || name == "list_dir" { onEvent(.message("Reading existing notes")) }
                default: onEvent(e)
                }
            }
            return result.usage
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

    // MARK: staging + swap

    private func newStagingDir(seedFromLive: Bool) throws -> URL {
        let fm = FileManager.default
        let parent = store.rootURL.deletingLastPathComponent()
        // sweep orphans
        for u in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent.hasPrefix(".brownie-kb-staging-") { try? fm.removeItem(at: u) }
        let dir = parent.appendingPathComponent(".brownie-kb-staging-\(UUID().uuidString)", isDirectory: true)
        if seedFromLive, fm.fileExists(atPath: store.rootURL.path) { try fm.copyItem(at: store.rootURL, to: dir) }
        else { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
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

    private func loadToken() async throws -> ResumeToken? {
        guard let s = try await runStore.value(SettingKey.kbResume), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResumeToken.self, from: d)
    }
    private func saveToken(_ t: ResumeToken?) async throws {
        try await runStore.setValue(SettingKey.kbResume, t.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) })
    }
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
        let base = root.appendingPathComponent(sub)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            let rel = String(u.path.dropFirst(root.path.count + 1))
            out.append((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? rel + "/" : rel)
        }
        return out.sorted()
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }
