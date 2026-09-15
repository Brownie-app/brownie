import Foundation
import Domain
import Support

/// Part 2: verify & prepare, read-only. Tools: search/read the KB. Output: ready cards.
public struct Preparer: Sendable {
    private let brain: any Brain
    private let knowledge: any KnowledgeStore
    private let clock: Clock
    private let template: String
    private let log = Log("proactive.prepare")

    public init(brain: any Brain, knowledge: any KnowledgeStore, clock: Clock = SystemClock(), bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.knowledge = knowledge; self.clock = clock
        template = try String(contentsOf: bundle.url(forResource: "prepare", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "prepare", withExtension: "md")!, encoding: .utf8)
    }

    public func prepare(candidates: [ActionItem], summaries: [SummaryRecord], instructions: String, max: Int = 5,
                        onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> ([Card], Usage) {
        guard !candidates.isEmpty else { return ([], .zero) }
        var p = template
        p = p.replacingOccurrences(of: "{{max}}", with: String(max))
        p = p.replacingOccurrences(of: "{{now}}", with: Judge.now(clock))
        p = p.replacingOccurrences(of: "{{instructions}}", with: instructions.isEmpty ? "" : "THE USER'S STANDING INSTRUCTIONS:\n\(instructions)\n")
        let cand = candidates.enumerated().map { i, c in "\(i + 1). \(c.title) [\(c.urgency.rawValue)] — \(c.action)\n   why: \(c.importance)\n   due: \(c.dueDate ?? "—") · sources: \(c.sources.joined(separator: ", "))" + (c.loopID.map { " · loopID: \($0)" } ?? "") + (c.owner.map { " · HOUSEHOLD, owner: \($0)" } ?? "") + ((c.cameBack ?? false) ? " · CAME BACK: the user already sent one message about this and got no answer" : "") }.joined(separator: "\n")
        p = p.replacingOccurrences(of: "{{candidates}}", with: cand)
        p = p.replacingOccurrences(of: "{{summaries}}", with: Judge.trim(summaries.enumerated().map { Judge.line($1, $0 + 1) }.joined(separator: "\n"), to: BrainLimits.corpusPartBudget / 2))

        let box = FinishBox()
        let tools = [
            Tool(name: "search_notes", description: "Full-text search the user's knowledge base. Returns matching note paths and the first lines.", parametersSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#) { data in
                let q = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["query"] as? String ?? ""
                let notes = try await knowledge.search(q, limit: 8)
                return notes.isEmpty ? "(no matches)" : notes.map { "\($0.relativePath)\n\($0.body.prefix(300))" }.joined(separator: "\n---\n")
            },
            Tool(name: "read_note", description: "Read one note by its relative path.", parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
                let path = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["path"] as? String ?? ""
                return try await knowledge.note(at: path)?.body ?? "(no such note)"
            },
            Tool(name: "finish", description: "Return the finished cards as JSON (see instructions).", parametersSchema: #"{"type":"object","properties":{"cards":{"type":"array"},"dropped":{"type":"array"}},"required":["cards"]}"#) { data in
                await box.set(data); return "recorded"
            },
        ]
        let usage: Usage
        var payload: Data?
        if let agentic = brain as? AgenticBrain, brain.descriptor.capabilities.contains(.tools) {
            let r = try await agentic.run(AgentTask(system: "You verify and prepare cards. Use the tools, then call finish exactly once.", input: p, effort: .high, maxTurns: 40), tools: tools, onEvent: onEvent)
            usage = r.usage; payload = await box.data ?? r.finalText.data(using: .utf8)
        } else {
            let r = try await brain.complete(BrainRequest(system: "You have no tools; verify from the summaries alone and mark items unverified where you cannot. Reply with the finish JSON only.", input: p, effort: .high, maxOutputTokens: 12_000, timeout: 1200))
            usage = r.usage; payload = r.jsonData
        }
        guard let payload, let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw BrainError.badResponse("prepare returned no JSON") }
        let raw = obj["cards"] as? [[String: Any]] ?? []
        let made = raw.prefix(max).compactMap { d -> (Card, [String: Any])? in Self.card(from: d, now: clock.now()).map { ($0, d) } }
        let cards = Self.withOwners(made.map(\.0), from: made.map(\.1), candidates: candidates).sorted { $0.urgency > $1.urgency }
        log.info("prepared \(cards.count) cards from \(candidates.count) candidates")
        return (cards, usage)
    }

    static func card(from d: [String: Any], now: Date) -> Card? {
        guard let title = d["title"] as? String, let recipeD = d["recipe"] as? [String: Any], let recipe = recipe(from: recipeD) else { return nil }
        let ev = (d["evidence"] as? [[String: Any]] ?? []).map { Evidence(source: $0["source"] as? String ?? "", when: $0["when"] as? String ?? "", text: $0["text"] as? String ?? "") }
        return Card(id: UUID().uuidString, title: title, sourceLabel: d["sourceLabel"] as? String ?? recipe.channelName, why: d["why"] as? String ?? "",
                    actionLabel: d["actionLabel"] as? String ?? "Do it", dueLine: d["dueLine"] as? String ?? "", urgency: Urgency(rawValue: d["urgency"] as? String ?? "medium") ?? .medium,
                    draftLabel: d["draftLabel"] as? String ?? "Draft", draft: d["draft"] as? String ?? "", recipe: recipe, evidence: ev,
                    verification: (d["verification"] as? String) == "verified" ? .verified : .unverified, verifiedLine: d["verifiedLine"] as? String ?? "", createdAt: now,
                    cameBack: d["cameBack"] as? Bool, loopID: (d["loopID"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 })
    }
    /// The candidate's owner rides onto its card: the preparer is told to copy it, and if it forgets, the candidate's own value stands.
    static func withOwners(_ cards: [Card], from raw: [[String: Any]], candidates: [ActionItem]) -> [Card] {
        zip(cards, raw).map { c, d in
            var c = c
            c.owner = Judge.cleanOwner(d["owner"] as? String) ?? candidates.first { $0.loopID != nil && $0.loopID == c.loopID }?.owner ?? candidates.first { $0.title == c.title }?.owner
            return c
        }
    }

    static func recipe(from r: [String: Any]) -> Recipe? {
        let s = { (k: String) in r[k] as? String ?? "" }
        let att = r["attachments"] as? [String] ?? []
        switch r["kind"] as? String {
        case "imessage": return .imessage(to: s("to"), body: s("body"), attachments: att)
        case "whatsapp": return .whatsapp(chat: s("chat"), body: s("body"), phone: (r["phone"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "mail": return .mail(to: s("to"), subject: s("subject"), body: s("body"), attachments: att)
        case "calendar": return .calendar(title: s("title"), startISO: s("startISO"), endISO: s("endISO"), notes: s("notes"))
        case "note": return .note(relativePath: s("relativePath"), body: s("body"))
        case "browser": return .browser(url: s("url"))
        case "computerUse": return .computerUse(goal: s("goal"))
        default: return nil
        }
    }
}

actor FinishBox { var data: Data?; func set(_ d: Data) { data = d } }
