import Foundation
import Domain
import Support

/// Part 1: hermetic, no tools. Summaries (+ calendar text + clock + standing instructions) → ranked candidates.
public struct Judge: Sendable {
    public static let schema = #"{"type":"object","properties":{"action_items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"action":{"type":"string"},"importance":{"type":"string"},"dueDate":{"type":["string","null"]},"sources":{"type":"array","items":{"type":"string"}},"urgency":{"type":"string","enum":["high","medium","low"]},"loopID":{"type":["string","null"]},"cameBack":{"type":"boolean"}},"required":["title","action","importance","dueDate","sources","urgency","loopID","cameBack"]}},"loops":{"type":"array","items":{"type":"object","properties":{"person":{"type":"string"},"direction":{"type":"string","enum":["mine","theirs"]},"what":{"type":"string"},"quote":{"type":"string"},"source":{"type":"string"},"due":{"type":["string","null"]}},"required":["person","direction","what","quote","source","due"]}},"loop_updates":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"status":{"type":"string","enum":["open","closed"]},"how":{"type":"string"}},"required":["id","status","how"]}}},"required":["action_items","loops","loop_updates"]}"#

    /// What the judge found besides the items: new loops and closures of tracked ones.
    public struct Findings: Sendable {
        public var items: [ActionItem]
        public var newLoops: [Loop]
        public var updates: [(idPrefix: String, closed: Bool, how: String)]
    }

    private let brain: any Brain
    private let template: String
    private let clock: Clock
    private let log = Log("proactive.judge")

    public init(brain: any Brain, clock: Clock = SystemClock(), bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.clock = clock
        template = try String(contentsOf: bundle.url(forResource: "judge", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "judge", withExtension: "md")!, encoding: .utf8)
    }

    public func findActionItems(summaries: [SummaryRecord], calendar: String?, instructions: String, max: Int = 8) async throws -> ([ActionItem], Usage) {
        let (f, u) = try await judge(summaries: summaries, calendar: calendar, instructions: instructions, openLoops: [], max: max)
        return (f.items, u)
    }

    public func judge(summaries: [SummaryRecord], calendar: String?, instructions: String, openLoops: [Loop], max: Int = 8) async throws -> (Findings, Usage) {
        guard !summaries.isEmpty else { return (Findings(items: [], newLoops: [], updates: []), .zero) }
        let corpus = Self.trim(summaries.enumerated().map { Self.line($1, $0 + 1) }.joined(separator: "\n"), to: BrainLimits.corpusPartBudget)
        var p = template
        p = p.replacingOccurrences(of: "{{max}}", with: String(max))
        p = p.replacingOccurrences(of: "{{now}}", with: Self.now(clock))
        p = p.replacingOccurrences(of: "{{calendar}}", with: calendar.map { "THE USER'S LIVE CALENDAR (last 7 days + next 24 hours):\n\($0)\n" } ?? "")
        p = p.replacingOccurrences(of: "{{instructions}}", with: instructions.isEmpty ? "" : "THE USER'S STANDING INSTRUCTIONS (honour these about what to surface or skip; they never override accuracy):\n\(instructions)\n")
        p = p.replacingOccurrences(of: "{{summaries}}", with: corpus)
        p = p.replacingOccurrences(of: "{{loops}}", with: openLoops.isEmpty ? "" : "OPEN LOOPS BROWNIE ALREADY TRACKS (report only closures, in loop_updates, by id):\n" + openLoops.map(\.judgeLine).joined(separator: "\n") + "\n")
        let r = try await brain.complete(BrainRequest(system: "You return only the JSON the user asks for.", input: p, schema: Self.schema, effort: .high, maxOutputTokens: 8000, timeout: 1200))
        guard let data = r.jsonData, let obj = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw BrainError.badResponse("judge returned no JSON") }
        let now = clock.now()
        let loops = (obj.loops ?? []).compactMap { l -> Loop? in
            guard !l.person.isEmpty, !l.what.isEmpty else { return nil }
            return Loop(direction: l.direction == "mine" ? .mine : .theirs, person: l.person, what: l.what, quote: l.quote, sourceLabel: l.source, due: l.due, openedAt: now)
        }
        let updates = (obj.loop_updates ?? []).map { (idPrefix: $0.id, closed: $0.status == "closed", how: $0.how) }
        log.info("judge: \(obj.action_items.count) candidates, \(loops.count) new loops, \(updates.count) loop updates from \(summaries.count) summaries")
        return (Findings(items: Array(obj.action_items.prefix(max)), newLoops: loops, updates: updates), r.usage)
    }

    struct Wrapper: Decodable {
        let action_items: [ActionItem]
        let loops: [RawLoop]?
        let loop_updates: [RawUpdate]?
        struct RawLoop: Decodable { let person: String; let direction: String; let what: String; let quote: String; let source: String; let due: String? }
        struct RawUpdate: Decodable { let id: String; let status: String; let how: String }
    }

    static func line(_ s: SummaryRecord, _ i: Int) -> String {
        let date = s.itemDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "undated"
        return "#\(i) · [\(s.source.rawValue)] \(s.bucketName) · \(date)\n\(s.title) — \(s.text)"
    }

    static func now(_ clock: Clock) -> String {
        let f = DateFormatter(); f.timeZone = clock.timeZone; f.dateFormat = "EEEE d MMMM yyyy 'at' h:mm a (zzz)"
        return f.string(from: clock.now())
    }

    /// Oldest dropped first: summaries arrive newest-first, so trim from the end.
    static func trim(_ s: String, to bytes: Int) -> String {
        guard s.utf8.count > bytes else { return s }
        return String(decoding: s.utf8.prefix(bytes), as: UTF8.self) + "\n…(older summaries omitted)"
    }
}
