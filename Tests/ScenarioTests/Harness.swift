import Testing
import Foundation
import Domain
import LocalSources
import Proactive
import Knowledge

// MARK: - The world a scenario lives in

/// A scenario is a handful of invented people saying real things over real days, and this is the machine that
/// replays them night by night. Nothing here decides anything: every decision is the app's own code, called in
/// the order `RunCoordinator` calls it — the ask scan and detection, the verdicts, the ledger merge, the loops
/// the asks settle, loop admission and merge, the due nudges, dedupe, the quiet check, the status block, the
/// note's shape. The only stand-in is the cloud judge, which needs a network: a scenario scripts what a real
/// judge would plausibly have handed back that night (`JudgeScript`), and everything downstream of it is real.
///
/// Days are whole days; the night that follows day N runs at 3 AM on day N+1, which is when the Mac actually
/// wakes, so "the morning before a due date" means what it means in the app. The clock is UTC throughout, so
/// two runs of a scenario are the same bytes.
///
/// Two simplifications, both narrower than the app and neither able to hide a fault: the status block is
/// rendered per person by name rather than routed through `PersonRegistry` (the coordinator routes by handle,
/// which is stricter, so a block here can hold a line the app would put elsewhere — never one it would drop),
/// and the on-device reader is never consulted, so every verdict here is one the rules reached on their own.
final class World {
    /// Day 0 is Monday 7 September 2026, midnight UTC, so a due said as "Friday" lands where a reader expects it.
    static let epoch = Date(timeIntervalSince1970: 1_788_739_200)
    let timeZone = TimeZone(identifier: "UTC")!
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }

    /// Everything the scenario has ever said, per chat.
    private(set) var chats: [Chat]
    /// The user's own names, for the loop bar.
    let selfNames: [String]
    /// Files the recipes may point at, for the quiet check.
    var files: Set<String> = []
    /// When each person's note last changed in substance, for the quiet check's staleness rule.
    var noteUpdated: [String: Date] = [:]

    private(set) var asks: [Ask] = []
    private(set) var loops: [Loop] = []
    /// Every card ever made, with the state the user left it in.
    private(set) var cards: [Card] = []
    /// Each person's note body, in the shape the gardener keeps it.
    private(set) var notes: [String: String] = [:]
    private(set) var nights: [Night] = []
    private var nextRowID: Int64 = 1

    init(_ chats: [Chat], selfNames: [String] = ["Vivek Upreti", "Vivek"]) {
        self.chats = chats
        self.selfNames = selfNames
        for c in chats where !c.isGroup { notes[c.person] = Self.blankNote(c.person) }
    }

    // MARK: the calendar

    func at(_ day: Int, _ hour: Double = 0) -> Date { Self.epoch.addingTimeInterval(Double(day) * 86400 + hour * 3600) }
    /// The night after day `day`: 3 AM the next morning, which is the morning it writes cards for.
    func nightAt(_ day: Int) -> Date { at(day + 1, 3) }
    /// The morning after day `day`, when the user sees the cards and acts on them.
    func morningAt(_ day: Int) -> Date { at(day + 1, 8) }

    // MARK: what was said

    /// One message in a chat, on a day, at an hour. `mine` is the user's own line. `inThread` marks a Slack-style
    /// threaded reply: it was really said, but `conversations.history` — all `SlackSource` ever calls — does not
    /// return it, so the source cannot see it.
    @discardableResult
    func say(_ chat: String, _ text: String, mine: Bool = false, day: Int, at hour: Double, inThread: Bool = false) -> ChatMessage {
        let id = BucketID(chat)
        guard let i = chats.firstIndex(where: { $0.id == id }) else { fatalError("no chat \(chat) in this scenario") }
        let m = ChatMessage(rowID: nextRowID, date: at(day, hour), sender: mine ? "Me" : chats[i].person, isMe: mine, text: text)
        nextRowID += 1
        chats[i].messages.append(m)
        if inThread { chats[i].inThread.insert(m.rowID) }
        return m
    }
    /// A line from someone named in a group, where the sender is not the chat.
    @discardableResult
    func say(_ chat: String, from sender: String, _ text: String, day: Int, at hour: Double) -> ChatMessage {
        let id = BucketID(chat)
        guard let i = chats.firstIndex(where: { $0.id == id }) else { fatalError("no chat \(chat) in this scenario") }
        let m = ChatMessage(rowID: nextRowID, date: at(day, hour), sender: sender, isMe: false, text: text)
        nextRowID += 1
        chats[i].messages.append(m)
        return m
    }

    /// What the brain has already written on a person's note, before tonight. The status block goes above it and
    /// the shape rules run over the whole thing, exactly as they do on a real note.
    func write(note person: String, _ body: String) { notes[person] = body }

    // MARK: what the user did in the app that morning

    /// The app's own buttons, as `AppModel` works them: dismiss, fire ("marked done"), close a loop, dismiss a loop.
    enum Act {
        case dismissed(card: String)
        case markedDone(card: String)
        case closedLoop(what: String, how: String)
        case dismissedLoop(what: String)
    }
    func did(_ acts: [Act], on day: Int) {
        let now = morningAt(day)
        for a in acts {
            switch a {
            case .dismissed(let title):
                if let i = cards.firstIndex(where: { $0.title == title && $0.state == .ready }) { cards[i].state = .dismissed; cards[i].resolvedAt = now }
            case .markedDone(let title):
                guard let i = cards.firstIndex(where: { $0.title == title && $0.state == .ready }) else { break }
                cards[i].state = .fired; cards[i].resolvedAt = now
                // a fired card about a loop is remembered on the loop, so the loop comes back if nothing changes
                if let l = cards[i].loopID, let j = loops.firstIndex(where: { $0.id == l }) { loops[j].firedCardIDs.append(cards[i].id) }
            case .closedLoop(let what, let how):
                if let i = loops.firstIndex(where: { $0.what == what && $0.status == .open }) {
                    loops[i].status = .closed; loops[i].closedAt = now; loops[i].closedHow = how; loops[i].closedBy = "user"
                }
            case .dismissedLoop(let what):
                if let i = loops.firstIndex(where: { $0.what == what && $0.status == .open }) {
                    loops[i].status = .dismissed; loops[i].closedAt = now; loops[i].closedHow = "not a promise"
                }
            }
        }
    }

    // MARK: the night

    /// One night, in the order the coordinator runs it. Returns what came out.
    @discardableResult
    func night(_ day: Int, judge: JudgeScript = JudgeScript(), did acts: [Act] = []) async -> Night {
        did(acts, on: day - 1)   // the user acted on yesterday's cards, the morning before this night
        let now = nightAt(day)
        let source = ChatSource(chats: chats.map { $0.upTo(now) }, now: now)
        let enabled = Set(chats.filter { !$0.isGroup }.map(\.id))

        // 1. READ — every direct chat scanned back as far as its own oldest waiting ask, the asks paired with
        // what the user said after them, then judged on-device (rules first; no reader, so no cloud and no guess).
        let scan = AskLedger.scan(existing: asks, now: now)
        let found = (try? await source.recentAsks(enabled: enabled, scan: scan)) ?? []
        asks = AskLedger.merge(existing: asks, found: found, now: now)
        asks = await AskAnswering.judge(asks, reader: nil)

        // 2. the ledger's own clock, before the judge sees it: a due said in words gets its date, a loop with no
        // news for its term is let go, and the asks settle the loops they settle.
        for i in loops.indices where loops[i].status == .open && loops[i].dueDate == nil {
            if let d = DueWords.date(loops[i].due, now: loops[i].openedAt, timeZone: timeZone) { loops[i].dueDate = d }
        }
        loops = StatusRules.lapse(loops: loops, now: now)
        closeLoopsByAsks(now: now)

        // 3. the cloud judge, scripted. Its ask_updates can close an ask answered in another channel.
        asks = AskLedger.apply(updates: judge.askUpdates, to: asks, now: now)
        closeLoopsByAsks(now: now)

        // 4. the bar every new loop must clear, then the merge. A loop the judge hands over carries its due as
        // words; the judge reads a date out of them against the run's clock before the loop is anything, which is
        // what `Judge` does with `dueISO` and `DueWords` in the same breath.
        let proposedLoops = judge.loops.map { l -> Loop in
            guard l.dueDate == nil, let d = DueWords.date(l.due, now: now, timeZone: timeZone) else { return l }
            var l = l; l.dueDate = d; return l
        }
        let gate = LoopQuality.admit(proposedLoops, selfNames: selfNames, existing: loops)
        let fresh = gate.kept.filter { l in !loops.contains { $0.id == l.id } }
        loops = LoopLedger.merge(existing: loops, found: fresh, updates: judge.updates, items: judge.items, now: now)

        // 5. due-aware nudges: a loop whose date is close gets a card even when nothing new was said.
        var dueCards: [Card] = []
        for l in DueNudger.due(loops, now: now, days: judge.nudgeDays, calendar: calendar) where !judge.cards.contains(where: { $0.loopID == l.id }) {
            dueCards.append(judge.dueCard(for: l, now: now, dueLine: DueNudger.dueLine(l.dueDate!, now: now, calendar: calendar)))
            if let i = loops.firstIndex(where: { $0.id == l.id }) { loops[i].nudgedForDue = true }
        }

        // 6. the cards: last night's unresolved ones are replaced, what the user touched stays; duplicates fold;
        // the quiet check drops what is no longer true.
        let past = cards.filter { $0.state != .ready }
        var proposed = CardDedupe.dedupe(judge.cards.map { $0.stamped(now) } + dueCards)
        let folded = judge.cards.count + dueCards.count - proposed.count
        let checked = QuietCheck.run(cards: proposed, loops: loops, past: past, noteUpdated: { [noteUpdated] in noteUpdated[$0] },
                                     fileExists: { [files] in files.contains($0) }, now: now, staleDays: judge.staleDays)
        proposed = checked.kept
        cards = past + proposed

        // 7. the status block on each person's note, then the note back in shape.
        var status: [String: [String]] = [:], bullets: [String: [String]] = [:]
        for (person, body) in notes {
            let mine = asks.filter { AskLedger.samePerson($0.person, person) }
            let theirs = loops.filter { AskLedger.samePerson($0.person, person) }
            let block = StatusBlock.render(person: person, asks: mine, loops: theirs, now: now, timeZone: timeZone)
            let retired = StatusBlock.retiredLines(person: person, asks: mine, loops: theirs, now: now, timeZone: timeZone)
            let withBlock = StatusBlock.upsert(into: body, block: block)
            let aged = NoteAging.age(body: withBlock, kind: .person, now: now, retired: retired, timeZone: timeZone)
            notes[person] = aged.body
            status[person] = Self.blockLines(aged.body)
            bullets[person] = Self.nowBullets(aged.body)
        }

        let n = Night(day: day, at: now, asks: asks, loops: loops, cards: proposed,
                      droppedCards: checked.dropped.map { (title: $0.card.title, why: $0.why) },
                      foldedCards: folded, rejectedLoops: gate.rejected.map { (what: $0.loop.what, why: $0.reason) },
                      status: status, nowBullets: bullets)
        nights.append(n)
        return n
    }

    /// The user's own replies close the loops about answering; an ask settled any way closes the loop it came from.
    private func closeLoopsByAsks(now: Date) {
        let open = loops.filter { $0.status == .open }
        let settled = AskLedger.followers(loops: AskLedger.closures(loops: open, asks: asks, now: now), asks: asks, now: now)
        for l in settled where l.status == .closed {
            if let i = loops.firstIndex(where: { $0.id == l.id }) { loops[i] = l }
        }
    }

    // MARK: reading a note back

    static func blankNote(_ person: String) -> String {
        "# \(person)\n\n## About\n\n## Now\n\n## Context\n\n## Earlier\n"
    }
    /// The status block's own lines, markers and heading dropped.
    static func blockLines(_ body: String) -> [String] {
        guard let block = NoteStatus.extract(from: body) else { return [] }
        return block.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }
    /// The bullets under `## Now`, which is what the cards are made from.
    static func nowBullets(_ body: String) -> [String] {
        var out: [String] = [], inNow = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") { inNow = line.hasPrefix("## Now"); continue }
            if inNow, line.hasPrefix("- ") { out.append(line) }
        }
        return out
    }
}

