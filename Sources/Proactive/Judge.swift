import Foundation
import Domain
import Support

/// Part 1: hermetic, no tools. Summaries (+ calendar text + clock + standing instructions) → ranked candidates.
public struct Judge: Sendable {
    public static let schema = #"{"type":"object","properties":{"action_items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"action":{"type":"string"},"importance":{"type":"string"},"dueDate":{"type":["string","null"]},"sources":{"type":"array","items":{"type":"string"}},"urgency":{"type":"string","enum":["high","medium","low"]},"loopID":{"type":["string","null"]},"cameBack":{"type":"boolean"},"owner":{"type":["string","null"]}},"required":["title","action","importance","dueDate","sources","urgency","loopID","cameBack","owner"]}},"loops":{"type":"array","items":{"type":"object","properties":{"person":{"type":"string"},"direction":{"type":"string","enum":["mine","theirs"]},"what":{"type":"string"},"quote":{"type":"string"},"source":{"type":"string"},"due":{"type":["string","null"]},"dueISO":{"type":["string","null"]},"owner":{"type":["string","null"]}},"required":["person","direction","what","quote","source","due","dueISO","owner"]}},"loop_updates":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"status":{"type":"string","enum":["open","closed"]},"how":{"type":"string"}},"required":["id","status","how"]}}},"required":["action_items","loops","loop_updates"]}"#

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

    /// `selfNames` are the user's own names: the judge is told them so `person` on a loop is never the user.
    public func judge(summaries: [SummaryRecord], calendar: String?, instructions: String, openLoops: [Loop], max: Int = 8, household: Household? = nil, asks: String = "", selfNames: [String] = []) async throws -> (Findings, Usage) {
        guard !summaries.isEmpty else { return (Findings(items: [], newLoops: [], updates: []), .zero) }
        let corpus = Self.trim(summaries.enumerated().map { Self.line($1, $0 + 1, shared: household?.isShared($1.bucket) ?? false) }.joined(separator: "\n"), to: BrainLimits.corpusPartBudget)
        var p = template
        p = p.replacingOccurrences(of: "{{max}}", with: String(max))
        p = p.replacingOccurrences(of: "{{now}}", with: Self.now(clock))
        p = p.replacingOccurrences(of: "{{calendar}}", with: calendar.map { "THE USER'S LIVE CALENDAR (last 7 days + next 24 hours):\n\($0)\n" } ?? "")
        p = p.replacingOccurrences(of: "{{instructions}}", with: instructions.isEmpty ? "" : "THE USER'S STANDING INSTRUCTIONS (honour these about what to surface or skip; they never override accuracy):\n\(instructions)\n")
        p = p.replacingOccurrences(of: "{{summaries}}", with: corpus)
        p = p.replacingOccurrences(of: "{{household}}", with: Self.householdBlock(household))
        p = p.replacingOccurrences(of: "{{asks}}", with: asks)
        p = p.replacingOccurrences(of: "{{self}}", with: Self.selfBlock(selfNames))
        p = p.replacingOccurrences(of: "{{loops}}", with: openLoops.isEmpty ? "" : "OPEN LOOPS BROWNIE ALREADY TRACKS (report only closures, in loop_updates, by id):\n" + openLoops.map(\.judgeLine).joined(separator: "\n") + "\n")
        let r = try await brain.complete(BrainRequest(system: "You return only the JSON the user asks for.", input: p, schema: Self.schema, effort: .high, maxOutputTokens: 8000, timeout: 1200))
        guard let data = r.jsonData, let obj = try? JSONDecoder().decode(Wrapper.self, from: data) else { throw BrainError.badResponse("judge returned no JSON") }
        let now = clock.now()
        let loops = (obj.loops ?? []).compactMap { l -> Loop? in
            guard !l.person.isEmpty, !l.what.isEmpty else { return nil }
            // The date: the judge's ISO day when it worked one out, else the words it used ("September6", "by the 30th") read against the clock.
            let dueDate = Self.date(l.dueISO, clock: clock) ?? DueWords.date(l.due, now: now, timeZone: clock.timeZone)
            var loop = Loop(direction: l.direction == "mine" ? .mine : .theirs, person: l.person, what: l.what, quote: l.quote, sourceLabel: l.source, due: l.due, dueDate: dueDate, openedAt: now)
            loop.owner = Self.cleanOwner(l.owner)
            return loop
        }
        let updates = (obj.loop_updates ?? []).map { (idPrefix: $0.id, closed: $0.status == "closed", how: $0.how) }
        log.info("judge: \(obj.action_items.count) candidates, \(loops.count) new loops, \(updates.count) loop updates from \(summaries.count) summaries")
        let items = obj.action_items.prefix(max).map { i -> ActionItem in var i = i; i.owner = Self.cleanOwner(i.owner); return i }
        return (Findings(items: Array(items), newLoops: loops, updates: updates), r.usage)
    }

