import Foundation
import Domain

/// Reads a direct chat the way a person would: their message that ends in a question mark or starts like a request
/// is an ask; the user's next message after it is the answer. Groups are skipped — a question there is rarely to the user.
public enum AskDetector {
    static let askStarts = ["can you", "could you", "would you", "will you", "please", "pls", "plz", "send me", "share", "let me know", "tell me", "any update", "did you", "have you", "when can", "what's the", "whats the", "where is", "how do",
                            "bata do", "batao", "bhej do", "bhejo", "kaise", "kab", "kya", "kahan", "chahiye", "kar do", "karo", "dena", "de do", "kar sakte", "ho gaya", "hua kya"]
    /// True when the line reads as a question or request.
    public static func isAsk(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 4 else { return false }
        if t.hasSuffix("?") || t.hasSuffix("??") || t.contains("?") && t.count < 200 { return true }
        // a request starts like one; a request word buried in the user's own kind of sentence ("I'll share…") does not count
        if t.hasPrefix("i'll ") || t.hasPrefix("i’ll ") || t.hasPrefix("i will ") || t.hasPrefix("i'm ") || t.hasPrefix("i’m ") { return false }
        return askStarts.contains { t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") || t == $0 } || askStarts.filter { $0.count > 4 }.contains { t.contains(" " + $0 + " ") && t.count < 120 && !$0.hasPrefix("share") }
    }

    /// Asks in one direct chat (ascending messages), each with the user's first reply after it — or, for an ask whose
    /// first reply was already judged to be about something else (`judged`, by ask id), the user's next message after
    /// that reply. Until there is one the judged reply stands, so the ask still reads "you wrote, but not about this".
    public static func detect(_ messages: [ChatMessage], person: String, bucket: BucketID, since: Date, handle: String? = nil, judged: [String: Date] = [:]) -> [Ask] {
        var out: [Ask] = []
        let recent = messages.filter { $0.date >= since }.sorted { $0.date < $1.date }
        for (i, m) in recent.enumerated() where !m.isMe && isAsk(m.text) {
            let id = "ask-" + String("\(bucket.rawValue)|\(m.rowID)".utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
            // a burst of their messages with a question in the middle: the reply that counts is the first "Me" after the burst
            let replies = recent[(i + 1)...].filter(\.isMe)
            let reply = judged[id].flatMap { j in replies.first { $0.date > j } ?? replies.first { $0.date == j } } ?? replies.first
            out.append(Ask(id: id, person: person, bucket: bucket, askedAt: m.date, question: String(m.text.prefix(200)), answeredAt: reply?.date, reply: reply.map { String($0.text.prefix(300)) }, handle: handle))
        }
        return out
    }
}

/// Every chat source that can read messages back can also scan them for asks — direct chats only, each read back
/// as far as its own asks need.
extension ChatReader where Self: Source {
    public func scanAsks(enabled: Set<BucketID>?, scan: AskScan, now: Date = Date()) async throws -> [Ask] {
        let chats = try await chats().filter { !$0.isGroup && (enabled?.contains($0.id) ?? false) }
        var out: [Ask] = []
        for c in chats {
            let since = scan.since(c.id)
            let msgs = try await messages(in: c.id, from: since, to: now.addingTimeInterval(3600))
            out += AskDetector.detect(msgs, person: c.name, bucket: c.id, since: since, handle: c.handle, judged: scan.judgedReplies)
        }
        return out
    }
}
extension WhatsAppSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask] { try await scanAsks(enabled: enabled, scan: scan) } }
extension iMessageSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask] { try await scanAsks(enabled: enabled, scan: scan) } }
