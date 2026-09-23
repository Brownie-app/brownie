import Foundation
import Domain
import Platform

// MARK: - What an evidence label points at

/// A card's evidence names where a fact came from. The brain writes the labels in its own words
/// ("WhatsApp summary #1 · Kanika Pandey Loadmill", "People/Karan.md", "Recording · Meera call · 03:12");
/// this reads them back into something the app can open.
public enum EvidenceRef: Equatable, Sendable {
    case chat(app: String, name: String)      // app: whatsapp | imessage | telegram | slack | teams
    case note(path: String)
    case recording(name: String, seconds: TimeInterval?)
    case loops
    case mail(label: String)
    case file(label: String)
    case unknown(String)

    static let apps: [(String, String)] = [("whatsapp", "whatsapp"), ("imessage", "imessage"), ("messages", "imessage"), ("telegram", "telegram"), ("slack", "slack"), ("teams", "teams")]

    public static func parse(source: String) -> EvidenceRef {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasSuffix(".md") || lower.hasPrefix("people/") || lower.hasPrefix("groups/") || lower.hasPrefix("household/") { return .note(path: s) }
        if lower.contains("loops ledger") || lower == "loop" || lower.hasPrefix("loop ·") { return .loops }
        let parts = s.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        if lower.hasPrefix("recording") || lower.hasPrefix("voice memo") || lower.contains("· recording") {
            let name = parts.dropFirst().first { !$0.lowercased().hasPrefix("recording") && !$0.lowercased().hasPrefix("voice") && stamp($0) == nil } ?? parts.last ?? s
            return .recording(name: name, seconds: parts.compactMap(stamp).first)
        }
        if lower.contains("gmail") || lower.contains("mail") && !lower.contains("imessage") { return .mail(label: s) }
        if let app = apps.first(where: { lower.contains($0.0) })?.1 {
            // the chat name is the part that isn't the app word or a "summary #n"
            // "#design" is a Slack channel; "#1" is a summary number
            let name = parts.first { p in let l = p.lowercased(); return !apps.contains { l.hasPrefix($0.0) } && !(l.hasPrefix("#") && l.dropFirst().allSatisfy(\.isNumber)) && !l.hasPrefix("summary") }
                ?? afterWith(s) ?? ""
            return .chat(app: app, name: cleanName(name))
        }
        if lower.hasPrefix("summary #") || lower.hasPrefix("#") {
            if let n = parts.dropFirst().first { return .file(label: n) }
        }
        return .unknown(s)
    }

    /// "WhatsApp with Nayan" → "Nayan".
    static func afterWith(_ s: String) -> String? {
        guard let r = s.range(of: " with ", options: .caseInsensitive) else { return nil }
        return String(s[r.upperBound...])
    }
    /// "nayan bsb (+919034935256)" → "nayan bsb".
    public static func cleanName(_ n: String) -> String {
        var t = n
        if let r = t.range(of: "(") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }
    /// "03:12" → 192, "1:02:05" → 3725; anything else nil.
    public static func stamp(_ s: String) -> TimeInterval? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard p.count >= 2, p.count <= 3, p.allSatisfy({ $0 != nil }) else { return nil }
        let v = p.map { $0! }
        return v.count == 2 ? TimeInterval(v[0] * 60 + v[1]) : TimeInterval(v[0] * 3600 + v[1] * 60 + v[2])
    }

    /// The date in a `when` label, when it names one: "13 Sep 2026", "13 Sep 2026 (#1)", "2026-09-02–2026-09-13" (the later day).
    public static func date(when: String, calendar: Calendar = .current) -> Date? {
        let w = when.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let iso = DateFormatter(); iso.calendar = calendar; iso.timeZone = calendar.timeZone; iso.dateFormat = "yyyy-MM-dd"
        let isoHits = w.matches(of: #/\d{4}-\d{2}-\d{2}/#).compactMap { iso.date(from: String($0.output)) }
        if let last = isoHits.last { return last }
        let long = DateFormatter(); long.calendar = calendar; long.timeZone = calendar.timeZone; long.locale = Locale(identifier: "en_US_POSIX"); long.dateFormat = "d MMM yyyy"
        for m in w.matches(of: #/\d{1,2} [A-Za-z]{3} \d{4}/#) { if let d = long.date(from: String(m.output)) { return d } }
        return nil
    }
}

// MARK: - Finding the line inside the chat

public enum EvidenceMatch {
    /// The message that best matches the evidence text, by shared words; nil when nothing overlaps enough.
    public static func best(_ messages: [ChatMessage], text: String) -> Int? {
        let target = words(text)
        guard !target.isEmpty else { return nil }
        var bestI: Int? = nil, bestScore = 0.0
        for (i, m) in messages.enumerated() {
            let w = words(m.text); guard !w.isEmpty else { continue }
            let score = Double(w.intersection(target).count) / Double(min(w.count, target.count))
            if score > bestScore { bestScore = score; bestI = i }
        }
        return bestScore >= 0.34 ? bestI : nil
    }
    static let stop: Set<String> = ["the", "and", "for", "with", "about", "that", "this", "you", "your", "was", "were", "have", "has", "had", "will", "said", "says", "user", "asked", "told", "from", "are", "not", "but", "she", "her", "him", "his", "they", "them", "then", "than", "into", "onto", "also"]
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }
}

