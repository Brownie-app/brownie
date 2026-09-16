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
    public init(id: String, person: String, bucket: BucketID, askedAt: Date, question: String, answeredAt: Date? = nil, reply: String? = nil, addressed: Bool? = nil, handle: String? = nil) {
        self.id = id; self.person = person; self.bucket = bucket; self.askedAt = askedAt; self.question = question; self.answeredAt = answeredAt; self.reply = reply; self.addressed = addressed; self.handle = handle
    }
    /// Still waiting: no reply at all, or a reply that was about something else.
    public var isOpen: Bool { answeredAt == nil || addressed == false }
    /// Settled: a reply that addressed it.
    public var isAnswered: Bool { answeredAt != nil && addressed != false }
}

/// A chat source that can tell what was asked of the user lately.
public protocol AskScanning: Sendable {
    func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask]
}
