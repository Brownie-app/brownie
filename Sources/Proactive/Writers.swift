import Foundation
import Domain
import Support

/// The Sunday letter: the week in Brownie's words, from this week's runs, cards and loops.
public struct WeeklyWriter: Sendable {
    private let brain: any Brain
    private let template: String
    public init(brain: any Brain, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain
        template = try String(contentsOf: bundle.url(forResource: "weekly", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "weekly", withExtension: "md")!, encoding: .utf8)
    }
    public func write(range: String, corrections: String = "", numbers: String, bytes: String, cards: [Card], loops: [Loop], readme: String, calendar: String?) async throws -> (String, Usage) {
        let f = DateFormatter(); f.dateFormat = "EEE"
        let cardLines = cards.isEmpty ? "(none)" : cards.map { "- \($0.title) · \($0.state.rawValue)\($0.isComeBack ? " · came back" : "") · \(f.string(from: $0.resolvedAt ?? $0.createdAt))" }.joined(separator: "\n")
        let loopLines = loops.isEmpty ? "(none)" : loops.map { l in "- [\(l.status.rawValue)] \(l.direction == .mine ? "you → \(l.person)" : "\(l.person) → you"): \(l.what) · said \(l.sourceLabel)\(l.due.map { " · due \($0)" } ?? "")\(l.closedHow.map { " · closed: \($0)" } ?? "")" }.joined(separator: "\n")
        var p = template
        for (k, v) in [("range", range), ("corrections", corrections.isEmpty ? "(none this week)" : corrections), ("numbers", numbers), ("bytes", bytes), ("cards", cardLines), ("loops", loopLines), ("readme", String(readme.prefix(6000))), ("calendar", calendar ?? "(nothing on the calendar)")] {
            p = p.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        let r = try await brain.complete(BrainRequest(system: "You write exactly one letter in Markdown, nothing else.", input: p, effort: .low, maxOutputTokens: 8000))
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrainError.badResponse("empty weekly letter") }
        return (text, r.usage)
    }
    /// "2026-W38" — the key a letter is stored under.
    public static func isoWeek(_ d: Date) -> String {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }
}

/// Ten minutes before a meeting: the People notes, the open loops, one page.
public struct BriefWriter: Sendable {
    private let brain: any Brain
    private let knowledge: any KnowledgeStore
    private let template: String
    public init(brain: any Brain, knowledge: any KnowledgeStore, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain; self.knowledge = knowledge
        template = try String(contentsOf: bundle.url(forResource: "brief", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "brief", withExtension: "md")!, encoding: .utf8)
    }
    public func write(eventID: String, title: String, startsAt: Date, eventLine: String, attendees: [String], loops: [Loop], cards: [Card]) async throws -> (Brief, Usage) {
        var notes: [String] = []
        for a in attendees.prefix(8) {
            let first = a.split(separator: " ").first.map(String.init) ?? a
            let byFirst = (try? await knowledge.search(first, limit: 3)) ?? []
            var hit = byFirst.first { $0.relativePath.hasPrefix("People/") }
            if hit == nil { hit = (try? await knowledge.search(a, limit: 1))?.first }
            if let n = hit { notes.append("## \(a) — from \(n.relativePath)\n\(n.body.prefix(2500))") } else { notes.append("## \(a)\n(no note yet)") }
        }
        let theirLoops = loops.filter { l in l.status == .open && attendees.contains { $0.lowercased().contains(l.person.lowercased()) || l.person.lowercased().contains($0.split(separator: " ").first.map(String.init)?.lowercased() ?? "\u{0}") } }
        let theirCards = cards.filter { c in attendees.contains { c.title.lowercased().contains($0.split(separator: " ").first.map(String.init)?.lowercased() ?? "\u{0}") } }
        var p = template
        p = p.replacingOccurrences(of: "{{event}}", with: eventLine)
        p = p.replacingOccurrences(of: "{{attendees}}", with: attendees.joined(separator: ", "))
        p = p.replacingOccurrences(of: "{{notes}}", with: notes.joined(separator: "\n\n"))
        p = p.replacingOccurrences(of: "{{loops}}", with: theirLoops.isEmpty ? "(none)" : theirLoops.map { l in "- \(l.direction == .mine ? "You → \(l.person)" : "\(l.person) → you"): \(l.what) · said \(l.sourceLabel)" }.joined(separator: "\n"))
        p = p.replacingOccurrences(of: "{{cards}}", with: theirCards.isEmpty ? "(none)" : theirCards.prefix(6).map { "- \($0.title) (\($0.state.rawValue)): \($0.why)" }.joined(separator: "\n"))
        let r = try await brain.complete(BrainRequest(system: "You write one brief in Markdown, nothing else.", input: p, effort: .low, maxOutputTokens: 4000, timeout: 240))
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrainError.badResponse("empty brief") }
        return (Brief(id: eventID, title: title, startsAt: startsAt, attendees: attendees, text: text, loops: theirLoops, createdAt: Date()), r.usage)
    }
}
