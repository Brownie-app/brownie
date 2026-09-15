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
        for f in found {
            if let i = loops.firstIndex(where: { $0.status == .open && same($0, f) }) {
                if loops[i].dueDate == nil, let d = f.dueDate { loops[i].dueDate = d }   // a date learned later still counts
            } else { loops.append(f) }
        }
        for it in items where it.cameBack == true {
            if let id = it.loopID, let i = loops.firstIndex(where: { $0.id.hasPrefix(id) }) { loops[i].cameBackCount += 1 }
        }
        // Keep the ledger small: closed loops fall off after 30 days.
        loops.removeAll { l in l.status != .open && now.timeIntervalSince(l.closedAt ?? l.openedAt) > 30 * 86400 }
        return loops
    }

    public static func same(_ a: Loop, _ b: Loop) -> Bool {
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

/// Due-aware nudges: a loop with a date gets a card ahead of it, even when nothing new was said.
public enum DueNudger {
    /// Open loops whose due date falls within `days` days of now (or is already past), not yet nudged.
    public static func due(_ loops: [Loop], now: Date, days: Int, calendar: Calendar = .current) -> [Loop] {
        guard days > 0 else { return [] }
        // Calendar days, not hours: a 3 AM run the morning before still counts as "the day before".
        let horizon = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return loops.filter { $0.status == .open && $0.nudgedForDue != true && $0.dueDate != nil && calendar.startOfDay(for: $0.dueDate!) <= horizon }
    }
    /// The line under a loop on the Loops screen: when its card will come, if a date is known.
    public static func nudgeLine(for loop: Loop, days: Int, now: Date, calendar: Calendar = .current) -> String? {
        guard days > 0, loop.status == .open, let d = loop.dueDate else { return nil }
        if loop.nudgedForDue == true { return "card sent" }
        let when = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: d)) ?? d
        if when <= now { return "card next morning" }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "EEE"
        return "card \(f.string(from: when)) 7:30"
    }
    /// "Due tomorrow", "Due today", "Overdue 2 days", "Due in 5 days" — from the date, for the card.
    public static func dueLine(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 0
        switch days { case ..<(-1): return "Overdue \(-days) days"; case -1: return "Overdue 1 day"; case 0: return "Due today"; case 1: return "Due tomorrow"; default: return "Due in \(days) days" }
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
    public func card(for loop: Loop, dueAware: Bool = false) async throws -> (Card, Usage) {
        let person = (try? await knowledge.search(loop.person, limit: 2))?.first?.body.prefix(2500) ?? ""
        var p = template
        p = p.replacingOccurrences(of: "{{now}}", with: Judge.now(clock))
        let dueNote = dueAware && loop.dueDate != nil ? "\nThis card exists because the date is close (\(DueNudger.dueLine(loop.dueDate!, now: clock.now()))) — nothing new was said. Say so plainly in `why`; the draft stays light." : ""
        p = p.replacingOccurrences(of: "{{loop}}", with: "\(loop.direction == .mine ? "The user promised \(loop.person)" : "\(loop.person) promised the user"): \(loop.what)\nOpened: \(loop.quote) (\(loop.sourceLabel))\(loop.due.map { "\nDue: \($0)" } ?? "")\(loop.firedCardIDs.isEmpty ? "" : "\nThe user already sent one message about this; it went unanswered.")" + dueNote)
        p = p.replacingOccurrences(of: "{{person}}", with: person.isEmpty ? "(no note about \(loop.person) yet)" : String(person))
        let r = try await brain.complete(BrainRequest(system: "You return only the JSON the user asks for.", input: p, effort: .medium, maxOutputTokens: 4000, timeout: 300))
        guard let data = r.jsonData, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var card = Preparer.card(from: obj, now: clock.now()) else { throw BrainError.badResponse("nudge returned no card") }
        card.loopID = loop.id; card.cameBack = loop.firedCardIDs.isEmpty ? nil : true
        if dueAware, let d = loop.dueDate { card.dueDate = d; card = card.withDueLine(DueNudger.dueLine(d, now: clock.now())) }
        return (card, r.usage)
    }
}

/// Two cards about the same thing — the same loop, or the same person and the same ask in other words — are one card.
/// The stronger one stays: higher urgency, then verified over unverified, then the earlier one.
public enum CardDedupe {
    public static func dedupe(_ cards: [Card]) -> [Card] {
        var kept: [Card] = []
        for c in cards.sorted(by: stronger) {
            if kept.contains(where: { same($0, c) }) { continue }
            kept.append(c)
        }
        // back in the order the pipeline chose, minus the duplicates
        return cards.filter { c in kept.contains { $0.id == c.id } }
    }

    static func stronger(_ a: Card, _ b: Card) -> Bool {
        if a.urgency != b.urgency { return a.urgency > b.urgency }
        if (a.verification == .verified) != (b.verification == .verified) { return a.verification == .verified }
        return a.createdAt < b.createdAt
    }

    public static func same(_ a: Card, _ b: Card) -> Bool {
        if let l = a.loopID, let m = b.loopID, l == m { return true }
        guard let pa = person(a), let pb = person(b), pa == pb else { return false }
        let wa = LoopLedger.words(a.title + " " + a.why + " " + a.draft), wb = LoopLedger.words(b.title + " " + b.why + " " + b.draft)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.5
    }

    /// Who the card is for, from its recipe: the chat, the recipient, the addressee.
    static func person(_ c: Card) -> String? {
        let raw: String
        switch c.recipe {
        case .whatsapp(let chat, _, _): raw = chat
        case .imessage(let to, _, _): raw = to
        case .mail(let to, _, _, _): raw = to
        default: return nil
        }
        // "Kanika Pandey Loadmill" and "Kanika Pandey" are the same person: compare on the first two words
        let parts = raw.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(2)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
