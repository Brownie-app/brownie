import Foundation
import Domain

/// `Today.md` in the vault: the morning's cards as checkboxes. Ticked on the phone (Obsidian, any editor),
/// it comes back through the two-way sync and the card is marked done here.
public enum TodayNote {
    public static let path = "Today.md"
    static let marker = "<!-- card:"

    public static func render(cards: [Card], date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "EEEE d MMMM"
        var out = "# Today — \(f.string(from: date))\n\n"
        let ready = cards.filter { $0.state == .ready }
        if ready.isEmpty { out += "Nothing waiting this morning.\n" }
        else {
            out += "Tick a box on your phone and Brownie marks the card done on the Mac at the next sync.\n\n"
            for c in ready.sorted(by: { $0.urgency > $1.urgency }) {
                out += "- [ ] **\(c.title)** — \(c.why.replacingOccurrences(of: "\n", with: " "))"
                if !c.dueLine.isEmpty { out += " · _\(c.dueLine)_" }
                out += " \(marker)\(c.id) -->\n"
                if !c.draft.isEmpty { out += "    > \(c.draft.replacingOccurrences(of: "\n", with: "\n    > "))\n" }
            }
        }
        out += "\n---\nWritten by Brownie. Sending, paying and deleting stay yours; a tick here only says “done”.\n"
        return out
    }

    public struct Tick: Equatable, Sendable { public let cardID: String; public let checked: Bool }
    /// Every card line and whether its box is ticked (`[x]` / `[X]`).
    public static func parse(_ markdown: String) -> [Tick] {
        markdown.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- ["), let open = l.range(of: "<!--"), let r = l[open.upperBound...].range(of: "card:"), let end = l[r.upperBound...].range(of: "-->") else { return nil }
            let id = l[r.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            let box = l.dropFirst(3).prefix(1).lowercased()
            return Tick(cardID: id, checked: box == "x")
        }
    }

    /// Applies what the phone ticked: those cards are fired ("done on the phone"), the rest untouched. Returns the ids that changed.
    public static func apply(_ ticks: [Tick], to cards: inout [Card], now: Date) -> [String] {
        var changed: [String] = []
        for t in ticks where t.checked {
            if let i = cards.firstIndex(where: { $0.id == t.cardID && $0.state == .ready }) { cards[i].state = .fired; cards[i].resolvedAt = now; changed.append(t.cardID) }
        }
        return changed
    }
}
