import Foundation
import Domain
import Support

/// The loops ledger: merges what the judge found with what is already tracked. Pure functions,
/// so the rules are testable: no duplicate loops, closures by id, came-back counting.
public enum LoopLedger {
    /// Applies one night's findings. New loops that match an open one (same person, same promise) are dropped.
    public static func merge(existing: [Loop], found: [Loop], updates: [(idPrefix: String, closed: Bool, how: String)], items: [ActionItem], now: Date) -> [Loop] {
        var loops = existing
        for u in updates where u.closed {
            if let i = loops.firstIndex(where: { $0.id.hasPrefix(u.idPrefix) && $0.status == .open }) {
                loops[i].status = .closed; loops[i].closedAt = now; loops[i].closedHow = u.how
            }
        }
        for f in found where !loops.contains(where: { $0.status == .open && same($0, f) }) { loops.append(f) }
        for it in items where it.cameBack == true {
            if let id = it.loopID, let i = loops.firstIndex(where: { $0.id.hasPrefix(id) }) { loops[i].cameBackCount += 1 }
        }
        // Keep the ledger small: closed loops fall off after 30 days.
        loops.removeAll { l in l.status != .open && now.timeIntervalSince(l.closedAt ?? l.openedAt) > 30 * 86400 }
        return loops
    }

    static func same(_ a: Loop, _ b: Loop) -> Bool {
        guard a.direction == b.direction, a.person.lowercased().trimmingCharacters(in: .whitespaces) == b.person.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        let wa = words(a.what), wb = words(b.what)
        guard !wa.isEmpty, !wb.isEmpty else { return a.what == b.what }
        let inter = wa.intersection(wb).count
        return Double(inter) / Double(min(wa.count, wb.count)) >= 0.5
    }
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !["the", "and", "for", "with", "about", "that", "this", "you", "your"].contains($0) })
    }

    /// The line under the sidebar count and on the Loops screen.
    public static func counts(_ loops: [Loop]) -> (mine: Int, theirs: Int, closedThisWeek: Int, now: Date) {
        let now = Date()
        return (loops.filter { $0.status == .open && $0.direction == .mine }.count,
                loops.filter { $0.status == .open && $0.direction == .theirs }.count,
                loops.filter { $0.status == .closed && now.timeIntervalSince($0.closedAt ?? .distantPast) < 7 * 86400 }.count, now)
    }

    public static func load(_ store: any RunStore) async -> [Loop] {
        guard let s = try? await store.value(SettingKey.loops), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Loop].self, from: d)) ?? []
    }
    public static func save(_ loops: [Loop], _ store: any RunStore) async {
        try? await store.setValue(SettingKey.loops, String(data: (try? JSONEncoder().encode(loops)) ?? Data(), encoding: .utf8))
    }
}

/// One card, on demand, for a loop the user wants to act on now: "Nudge" on the Loops screen.
public struct LoopNudger: Sendable {
    private let brain: any Brain
    private let knowledge: any KnowledgeStore
    private let template: String
    private let clock: Clock
    public init(brain: any Brain, knowledge: any KnowledgeStore, clock: Clock = SystemClock(), bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.knowledge = knowledge; self.clock = clock
        template = try String(contentsOf: bundle.url(forResource: "nudge", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "nudge", withExtension: "md")!, encoding: .utf8)
    }
    public func card(for loop: Loop) async throws -> (Card, Usage) {
        let person = (try? await knowledge.search(loop.person, limit: 2))?.first?.body.prefix(2500) ?? ""
        var p = template
        p = p.replacingOccurrences(of: "{{now}}", with: Judge.now(clock))
        p = p.replacingOccurrences(of: "{{loop}}", with: "\(loop.direction == .mine ? "The user promised \(loop.person)" : "\(loop.person) promised the user"): \(loop.what)\nOpened: \(loop.quote) (\(loop.sourceLabel))\(loop.due.map { "\nDue: \($0)" } ?? "")\(loop.firedCardIDs.isEmpty ? "" : "\nThe user already sent one message about this; it went unanswered.")")
        p = p.replacingOccurrences(of: "{{person}}", with: person.isEmpty ? "(no note about \(loop.person) yet)" : String(person))
        let r = try await brain.complete(BrainRequest(system: "You return only the JSON the user asks for.", input: p, effort: .medium, maxOutputTokens: 4000, timeout: 300))
        guard let data = r.jsonData, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var card = Preparer.card(from: obj, now: clock.now()) else { throw BrainError.badResponse("nudge returned no card") }
        card.loopID = loop.id; card.cameBack = loop.firedCardIDs.isEmpty ? nil : true
        return (card, r.usage)
    }
}
