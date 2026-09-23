import Testing
import Foundation
@testable import LocalSources
import Domain

@Suite struct ChatWindowingTests {
    @Test func testEveryMessageLandsInExactlyOneWindow() {
        let chat = ChatInfo(id: "c", name: "Family", isGroup: true, memberCount: 5)
        var msgs: [ChatMessage] = []
        for i in 1...300 {
            let me = i % 3 == 0
            msgs.append(ChatMessage(rowID: Int64(i), date: Date(timeIntervalSince1970: Double(i) * 60), sender: me ? "Me" : "Amma", isMe: me, text: String(repeating: "hello ", count: 20)))
        }
        let w = ChatWindowing.windows(msgs, chat: chat)
        #expect(w.count > 1)
        #expect(w.reduce(0) { $0 + $1.messageCount } == 300)
        #expect(w.first?.firstRowID == 1); #expect(w.last?.lastRowID == 300)
        #expect(w[0].text.hasPrefix("Chat: Family · GROUP (5 members)"))
        #expect(w[0].text.contains("sent by Me (the user)"))
        for x in w { #expect(x.text.utf8.count <= ChatWindowing.targetBytes + 2500) }
    }

    @Test func testClampNeverExceedsHardCap() {
        let s = ChatWindowing.clamp(String(repeating: "x", count: ChatWindowing.hardCapBytes * 2))
        #expect(s.utf8.count < ChatWindowing.hardCapBytes + 64)
    }

    @Test func testTypedStreamExtraction() {
        // "NSString" marker, '+' tag, 1-byte length, UTF-8 payload
        var bytes: [UInt8] = Array("junkNSString".utf8) + [0x01, 0x2B, 0x05] + Array("hello".utf8) + [0x86, 0x84]
        #expect(TypedStream.extractString(Data(bytes)) == "hello")
        let long = String(repeating: "a", count: 300)
        bytes = Array("NSString".utf8) + [0x01, 0x2B, 0x81, 0x2C, 0x01] + Array(long.utf8)
        #expect(TypedStream.extractString(Data(bytes)) == long)
    }

    @Test func testGunzipAndProtobufWalk() throws {
        // gzip a tiny protobuf: field 2 (len-delimited) containing field 2 string "Grocery list for Sunday"
        let inner: [UInt8] = [0x12, 23] + Array("Grocery list for Sunday".utf8)
        let outer: [UInt8] = [0x12, UInt8(inner.count)] + inner
        let raw = Data(outer)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var gz = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0]); gz.append(deflated); gz.append(Data(repeating: 0, count: 8))
        #expect(NoteBody.text(fromGzippedProtobuf: gz) == "Grocery list for Sunday")
    }
}

@Suite struct SaneMessagesTests {
    @Test func messagesFromTheFutureAreDropped() {
        let now = Date(timeIntervalSince1970: 1_789_500_000)
        func m(_ t: Double) -> ChatMessage { ChatMessage(rowID: Int64(t), date: Date(timeIntervalSince1970: t), sender: "Nitesh", isMe: false, text: "hi") }
        let msgs = [m(1_789_400_000), m(1_789_499_000), m(1_789_500_000 + 3600), m(2_001_513_725)]
        #expect(ChatWindowing.sane(msgs, now: now).map(\.rowID) == [1_789_400_000, 1_789_499_000, 1_789_503_600], "an hour ahead is clock skew; 2033 is not")
    }
}