// MARK: - What came out of one night

struct Night {
    let day: Int
    let at: Date
    let asks: [Ask]
    let loops: [Loop]
    /// The cards that reached the morning.
    let cards: [Card]
    let droppedCards: [(title: String, why: String)]
    let foldedCards: Int
    let rejectedLoops: [(what: String, why: String)]
    let status: [String: [String]]
    let nowBullets: [String: [String]]

    var cardTitles: [String] { cards.map(\.title) }
    var openAsks: [Ask] { asks.filter(\.isOpen) }
    var openLoops: [Loop] { loops.filter { $0.status == .open } }
    func ask(from person: String) -> Ask? { asks.first { AskLedger.samePerson($0.person, person) } }
    func asks(from person: String) -> [Ask] { asks.filter { AskLedger.samePerson($0.person, person) } }
    func loop(_ what: String) -> Loop? { loops.first { $0.what == what } }
    func lines(_ person: String) -> [String] { status[person] ?? [] }
    /// One line of the whole night, for a failure message a reader can act on.
    var line: String {
        "day \(day): asks " + asks.map { "\($0.person)/\($0.outcome?.rawValue ?? "unjudged")\($0.isLapsed ? "/lapsed" : "")" }.joined(separator: ", ")
            + " · loops " + loops.map { "\($0.what)/\($0.status.rawValue)" }.joined(separator: ", ")
            + " · cards " + cardTitles.joined(separator: ", ")
            + (droppedCards.isEmpty ? "" : " · dropped " + droppedCards.map { "\($0.title) (\($0.why))" }.joined(separator: ", "))
    }
    /// The same line as a test comment, so a failure names the night it happened on.
    var summary: Comment { Comment(rawValue: line) }
}

