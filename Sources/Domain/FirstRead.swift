import Foundation

/// What Brownie reads the first time it opens a source — one policy for every source, so a chat, a mailbox
/// and a folder all start from the same idea: recent history, bounded. A bucket is on its "first read" until
/// the ingest core has walked it to the bottom once; only a complete bucket hands its mark back to the source,
/// so a run stopped halfway through a first read lists the same bounded slice again, never the whole history.
/// "Read further back" widens one source's window by `stepDays` each time the user asks.
public struct FirstRead: Sendable, Codable, Equatable {
    /// Chats (WhatsApp, iMessage, Telegram, Slack, Teams): this many days back, then the newest N messages per chat.
    public var chatDays = 90
    public var directChatMessages = 600
    public var groupChatMessages = 300
    /// Mail: threads newer than this, at most `mailThreads` of them, the newest `mailNewestMessages` of each.
    public var mailDays = 30
    public var mailThreads = 300
    public var mailNewestMessages = 6
    /// Files by the date they were added; notes by creation; recordings by creation.
    public var fileDays = 180
    public var noteDays = 365
    public var voiceDays = 90
    /// Days the user added per source with "Read further back", keyed by the source id's raw value.
    public var extraDays: [String: Int] = [:]

    /// One press of "Read further back" adds this many days.
    public static let stepDays = 90

    /// The policy every source consults. The app loads it from the store at start-up and writes back
    /// when the user widens a window; the CLI and tests run on the defaults.
    nonisolated(unsafe) public static var current = FirstRead()

    public init() {}

    // Fields absent from a stored policy fall back to their defaults, so a policy saved by an older build
    // keeps working when a new number is added.
    private enum Key: String, CodingKey { case chatDays, directChatMessages, groupChatMessages, mailDays, mailThreads, mailNewestMessages, fileDays, noteDays, voiceDays, extraDays }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        chatDays = try c.decodeIfPresent(Int.self, forKey: .chatDays) ?? chatDays
        directChatMessages = try c.decodeIfPresent(Int.self, forKey: .directChatMessages) ?? directChatMessages
        groupChatMessages = try c.decodeIfPresent(Int.self, forKey: .groupChatMessages) ?? groupChatMessages
        mailDays = try c.decodeIfPresent(Int.self, forKey: .mailDays) ?? mailDays
        mailThreads = try c.decodeIfPresent(Int.self, forKey: .mailThreads) ?? mailThreads
        mailNewestMessages = try c.decodeIfPresent(Int.self, forKey: .mailNewestMessages) ?? mailNewestMessages
        fileDays = try c.decodeIfPresent(Int.self, forKey: .fileDays) ?? fileDays
        noteDays = try c.decodeIfPresent(Int.self, forKey: .noteDays) ?? noteDays
        voiceDays = try c.decodeIfPresent(Int.self, forKey: .voiceDays) ?? voiceDays
        extraDays = try c.decodeIfPresent([String: Int].self, forKey: .extraDays) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(chatDays, forKey: .chatDays); try c.encode(directChatMessages, forKey: .directChatMessages); try c.encode(groupChatMessages, forKey: .groupChatMessages)
        try c.encode(mailDays, forKey: .mailDays); try c.encode(mailThreads, forKey: .mailThreads); try c.encode(mailNewestMessages, forKey: .mailNewestMessages)
        try c.encode(fileDays, forKey: .fileDays); try c.encode(noteDays, forKey: .noteDays); try c.encode(voiceDays, forKey: .voiceDays)
        try c.encode(extraDays, forKey: .extraDays)
    }

    // MARK: what a source gets

    /// The shape of a source, as far as the first read is concerned.
    public enum Shape: Sendable, Equatable { case chat, mail, files, notes, voice, other }

    public static func shape(of source: SourceID) -> Shape {
        switch source.rawValue {
        case "whatsapp", "imessage", "telegram", "slack", "teams": return .chat
        case "gmail": return .mail
        case "files": return .files
        case "notes": return .notes
        case "voicememos", "recordings": return .voice
        default: return .other
        }
    }

    /// Days back a first read of this source covers: the policy's number for its shape plus whatever the user added.
    public func days(for source: SourceID) -> Int {
        let base: Int
        switch Self.shape(of: source) {
        case .chat, .other: base = chatDays
        case .mail: base = mailDays
        case .files: base = fileDays
        case .notes: base = noteDays
        case .voice: base = voiceDays
        }
        return base + (extraDays[source.rawValue] ?? 0)
    }

    /// The oldest moment a first read of this source looks at.
    public func window(for source: SourceID, now: Date) -> Date {
        now.addingTimeInterval(-Double(days(for: source)) * 86_400)
    }

    /// The most messages a first read keeps of one chat, before "Read further back" is taken into account.
    public func chatCap(isGroup: Bool) -> Int { isGroup ? groupChatMessages : directChatMessages }

    /// The most messages a first read keeps of one chat from this source: the base cap, plus one more base cap
    /// for every step of "Read further back" the user asked for. A busy chat is bounded by the cap long before
    /// the window, so widening the days alone would re-slice the same newest messages off the top and reach
    /// nothing older; growing the cap with the days is what makes the press reach further back.
    public func chatCap(isGroup: Bool, for source: SourceID) -> Int {
        let base = chatCap(isGroup: isGroup)
        return base + base * ((extraDays[source.rawValue] ?? 0) / Self.stepDays)
    }

    /// "Read further back": one more step of days for this source.
    public mutating func readFurtherBack(_ source: SourceID) {
        extraDays[source.rawValue, default: 0] += Self.stepDays
    }

    /// The line Settings shows under a source: what its first read covers. Nil for sources the policy leaves alone.
    public func describe(for source: SourceID) -> String? {
        let d = days(for: source)
        switch Self.shape(of: source) {
        case .chat: return "first read: last \(d) days, up to \(chatCap(isGroup: false, for: source)) messages per direct chat and \(chatCap(isGroup: true, for: source)) per group"
        case .mail: return "first read: last \(d) days, up to \(mailThreads) threads, the newest \(mailNewestMessages) messages of each"
        case .files: return "first read: files added in the last \(d) days"
        case .notes: return "first read: notes created in the last \(d) days"
        case .voice: return "first read: recordings from the last \(d) days"
        case .other: return nil
        }
    }

    // MARK: persistence

    /// The stored policy, or the defaults when nothing was saved or it does not parse.
    public static func load(from store: any RunStore) async -> FirstRead {
        guard let j = try? await store.value(SettingKey.firstRead), let d = j.data(using: .utf8) else { return FirstRead() }
        return (try? JSONDecoder().decode(FirstRead.self, from: d)) ?? FirstRead()
    }

    public func save(to store: any RunStore) async throws {
        let d = try JSONEncoder().encode(self)
        try await store.setValue(SettingKey.firstRead, String(decoding: d, as: UTF8.self))
    }
}
