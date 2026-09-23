import Foundation

/// One person in the household. `isMe` marks this Mac's owner. Open to more than two — the flows decide later.
public struct HouseholdMember: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var isMe: Bool
    /// Digits only, for matching chat members ("919034935256"); optional.
    public var phone: String?
    public init(id: String = UUID().uuidString, name: String, isMe: Bool, phone: String? = nil) { self.id = id; self.name = name; self.isMe = isMe; self.phone = phone }
    /// The name as it appears on cards: first name.
    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Two (or more) people, two Macs, one shared folder. Each keeps their own Brownie; only what all of them are in is shared.
public struct Household: Codable, Sendable, Equatable {
    public var members: [HouseholdMember]
    /// The shared folder both Macs sync to — an iCloud Drive folder shared with Family Sharing.
    public var folderPath: String
    /// Chats every member is in and the user chose to share (BucketID raw values).
    public var sharedBuckets: [String]
    public var calendarShared: Bool
    public var since: Date
    public init(members: [HouseholdMember], folderPath: String, sharedBuckets: [String] = [], calendarShared: Bool = false, since: Date) {
        self.members = members; self.folderPath = folderPath; self.sharedBuckets = sharedBuckets; self.calendarShared = calendarShared; self.since = since
    }
    public var me: HouseholdMember? { members.first { $0.isMe } }
    public var others: [HouseholdMember] { members.filter { !$0.isMe } }
    /// "Priya" · "Priya and Amma" — for sentences.
    public var othersLine: String {
        let n = others.map(\.firstName)
        switch n.count { case 0: return "no one yet"; case 1: return n[0]; default: return n.dropLast().joined(separator: ", ") + " and " + n.last! }
    }
    public func isShared(_ bucket: BucketID) -> Bool { sharedBuckets.contains(bucket.rawValue) }
}

/// Which chats can be shared: only ones every other member is in, by phone or by name.
public enum HouseholdEligibility {
    public static func digits(_ s: String) -> String { s.filter(\.isNumber) }
    /// True when `member` matches one of the chat's members: the phone's last 10 digits, or the name (case-insensitive; first name alone counts when unambiguous in the list).
    public static func matches(_ member: HouseholdMember, chatMembers: [String]) -> Bool {
        if let p = member.phone.map(digits), p.count >= 7 {
            let tail = String(p.suffix(10))
            if chatMembers.contains(where: { digits($0).hasSuffix(tail) && !digits($0).isEmpty }) { return true }
        }
        let name = member.name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        let names = chatMembers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if names.contains(name) { return true }
        let first = member.firstName.lowercased()
        let firstHits = names.filter { $0 == first || $0.hasPrefix(first + " ") }
        return firstHits.count == 1
    }
    public static func isEligible(chatMembers: [String], others: [HouseholdMember]) -> Bool {
        !others.isEmpty && others.allSatisfy { matches($0, chatMembers: chatMembers) }
    }
}