// MARK: - The chats a scenario declares

/// One chat on one app: what it is called, whether it is a group, the handle the source knows it by, and
/// everything ever said in it.
struct Chat: Sendable {
    let id: BucketID
    /// The chat's name, which for a direct chat is the person as that app spells them.
    let name: String
    let isGroup: Bool
    let handle: String?
    var messages: [ChatMessage] = []
    /// Lines that were said inside a thread: real, but out of the source's reach.
    var inThread: Set<Int64> = []
    /// The person behind a direct chat, for the note and the sender's name.
    var person: String { name }

    static func direct(_ id: String, _ name: String, handle: String? = nil) -> Chat {
        Chat(id: BucketID(id), name: name, isGroup: false, handle: handle)
    }
    static func group(_ id: String, _ name: String) -> Chat {
        Chat(id: BucketID(id), name: name, isGroup: true, handle: nil)
    }
    /// The chat as it stood at a moment — what a source reading tonight can see.
    func upTo(_ now: Date) -> Chat {
        var c = self; c.messages = messages.filter { $0.date <= now }; return c
    }
    var info: BucketInfo { BucketInfo(id: id, name: name, detail: isGroup ? "Group" : "Direct", isGroup: isGroup, count: messages.count, handle: handle) }
}

/// A source that holds scripted chats and nothing else. It is a real `Source` and a real `ChatReader`, so the
/// app's own `scanAsks` — the same extension WhatsApp, iMessage, Slack, Teams and Telegram all reach asks
/// through — runs over it unchanged.
struct ChatSource: Source, ChatReader, AskScanning {
    static let descriptor = SourceDescriptor(id: SourceID("scenario"), name: "Scenario", detail: "invented people",
                                             door: .localDatabase, supportsPerBucketOptIn: true)
    let chats: [Chat]
    let now: Date

