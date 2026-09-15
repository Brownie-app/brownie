import Foundation
import Domain

/// `ledger.json` in the shared folder: every household loop each Mac knows, and who closed what.
/// Both Macs write their own entries; the file is the union, latest word per loop wins, closed beats open.
public struct HouseholdEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { loopID }
    public let loopID: String
    public let memberID: String        // whose Brownie wrote this line
    public let person: String
    public let what: String
    public let direction: LoopDirection
    public var owner: String?
    public var status: LoopStatus
    public var closedBy: String?       // member id
    public var closedHow: String?
    public var updatedAt: Date
    public init(loopID: String, memberID: String, person: String, what: String, direction: LoopDirection, owner: String?, status: LoopStatus, closedBy: String? = nil, closedHow: String? = nil, updatedAt: Date) {
        self.loopID = loopID; self.memberID = memberID; self.person = person; self.what = what; self.direction = direction; self.owner = owner; self.status = status; self.closedBy = closedBy; self.closedHow = closedHow; self.updatedAt = updatedAt
    }
}

public enum HouseholdLedger {
    public static let file = "ledger.json"

    /// My household loops as ledger lines.
    public static func entries(from loops: [Loop], me: String, now: Date) -> [HouseholdEntry] {
        loops.filter { $0.owner != nil }.map { l in
            HouseholdEntry(loopID: l.id, memberID: me, person: l.person, what: l.what, direction: l.direction, owner: l.owner, status: l.status, closedBy: l.status == .closed ? me : nil, closedHow: l.closedHow, updatedAt: l.closedAt ?? l.openedAt)
        }
    }

    /// Union by loop id; the newer line wins, except that a closure is never undone by an older open line.
    /// Loops the two Macs found separately (same person, same words) are folded onto the earlier id.
    public static func merge(_ a: [HouseholdEntry], _ b: [HouseholdEntry]) -> [HouseholdEntry] {
        var out: [String: HouseholdEntry] = [:]
        for e in (a + b).sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let key = out.values.first(where: { $0.loopID == e.loopID || sameLoop($0, e) })?.loopID ?? e.loopID
            if var cur = out[key] {
                if e.status == .closed { cur.status = .closed; cur.closedBy = e.closedBy ?? cur.closedBy; cur.closedHow = e.closedHow ?? cur.closedHow }
                if e.updatedAt >= cur.updatedAt { cur.owner = e.owner ?? cur.owner; cur.updatedAt = e.updatedAt }
                out[key] = cur
            } else { out[key] = e }
        }
        return out.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func sameLoop(_ a: HouseholdEntry, _ b: HouseholdEntry) -> Bool {
        guard a.direction == b.direction, a.person.lowercased() == b.person.lowercased() else { return false }
        let wa = LoopLedger.words(a.what), wb = LoopLedger.words(b.what)
        guard !wa.isEmpty, !wb.isEmpty else { return a.what == b.what }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.5
    }

    /// Cards whose loop another member closed get `handledBy` (their first name); the rest are untouched.
    public static func markHandled(_ cards: [Card], ledger: [HouseholdEntry], household: Household) -> [Card] {
        guard let me = household.me?.id else { return cards }
        return cards.map { c in
            var c = c; c.handledBy = nil
            guard c.owner != nil else { return c }
            let hit = ledger.first { e in
                e.status == .closed && e.closedBy != nil && e.closedBy != me &&
                (e.loopID == c.loopID || sameCard(c, e))
            }
            if let hit, let who = household.members.first(where: { $0.id == hit.closedBy }) { c.handledBy = who.firstName }
            return c
        }
    }
    /// The card's title against the loop's promise — not the chat name, which every card in a group would share.
    static func sameCard(_ c: Card, _ e: HouseholdEntry) -> Bool {
        let wc = LoopLedger.words(c.title), we = LoopLedger.words(e.what)
        guard !wc.isEmpty, !we.isEmpty else { return false }
        return Double(wc.intersection(we).count) / Double(min(wc.count, we.count)) >= 0.5
    }

    /// Loops the other Macs closed that I still hold open → close them here too, saying who.
    public static func closures(for loops: [Loop], ledger: [HouseholdEntry], household: Household, now: Date) -> [Loop] {
        guard let me = household.me?.id else { return loops }
        return loops.map { l in
            guard l.status == .open, l.owner != nil, let e = ledger.first(where: { $0.status == .closed && $0.closedBy != nil && $0.closedBy != me && ($0.loopID == l.id || sameLoop($0, HouseholdEntry(loopID: l.id, memberID: me, person: l.person, what: l.what, direction: l.direction, owner: l.owner, status: .open, updatedAt: now))) }) else { return l }
            var l = l; l.status = .closed; l.closedAt = now
            l.closedHow = "\(household.members.first { $0.id == e.closedBy }?.firstName ?? "someone at home") did it\(e.closedHow.map { " — \($0)" } ?? "")"
            return l
        }
    }

    public static func read(_ url: URL) -> [HouseholdEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HouseholdEntry].self, from: d)) ?? []
    }
    public static func write(_ entries: [HouseholdEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: url, options: .atomic)
    }
}
