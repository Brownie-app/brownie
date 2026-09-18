import Foundation

/// One message after an ask, from either side: what the verdict on the ask is read from. Local only.
public struct AskLine: Codable, Sendable, Equatable {
    public let at: Date
    /// True for the user's own line.
    public let mine: Bool
    public let text: String
    public init(at: Date, mine: Bool, text: String) { self.at = at; self.mine = mine; self.text = text }
}

/// Where an ask stands, read from the exchange after it. `answered`: the user answered it (in the chat, or, by the
/// judge's word, somewhere else). `confirmedByThem`: the person who asked said it is settled — the strongest word
/// there is. `declined`: the user said no. `promised`: the user said later, so it is still open. `open`: nothing
/// after it settles it.
public enum AskOutcome: String, Codable, Sendable {
    case answered, confirmedByThem, declined, promised, open
    /// Settled: nothing more is owed on it.
    public var isClosed: Bool { self == .answered || self == .confirmedByThem || self == .declined }
    /// The `addressed` flag this verdict keeps in step: a promise is about the question; only an unrelated reply is not.
    public var addressed: Bool { self != .open }
}

/// A question or request someone put to the user in a direct chat, and whether it was settled.
/// Kept on this Mac only: the words never go to the brain — only "asked on the 16th · you replied at 21:29".
public struct Ask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var person: String
    public let bucket: BucketID
    public let askedAt: Date
    /// The question itself, for the person's note. Local only.
    public let question: String
    /// When the user first wrote after the question — or, for an ask the judge saw answered elsewhere with no reply in the chat, the judge's night.
    public var answeredAt: Date?
    /// The user's first message after the question. Local only.
    public var reply: String?
    /// Was the question dealt with? Kept in step with `outcome` for ledgers and code that read it before there was one. nil = not yet judged.
    public var addressed: Bool?
    /// The chat's stable handle (`PersonHandle`), when the source knows one — how the registry ties the ask to a person.
    public var handle: String?
    /// Set when the question went unanswered long enough that Brownie stopped tracking it (45 days). Never nagged about again.
    public var lapsedAt: Date?
    /// The verdict read from the window. nil until judged; a closed verdict is never reopened by a later read.
    public var outcome: AskOutcome?
    /// When the line that decided the outcome was written — their confirmation, the user's promise or refusal, or the judge's night.
    public var outcomeAt: Date?
    /// Who decided: "rules", "reader" or "judge".
    public var outcomeBy: String?
    /// The judge's few words on where an ask answered elsewhere was answered ("on Slack").
    public var outcomeHow: String?
    /// The exchange after the question, both sides, oldest first — at most twelve lines, refreshed on every read. Local only.
    public var window: [AskLine]?
    public init(id: String, person: String, bucket: BucketID, askedAt: Date, question: String, answeredAt: Date? = nil, reply: String? = nil, addressed: Bool? = nil, handle: String? = nil, lapsedAt: Date? = nil,
                outcome: AskOutcome? = nil, outcomeAt: Date? = nil, outcomeBy: String? = nil, outcomeHow: String? = nil, window: [AskLine]? = nil) {
        self.id = id; self.person = person; self.bucket = bucket; self.askedAt = askedAt; self.question = question; self.answeredAt = answeredAt; self.reply = reply; self.addressed = addressed; self.handle = handle; self.lapsedAt = lapsedAt
        self.outcome = outcome; self.outcomeAt = outcomeAt; self.outcomeBy = outcomeBy; self.outcomeHow = outcomeHow; self.window = window
    }
    /// Still waiting: nothing settled it — no reply, a reply about something else, or a promise to get to it — and not yet let go.
    public var isOpen: Bool { lapsedAt == nil && !isAnswered }
    /// Settled: a verdict that closes it, or, for an ask judged before there were verdicts, a reply that addressed it (an unjudged reply gets the benefit of the doubt).
    public var isAnswered: Bool {
        if let outcome { return outcome.isClosed }
        return answeredAt != nil && addressed != false
    }
    /// Settled by a verdict — never on the benefit of the doubt: what a later read must not reopen, and what closes the loop it came from.
    public var isSettled: Bool { outcome?.isClosed ?? (answeredAt != nil && addressed == true) }
    /// Let go: waited 45 days and nothing came.
    public var isLapsed: Bool { lapsedAt != nil && !isAnswered }
}

/// What one scan for asks is told: how far back to read each chat, and which replies are already judged.
/// A chat with nothing waiting is read `since`; a chat with an ask still open is read back to that ask, on its own —
/// one colleague's question from forty days ago does not send every other chat on the source forty days deep.
public struct AskScan: Sendable, Equatable {
    /// How far back a chat with no ask waiting is read.
    public var since: Date
    /// The chats with an ask waiting, each read back to its own oldest one.
    public var sinceByBucket: [BucketID: Date]
    /// Ask id → the reply already judged to be about something else, so the user's next message after it is the one to pair now.
    public var judgedReplies: [String: Date]
    public init(since: Date, sinceByBucket: [BucketID: Date] = [:], judgedReplies: [String: Date] = [:]) {
        self.since = since; self.sinceByBucket = sinceByBucket; self.judgedReplies = judgedReplies
    }
    public func since(_ bucket: BucketID) -> Date { sinceByBucket[bucket] ?? since }
}

/// A chat source that can tell what was asked of the user lately.
public protocol AskScanning: Sendable {
    func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask]
}
