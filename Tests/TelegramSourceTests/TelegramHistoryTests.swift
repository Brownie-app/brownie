import Testing
import Foundation
@testable import TelegramSource
import LocalSources
import Domain

/// A chat's history the way TDLib pages it: newest first, `limit` at a time, from the message id asked for.
/// Every message is the user's own, so no name lookups happen; the fake counts the pages it was asked for.
final class ScriptedChat: TDSending, @unchecked Sendable {
    let ids: [Int64]   // newest first
    let me: Int64 = 7
    let base = Date(timeIntervalSince1970: 1_789_500_000)
    private let lock = NSLock()
    private(set) var pages = 0
    /// `count` messages, ids counting down from `newest`, one second apart.
    init(count: Int, newest: Int64 = 100_000) { ids = (0..<count).map { newest - Int64($0) } }

    func send(_ req: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard req["@type"] as? String == "getChatHistory" else { return ["id": me] }
        lock.lock(); pages += 1; lock.unlock()
        let from = req["from_message_id"] as? Int64 ?? 0
        let limit = req["limit"] as? Int ?? 100
        let page = ids.filter { from == 0 || $0 < from }.prefix(limit)
        return ["messages": page.map { id -> [String: Any] in
            ["id": id, "date": Int(base.timeIntervalSince1970) - Int(ids[0] - id),
             "sender_id": ["@type": "messageSenderUser", "user_id": me],
             "content": ["@type": "messageText", "text": ["text": "m\(id)"]]]
        }]
    }
}

/// Paging a Telegram chat: a read since the mark goes all the way down to it, and a bounded read says when it stopped short.
@Suite struct TelegramHistoryTests {
    @Test func aReadSinceTheMarkPagesDownToTheMarkHoweverManyPagesThatTakes() async throws {
        // 2,500 messages above the mark: far past the page cap of 20 and the old 1,200-message ceiling.
        let chat = ScriptedChat(count: 3_001)
        let mark: Int64 = 100_000 - 2_500
        let h = try await TelegramSource.history(chat, chatID: 1, me: chat.me, limit: nil) { $0.rowID <= mark }
        #expect(h.messages.count == 2_500 && h.stoppedShort == false, "every message since the mark, none set aside")
        #expect(h.messages.first?.rowID == mark + 1 && h.messages.last?.rowID == 100_000, "ascending, from just above the mark")
        #expect(chat.pages == 26, "25 full pages, then the page that holds the mark")
    }

    @Test func aBoundedReadThatFillsItsLimitOnAPageEdgeSaysItStoppedShort() async throws {
        // 600 messages land exactly on six full pages; the old formula called that "nothing left" while thousands sat behind it.
        let chat = ScriptedChat(count: 3_000)
        let h = try await TelegramSource.history(chat, chatID: 1, me: chat.me, limit: 600) { _ in false }
        #expect(h.messages.count == 600 && chat.pages == 6)
        #expect(h.stoppedShort, "the limit, not the window edge, ended paging")
    }

    @Test func aBoundedReadThatReachesTheEdgeOrTheStartOfTheChatIsNotShort() async throws {
        let chat = ScriptedChat(count: 250)
        let edge = try await TelegramSource.history(chat, chatID: 1, me: chat.me, limit: 600) { $0.rowID < 99_901 }
        #expect(edge.messages.count == 100 && edge.stoppedShort == false, "the stopping message ends paging cleanly")
        let whole = try await TelegramSource.history(ScriptedChat(count: 250), chatID: 1, me: chat.me, limit: 600) { _ in false }
        #expect(whole.messages.count == 250 && whole.stoppedShort == false, "so does the start of the chat")
    }

    @Test func aBoundedReadStoppedByThePageCapSaysSo() async throws {
        let chat = ScriptedChat(count: 3_000)
        let h = try await TelegramSource.history(chat, chatID: 1, me: chat.me, limit: 5_000) { _ in false }
        #expect(chat.pages == TelegramSource.pageCap && h.messages.count == 2_000)
        #expect(h.stoppedShort, "the page cap left a thousand messages unseen")
    }
}