    func availability() async -> Availability { .available }
    func discoverBuckets() async throws -> [BucketInfo] { chats.map(\.info) }
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] { [] }
    func load(_ candidate: Candidate) async throws -> Artifact { throw SourceError.itemGone }
    func chats() async throws -> [BucketInfo] { chats.map(\.info) }
    func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard let c = chats.first(where: { $0.id == bucket }) else { return [] }
        return c.messages.filter { !c.inThread.contains($0.rowID) && $0.date >= from && $0.date <= to }.sorted { $0.date < $1.date }
    }
    func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask] {
        try await scanAsks(enabled: enabled, scan: scan, now: now)
    }
}

// MARK: - The cloud judge, scripted

/// What a real judge would plausibly have handed back on one night: the cards it proposes, the loops it opens,
/// the loops it reports closed, and the asks it saw answered somewhere else. The real one needs a network.
struct JudgeScript {
    var cards: [Card] = []
    var loops: [Loop] = []
    var items: [ActionItem] = []
    var updates: [(idPrefix: String, closed: Bool, how: String)] = []
    var askUpdates: [(idPrefix: String, how: String)] = []
    var nudgeDays = 1
    var staleDays = QuietCheck.defaultStaleDays

    /// The card the nudger would draft for a loop whose date is close.
    func dueCard(for loop: Loop, now: Date, dueLine: String) -> Card {
        var c = Card(id: UUID().uuidString, title: "Nudge \(PersonKey.displayName(loop.person))", sourceLabel: loop.sourceLabel,
                     why: "The date is close (\(dueLine)) — nothing new was said.", actionLabel: "Send", dueLine: dueLine,
                     urgency: .medium, draftLabel: "Draft", draft: "About \(loop.what) — still on for \(loop.due ?? "soon")?",
                     recipe: .whatsapp(chat: loop.person, body: "About \(loop.what)"), evidence: [Evidence(source: loop.sourceLabel, when: "", text: loop.quote)],
                     verification: .verified, verifiedLine: "", createdAt: now, loopID: loop.id)
        c.dueDate = loop.dueDate
        return c
    }
}

