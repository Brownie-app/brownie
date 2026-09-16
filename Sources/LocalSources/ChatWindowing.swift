import Foundation
import Domain

/// One message in any chat-like source, already resolved to display names.
public struct ChatMessage: Sendable, Equatable {
    public let rowID: Int64
    public let date: Date
    public let sender: String      // "Me" for the user
    public let isMe: Bool
    public let text: String
    public init(rowID: Int64, date: Date, sender: String, isMe: Bool, text: String) {
        self.rowID = rowID; self.date = date; self.sender = sender; self.isMe = isMe; self.text = text
    }
}

public struct ChatInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isGroup: Bool
    public let memberCount: Int
    public init(id: String, name: String, isGroup: Bool, memberCount: Int) { self.id = id; self.name = name; self.isGroup = isGroup; self.memberCount = memberCount }
}

/// A window is the unit the reader judges: a time-ordered slice of ONE chat sized by a byte budget.
/// The header tells the reader who "Me" is, whether it's a group, and how many lines are the user's —
/// the attribution guard rails the group-chat prompt depends on.
public struct ChatWindow: Sendable, Equatable {
    public let chat: ChatInfo
    public let firstRowID: Int64
    public let lastRowID: Int64
    public let firstDate: Date
    public let lastDate: Date
    public let messageCount: Int
    public let myCount: Int
    public let text: String
}

public enum ChatWindowing {
    public static let targetBytes = 12 * 1024
    public static let hardCapBytes = 48 * 1024

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f }()

    /// Messages a chat database can hold that no reader should see as "the newest": ones dated in the future.
    /// WhatsApp keeps the odd row stamped years ahead (a scheduled or malformed message); windowed as-is it becomes
    /// the newest item, the cursor's mark leaps past every real message, and the chat reads as "nothing new" forever.
    public static func sane(_ messages: [ChatMessage], now: Date, slack: TimeInterval = 86400) -> [ChatMessage] {
        messages.filter { $0.date <= now.addingTimeInterval(slack) }
    }

    /// Ascending messages → windows (ascending). Every message lands in exactly one window.
    public static func windows(_ messages: [ChatMessage], chat: ChatInfo) -> [ChatWindow] {
        var out: [ChatWindow] = []
        var buf: [ChatMessage] = []
        var bytes = 0
        func flush() {
            guard let f = buf.first, let l = buf.last else { return }
            let body = buf.map(line).joined(separator: "\n")
            let mine = buf.filter(\.isMe).count
            let header = "Chat: \(chat.name) · \(chat.isGroup ? "GROUP (\(chat.memberCount) members)" : "direct message") · \(buf.count) messages, \(mine) of them sent by Me (the user)."
            out.append(ChatWindow(chat: chat, firstRowID: f.rowID, lastRowID: l.rowID, firstDate: f.date, lastDate: l.date,
                                  messageCount: buf.count, myCount: mine, text: header + "\n\n" + body))
            buf.removeAll(); bytes = 0
        }
        for m in messages {
            let n = line(m).utf8.count + 1
            if bytes + n > targetBytes, !buf.isEmpty { flush() }
            buf.append(m); bytes += n
        }
        flush()
        return out
    }

    static func line(_ m: ChatMessage) -> String {
        let t = m.text.replacingOccurrences(of: "\n", with: " ").prefix(2000)
        return "[\(time.string(from: m.date))] \(m.isMe ? "Me" : m.sender): \(t)"
    }

    /// Backstop so a prompt can never exceed the model context.
    public static func clamp(_ text: String) -> String {
        guard text.utf8.count > hardCapBytes else { return text }
        var s = String(decoding: text.utf8.prefix(hardCapBytes), as: UTF8.self)
        s += "\n…(window truncated)"
        return s
    }
}