// MARK: - Reading the chat back, on demand

/// A source that can show the original messages of a chat. Read on demand, never stored, never sent.
public protocol ChatReader: Sendable {
    func chats() async throws -> [BucketInfo]
    func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage]
}

public struct EvidenceWindow: Sendable, Equatable {
    public let chat: BucketInfo
    public let messages: [ChatMessage]
    public let highlight: Int?
    public init(chat: BucketInfo, messages: [ChatMessage], highlight: Int?) { self.chat = chat; self.messages = messages; self.highlight = highlight }
}

public enum EvidenceResolver {
    public static let daysAround = 2.0
    /// The chat whose name matches best: exact, then prefix, then contains — case-insensitive, phones stripped.
    public static func chat(named name: String, in chats: [BucketInfo]) -> BucketInfo? {
        let n = EvidenceRef.cleanName(name).lowercased()
        guard !n.isEmpty else { return nil }
        func nm(_ b: BucketInfo) -> String { EvidenceRef.cleanName(b.name).lowercased() }
        return chats.first { nm($0) == n } ?? chats.first { nm($0).hasPrefix(n) || n.hasPrefix(nm($0)) } ?? chats.first { nm($0).contains(n) || n.contains(nm($0)) }
    }

    /// The messages around the evidence's day (± `daysAround`; the last week when the day is unknown), with the matching line marked.
    public static func resolve(_ ref: EvidenceRef, when: String, text: String, reader: any ChatReader, now: Date = Date()) async throws -> EvidenceWindow? {
        guard case .chat(_, let name) = ref, let chat = chat(named: name, in: try await reader.chats()) else { return nil }
        let day = EvidenceRef.date(when: when)
        let from = day.map { $0.addingTimeInterval(-daysAround * 86400) } ?? now.addingTimeInterval(-7 * 86400)
        let to = day.map { $0.addingTimeInterval((daysAround + 1) * 86400) } ?? now
        let msgs = try await reader.messages(in: chat.id, from: from, to: to)
        return EvidenceWindow(chat: chat, messages: msgs, highlight: EvidenceMatch.best(msgs, text: text))
    }
}

// MARK: - The local sources as readers

extension WhatsAppSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        let pk = Int64(bucket.rawValue.dropFirst("whatsapp:".count)) ?? 0
        return try WALSafeCopy.withCopy(of: Self.database) { db in try Self.messages(db, session: pk, fromDate: from.timeIntervalSinceReferenceDate, toDate: to.timeIntervalSinceReferenceDate) }
    }
}

extension iMessageSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        let chatID = Int64(bucket.rawValue.dropFirst("imessage:".count)) ?? 0
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            let names = ContactNames()
            let rows = try db.query("""
            SELECT m.ROWID AS id, m.date AS d, m.is_from_me AS me, m.text AS t, m.attributedBody AS body, h.id AS handle
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id
            WHERE j.chat_id=? AND m.date BETWEEN ? AND ? ORDER BY m.ROWID ASC
            """, [.int(chatID), .int(AppleDates.toMessagesDate(from)), .int(AppleDates.toMessagesDate(to))])
            return rows.compactMap { r in
                let text = r["t"].text.flatMap { $0.isEmpty ? nil : $0 } ?? r["body"].blob.flatMap(TypedStream.extractString)
                guard let text, !text.isEmpty, let id = r["id"].int else { return nil }
                let me = (r["me"].int ?? 0) == 1
                return ChatMessage(rowID: id, date: AppleDates.fromMessagesDate(r["d"].int ?? 0), sender: me ? "Me" : names.resolve(r["handle"].text ?? "?"), isMe: me, text: text)
            }
        }
    }
}