// MARK: - Builders a scenario writes with

extension Card {
    /// A card the way the preparer makes one: a fresh id every night, whatever else repeats.
    static func proposed(_ title: String, to person: String, on channel: Channel = .whatsapp, why: String = "",
                         draft: String = "", loop: String? = nil, urgency: Urgency = .medium,
                         evidence: [Evidence] = [], verified: Bool = true) -> Card {
        Card(id: UUID().uuidString, title: title, sourceLabel: channel.label, why: why, actionLabel: "Send",
             dueLine: "", urgency: urgency, draftLabel: "Draft", draft: draft,
             recipe: channel.recipe(to: person, body: draft.isEmpty ? title : draft, subject: title),
             evidence: evidence, verification: verified ? .verified : .unverified, verifiedLine: "", createdAt: .distantPast, loopID: loop)
    }
    /// The same card with tonight's clock on it — the preparer stamps every card with the run's moment.
    func stamped(_ now: Date) -> Card {
        var c = Card(id: id, title: title, sourceLabel: sourceLabel, why: why, actionLabel: actionLabel, dueLine: dueLine,
                     urgency: urgency, draftLabel: draftLabel, draft: draft, recipe: recipe, evidence: evidence,
                     verification: verification, verifiedLine: verifiedLine, state: state, createdAt: now, cameBack: cameBack, loopID: loopID)
        c.dueDate = dueDate; c.owner = owner
        return c
    }
}

/// Where a card would go out.
enum Channel {
    case whatsapp, imessage, mail, slack
    var label: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .imessage: return "iMessage"
        case .mail: return "Mail"
        case .slack: return "Slack"
        }
    }
    func recipe(to person: String, body: String, subject: String) -> Recipe {
        switch self {
        case .whatsapp, .slack: return .whatsapp(chat: person, body: body)
        case .imessage: return .imessage(to: person, body: body, attachments: [])
        case .mail: return .mail(to: person, subject: subject, body: body, attachments: [])
        }
    }
}

extension Loop {
    /// A loop the way the judge proposes one.
    static func proposed(_ what: String, _ direction: LoopDirection, with person: String, quote: String = "",
                         source: String = "WhatsApp · Mon", due: String? = nil, dueISO: Date? = nil,
                         openedAt: Date, id: String = UUID().uuidString) -> Loop {
        Loop(id: id, direction: direction, person: person, what: what, quote: quote.isEmpty ? what : quote,
             sourceLabel: source, due: due, dueDate: dueISO, openedAt: openedAt, noticedAt: openedAt)
    }
}
