import Foundation
import Domain

/// What a first read of one chat keeps, and how much it set aside.
public struct FirstReadCut: Sendable, Equatable {
    /// Ascending, like the input: the messages inside the window, the newest ones up to the cap.
    public let messages: [ChatMessage]
    /// Messages inside the window that the cap left out.
    public let deferred: Int
    public init(messages: [ChatMessage], deferred: Int) { self.messages = messages; self.deferred = deferred }
}

public extension ChatWindowing {
    /// The first read of a chat: only messages newer than the policy's window for this source, and of those only
    /// the newest `directChatMessages` or `groupChatMessages`. Older history rarely makes a card and would cost
    /// an hour on a big group, so it is left unread and counted, never silently dropped. Ascending in, ascending out.
    static func firstReadSlice(_ msgs: [ChatMessage], isGroup: Bool, policy: FirstRead, source: SourceID, now: Date) -> FirstReadCut {
        let edge = policy.window(for: source, now: now)
        let inWindow = msgs.filter { $0.date >= edge }
        let cap = policy.chatCap(isGroup: isGroup)
        guard inWindow.count > cap else { return FirstReadCut(messages: inWindow, deferred: 0) }
        return FirstReadCut(messages: Array(inWindow.suffix(cap)), deferred: inWindow.count - cap)
    }
}

/// The first read of a dated, item-shaped source (files, notes, recordings): only items dated inside the policy's
/// window for that source. An item without a date is kept, since nothing says it is old.
public enum FirstReadFilter {
    public static func inWindow(_ items: [Candidate], policy: FirstRead, source: SourceID, now: Date) -> [Candidate] {
        let edge = policy.window(for: source, now: now)
        return items.filter { $0.itemDate.map { $0 >= edge } ?? true }
    }
}
