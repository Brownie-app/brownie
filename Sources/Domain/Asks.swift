import Foundation

/// A question or request someone put to the user in a direct chat, and whether the user answered.
/// Kept on this Mac only: the words never go to the brain — only "asked on the 16th · you replied at 21:29".
public struct Ask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let person: String
    public let bucket: BucketID
    public let askedAt: Date
    /// The question itself, for the person's note. Local only.
    public let question: String
    public var answeredAt: Date?
    /// The user's first message after the question. Local only.
    public var reply: String?
    /// Did that message actually answer the question? nil = not yet judged.
    public var addressed: Bool?
    /// The chat's stable handle (`PersonHandle`), when the source knows one — how the registry ties the ask to a person.
    public var handle: String?
    /// Set when the question went unanswered long enough that Brownie stopped tracking it (45 days). Never nagged about again.
    public var lapsedAt: Date?
    public init(id: String, person: String, bucket: BucketID, askedAt: Date, question: String, answeredAt: Date? = nil, reply: String? = nil, addressed: Bool? = nil, handle: String? = nil, lapsedAt: Date? = nil) {
        self.id = id; self.person = person; self.bucket = bucket; self.askedAt = askedAt; self.question = question; self.answeredAt = answeredAt; self.reply = reply; self.addressed = addressed; self.handle = handle; self.lapsedAt = lapsedAt
    }
    /// Still waiting: no reply at all, or a reply that was about something else — and not yet let go.
    public var isOpen: Bool { lapsedAt == nil && (answeredAt == nil || addressed == false) }
    /// Settled: a reply that addressed it.
    public var isAnswered: Bool { answeredAt != nil && addressed != false }
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
