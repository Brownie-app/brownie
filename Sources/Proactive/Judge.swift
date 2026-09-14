import Foundation
import Domain
import Support

/// Part 1: hermetic, no tools. Summaries (+ calendar text + clock + standing instructions) → ranked candidates.
public struct Judge: Sendable {
    public static let schema = #"{"type":"object","properties":{"action_items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"action":{"type":"string"},"importance":{"type":"string"},"dueDate":{"type":["string","null"]},"sources":{"type":"array","items":{"type":"string"}},"urgency":{"type":"string","enum":["high","medium","low"]}},"required":["title","action","importance","dueDate","sources","urgency"]}}},"required":["action_items"]}"#

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
        guard !summaries.isEmpty else { return ([], .zero) }
        let corpus = Self.trim(summaries.enumerated().map { Self.line($1, $0 + 1) }.joined(separator: "\n"), to: BrainLimits.corpusPartBudget)
        var p = template
        p = p.replacingOccurrences(of: "{{max}}", with: String(max))
        p = p.replacingOccurrences(of: "{{now}}", with: Self.now(clock))
        p = p.replacingOccurrences(of: "{{calendar}}", with: calendar.map { "THE USER'S LIVE CALENDAR (last 7 days + next 24 hours):\n\($0)\n" } ?? "")
        p = p.replacingOccurrences(of: "{{instructions}}", with: instructions.isEmpty ? "" : "THE USER'S STANDING INSTRUCTIONS (honour these about what to surface or skip; they never override accuracy):\n\(instructions)\n")
        p = p.replacingOccurrences(of: "{{summaries}}", with: corpus)
        let r = try await brain.complete(BrainRequest(system: "You return only the JSON the user asks for.", input: p, schema: Self.schema, effort: .high, maxOutputTokens: 8000, timeout: 1200))
        guard let data = r.jsonData, let obj = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw BrainError.badResponse("judge returned no JSON") }
        log.info("judge: \(obj.action_items.count) candidates from \(summaries.count) summaries")
        return (Array(obj.action_items.prefix(max)), r.usage)
    }

    struct Wrapper: Decodable { let action_items: [ActionItem] }

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