    struct Wrapper: Decodable {
        let action_items: [ActionItem]
        let loops: [RawLoop]?
        let loop_updates: [RawUpdate]?
        struct RawLoop: Decodable { let person: String; let direction: String; let what: String; let quote: String; let source: String; let due: String?; let dueISO: String?; let owner: String? }
        struct RawUpdate: Decodable { let id: String; let status: String; let how: String }
    }

    static func line(_ s: SummaryRecord, _ i: Int, shared: Bool = false) -> String {
        let date = s.itemDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "undated"
        return "#\(i) · [\(s.source.rawValue)\(shared ? " · SHARED with the household" : "")] \(s.bucketName) · \(date)\n\(s.title) — \(s.text)"
    }
    /// "me" / "either" / a member's first name; anything else (an empty string, "null", a stranger) → nil.
    public static func cleanOwner(_ raw: String?, members: [String]? = nil) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, r.lowercased() != "null" else { return nil }
        let l = r.lowercased()
        if l == "me" || l == "user" || l == "the user" || l == "you" { return "me" }
        if l == "either" || l == "both" || l == "anyone" { return "either" }
        return String(r.split(separator: " ").first ?? Substring(r))
    }
    /// Who the user is, so `person` never names them: a loop the user made is `mine` with `person` the one it was made to.
    static func selfBlock(_ names: [String]) -> String {
        let clean = SelfNames.clean(names)
        guard let first = clean.first else { return "" }
        let also = clean.dropFirst().isEmpty ? "" : " (also written \(clean.dropFirst().joined(separator: ", ")))"
        return "THE USER IS \(first)\(also). `person` on a loop or an item is always the other party — never the user under any spelling. A promise the user made is `mine` with `person` the one it was made to; a promise made to the user is `theirs` with `person` the one who made it. Never open a loop in which the user owes something to themselves.\n"
    }
    static func householdBlock(_ h: Household?) -> String {
        guard let h, !h.others.isEmpty else { return "" }
        return """
        THE HOUSEHOLD: the user shares a household with \(h.othersLine). Summaries marked SHARED come from chats every member is in, and \(h.othersLine)'s own Brownie reads them too. For every item AND every loop that comes from a SHARED summary, set `owner`: "me" when the summary shows the user is the one to act, "\(h.others.map(\.firstName).joined(separator: "\" or \""))" when it shows that person took it on, or "either" when it is open to whoever gets to it. Items from anything not marked SHARED get `owner`: null — they are the user's alone and never reach the household.

        """
    }

    /// "2026-09-23" → that day at 9 AM local, so "due Tuesday" sorts before the day is over. Anything else → nil,
    /// and so is a date the brain invented years out or long past: the loop keeps its words ("by Tuesday") but no date.
    static func date(_ iso: String?, clock: Clock) -> Date? {
        guard let iso, iso.count == 10 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = clock.timeZone
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return DateSanity.due(cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 9)), now: clock.now())
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
