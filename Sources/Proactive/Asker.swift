import Foundation
import Domain
import Support

/// "Ask": one question, answered from the notes with citations that open the original.
public struct Asker: Sendable {
    public struct Citation: Codable, Sendable, Identifiable, Equatable { public var id: Int { n }; public let n: Int; public let kind: String; public let label: String; public let ref: String }
    public struct Action: Codable, Sendable, Equatable { public let label: String; public let kind: String; public let ref: String }
    public struct Answer: Codable, Sendable, Equatable {
        public let question: String
        public let answer: String
        public let citations: [Citation]
        public let actions: [Action]
        public let at: Date
    }
    private let brain: any Brain
    private let knowledge: any KnowledgeStore
    private let clock: Clock
    private let template: String

    public init(brain: any Brain, knowledge: any KnowledgeStore, clock: Clock = SystemClock(), bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.knowledge = knowledge; self.clock = clock
        template = try String(contentsOf: bundle.url(forResource: "ask", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "ask", withExtension: "md")!, encoding: .utf8)
    }

    public func ask(_ question: String, loops: [Loop], cards: [Card], onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (Answer, Usage) {
        var p = template
        // The likely notes go in with the question, so most answers take one round-trip instead of four.
        onProgress("Searching your notes…")
        let found = (try? await knowledge.search(question, limit: 5)) ?? []
        let foundBlock = found.isEmpty ? "(no note matched the words of the question — use search_notes with other words, or a person's name)"
            : found.map { "### \($0.relativePath)\n\($0.body.prefix(2500))" }.joined(separator: "\n\n")
        p = p.replacingOccurrences(of: "{{found}}", with: foundBlock)
        p = p.replacingOccurrences(of: "{{now}}", with: Judge.now(clock))
        p = p.replacingOccurrences(of: "{{question}}", with: question)
        p = p.replacingOccurrences(of: "{{loops}}", with: loops.isEmpty ? "(none)" : loops.map { "- id \($0.id): \($0.direction == .mine ? "you → \($0.person)" : "\($0.person) → you"): \($0.what) · said \($0.sourceLabel)" }.joined(separator: "\n"))
        p = p.replacingOccurrences(of: "{{cards}}", with: cards.isEmpty ? "(none)" : cards.map { "- id \($0.id): \($0.title) — \($0.why)" }.joined(separator: "\n"))
        let box = FinishBox()
        let tools = [
            Tool(name: "search_notes", description: "Full-text search the knowledge base. Returns note paths and first lines.", parametersSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#) { data in
                let q = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["query"] as? String ?? ""
                let notes = try await knowledge.search(q, limit: 8)
                return notes.isEmpty ? "(no matches)" : notes.map { "\($0.relativePath)\n\($0.body.prefix(400))" }.joined(separator: "\n---\n")
            },
            Tool(name: "read_note", description: "Read one note by its relative path.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                let path = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["path"] as? String ?? ""
                return try await knowledge.note(at: path)?.body ?? "(no such note)"
            },
            Tool(name: "finish", description: "Return the answer as JSON (see instructions).", parametersSchema: #"{"type":"object","properties":{"answer":{"type":"string"},"citations":{"type":"array"},"actions":{"type":"array"}},"required":["answer","citations"]}"#) { data in await box.set(data); return "recorded" },
        ]
        var payload: Data?
        let usage: Usage
        if let agentic = brain as? AgenticBrain, brain.descriptor.capabilities.contains(.tools) {
            let r = try await agentic.run(AgentTask(system: "You answer from the user's notes with citations. If the notes already given answer the question, call finish immediately; otherwise use the tools first. Call finish exactly once.", input: p, effort: .low, maxTurns: 8, timeout: 120), tools: tools, onEvent: { e in
                switch e {
                case .toolCall(let name, let summary):
                    let arg = Self.firstArgument(summary)
                    onProgress(name == "search_notes" ? "Searching for “\(arg)”…" : name == "read_note" ? "Reading \(arg)…" : "Writing the answer…")
                default: break
                }
            })
            usage = r.usage; payload = await box.data ?? r.finalText.data(using: .utf8)
        } else {
            onProgress("Writing the answer…")
            let r = try await brain.complete(BrainRequest(system: "You answer from the notes given, with citations, and reply with the finish JSON only. You have no tools.", input: p, effort: .low, maxOutputTokens: 3000, timeout: 240))
            usage = r.usage; payload = r.jsonData
        }
        guard let payload, let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let text = obj["answer"] as? String else { throw BrainError.badResponse("ask returned no answer") }
        let cites = (obj["citations"] as? [[String: Any]] ?? []).compactMap { d -> Citation? in
            guard let n = d["n"] as? Int else { return nil }
            return Citation(n: n, kind: d["kind"] as? String ?? "note", label: d["label"] as? String ?? "", ref: d["ref"] as? String ?? "")
        }
        let actions = (obj["actions"] as? [[String: Any]] ?? []).compactMap { d -> Action? in
            guard let l = d["label"] as? String else { return nil }
            return Action(label: l, kind: d["kind"] as? String ?? "note", ref: d["ref"] as? String ?? "")
        }
        return (Answer(question: question, answer: text, citations: cites, actions: actions, at: clock.now()), usage)
    }
}

/// What the ⌘⇧Space bar does with a line of text: a question is answered from the notes; anything else is a goal for Hands (or a recipe's name).
public enum CommandIntent: Sendable, Equatable {
    case question(String), goal(String)

    /// A question ends with `?` or starts with a question word (what / who / when / did / where / how / why / which / is / are / do / does / have / has / am / was / were / will / should / can / could / any).
    public static func classify(_ text: String) -> CommandIntent {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isQuestion(t) ? .question(t) : .goal(t)
    }

    public static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") || t.hasSuffix("？") { return true }
        let first = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).first.map(String.init) ?? ""
        return questionWords.contains(first) || first.hasPrefix("what'") || first.hasPrefix("who'") || first.hasPrefix("when'") || first.hasPrefix("where'") || first.hasPrefix("how'")
    }

    static let questionWords: Set<String> = [
        "what", "who", "whom", "whose", "when", "where", "why", "how", "which",
        "did", "do", "does", "is", "are", "am", "was", "were", "have", "has", "had",
        "will", "would", "should", "can", "could", "any", "anything", "anyone",
    ]
}

extension Asker {
    /// The first string value in a tool's JSON arguments, for the progress line: {"query":"nayan"} → nayan.
    static func firstArgument(_ json: String) -> String {
        if let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let v = o.values.compactMap({ $0 as? String }).first { return v }
        return json.trimmingCharacters(in: CharacterSet(charactersIn: "{}\" "))
    }
}
