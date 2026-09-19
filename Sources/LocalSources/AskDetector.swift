import Foundation
import Domain

/// Reads a direct chat the way a person would: their message that ends in a question mark or starts like a request
/// is an ask; the user's next message after it is the answer. Groups are skipped — a question there is rarely to the user.
public enum AskDetector {
    static let askStarts = ["can you", "could you", "would you", "will you", "please", "pls", "plz", "send me", "share", "let me know", "tell me", "any update", "did you", "have you", "when can", "what's the", "whats the", "where is", "how do",
                            "bata do", "batao", "bhej do", "bhejo", "kaise", "kab", "kya", "kahan", "chahiye", "kar do", "karo", "dena", "de do", "kar sakte", "ho gaya", "hua kya"]
    /// True when the line reads as a question or request.
    static let link = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+"#, options: .caseInsensitive)
    public static func isAsk(_ text: String) -> Bool {
        // a link is a thing shared, not a thing asked — its "?" is a query string; what is left around it decides
        let stripped = link.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let t = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 4 else { return false }
        if t.hasSuffix("?") || t.hasSuffix("??") || t.contains("?") && t.count < 200 { return true }
        // a request starts like one; a request word buried in the user's own kind of sentence ("I'll share…") does not count
        if t.hasPrefix("i'll ") || t.hasPrefix("i’ll ") || t.hasPrefix("i will ") || t.hasPrefix("i'm ") || t.hasPrefix("i’m ") { return false }
        return askStarts.contains { t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") || t == $0 } || askStarts.filter { $0.count > 4 }.contains { t.contains(" " + $0 + " ") && t.count < 120 && !$0.hasPrefix("share") }
    }

    /// Asks in one direct chat (ascending messages), each with the exchange after it — the window, both sides, the
    /// newest `windowLines` of them — which is what the verdict on it is read from, and with the user's first reply
    /// after it, kept as it always was: or, for an ask whose reply was already judged to be about something else
    /// (`judged`, by ask id), the user's newest message after that reply, with every user message between the two in
    /// the text (oldest first, the newest `repliesShown` of them). Until there is a newer message the judged reply
    /// stands, with the same text as before, so the ask still reads "you wrote, but not about this".
    public static func detect(_ messages: [ChatMessage], person: String, bucket: BucketID, since: Date, handle: String? = nil, judged: [String: Date] = [:]) -> [Ask] {
        var out: [Ask] = []
        let recent = messages.filter { $0.date >= since }.sorted { $0.date < $1.date }
        for (i, m) in recent.enumerated() where !m.isMe && isAsk(m.text) {
            let id = "ask-" + String("\(bucket.rawValue)|\(m.rowID)".utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
            // a burst of their messages with a question in the middle: the reply that counts is the first "Me" after the burst
            let after = recent[(i + 1)...]
            let replies = after.filter(\.isMe)
            let reply = judged[id].flatMap { j in replies.last { $0.date > j } ?? replies.first { $0.date == j } } ?? replies.first
            out.append(Ask(id: id, person: person, bucket: bucket, askedAt: m.date, question: String(m.text.prefix(200)), answeredAt: reply?.date, reply: reply.map { replyText(replies, upTo: $0) }, handle: handle, window: window(after)))
        }
        return out
    }

    /// How much of the exchange after an ask the verdict is read from: the newest twelve lines, sharing about 900 characters.
    static let windowLines = 12, windowRoom = 900
    /// The window: the newest lines after the ask from both sides, oldest first, each on one line, blank ones (a bare
    /// attachment) left out, and cut to fit the room together — the short ones keep every word, the long ones share what is left.
    static func window(_ after: ArraySlice<ChatMessage>) -> [AskLine] {
        let lines = after.map { ($0, $0.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.1.isEmpty }.suffix(windowLines)
        let cut = fit(lines.map(\.1), room: windowRoom)
        return zip(lines, cut).map { AskLine(at: $0.0.date, mine: $0.0.isMe, text: $1) }
    }
    static func fit(_ texts: [String], room: Int) -> [String] {
        var budget = room, left = texts.count, cut = [Int](repeating: 0, count: texts.count)
        for i in texts.indices.sorted(by: { texts[$0].count < texts[$1].count }) {
            let take = min(texts[i].count, budget / max(left, 1)); cut[i] = take; budget -= take; left -= 1
        }
        return zip(texts, cut).map { String($0.prefix($1)) }
    }

    /// How many of the user's messages the judge is shown at once, and the room they share — the judge's prompt cuts at 400.
    static let repliesShown = 6, replyRoom = 390
    /// The text an ask's reply carries: the paired message alone, or with the user's messages before it back to the
    /// question, newest last and each cut to its share of the room. Fixed by the messages up to the paired one, so a
    /// rescan that pairs the same message yields the same text and the judgement made about it is kept.
    static func replyText(_ replies: [ChatMessage], upTo reply: ChatMessage) -> String {
        let shown = Array(replies.prefix { $0.date <= reply.date }.suffix(repliesShown))
        guard shown.count > 1 else { return String(reply.text.prefix(300)) }
        return shown.map { String($0.text.prefix(replyRoom / shown.count)) }.joined(separator: "\n")
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
