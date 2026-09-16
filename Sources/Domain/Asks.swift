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
    public init(id: String, person: String, bucket: BucketID, askedAt: Date, question: String, answeredAt: Date? = nil) {
        self.id = id; self.person = person; self.bucket = bucket; self.askedAt = askedAt; self.question = question; self.answeredAt = answeredAt
    }
    public var isOpen: Bool { answeredAt == nil }
}

/// A chat source that can tell what was asked of the user lately.
public protocol AskScanning: Sendable {
    func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask]
}
