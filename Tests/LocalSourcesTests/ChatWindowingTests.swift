import XCTest
@testable import LocalSources
import Domain

final class ChatWindowingTests: XCTestCase {
    func testEveryMessageLandsInExactlyOneWindow() {
        let chat = ChatInfo(id: "c", name: "Family", isGroup: true, memberCount: 5)
        var msgs: [ChatMessage] = []
        for i in 1...300 {
            let me = i % 3 == 0
            msgs.append(ChatMessage(rowID: Int64(i), date: Date(timeIntervalSince1970: Double(i) * 60), sender: me ? "Me" : "Amma", isMe: me, text: String(repeating: "hello ", count: 20)))
        }
        let w = ChatWindowing.windows(msgs, chat: chat)
        XCTAssertGreaterThan(w.count, 1)
        XCTAssertEqual(w.reduce(0) { $0 + $1.messageCount }, 300)
        XCTAssertEqual(w.first?.firstRowID, 1); XCTAssertEqual(w.last?.lastRowID, 300)
        XCTAssertTrue(w[0].text.hasPrefix("Chat: Family · GROUP (5 members)"))
        XCTAssertTrue(w[0].text.contains("sent by Me (the user)"))
        for x in w { XCTAssertLessThanOrEqual(x.text.utf8.count, ChatWindowing.targetBytes + 2500) }
    }

    func testClampNeverExceedsHardCap() {
        let s = ChatWindowing.clamp(String(repeating: "x", count: ChatWindowing.hardCapBytes * 2))
        XCTAssertLessThan(s.utf8.count, ChatWindowing.hardCapBytes + 64)
    }

    func testTypedStreamExtraction() {
        // "NSString" marker, '+' tag, 1-byte length, UTF-8 payload
        var bytes: [UInt8] = Array("junkNSString".utf8) + [0x01, 0x2B, 0x05] + Array("hello".utf8) + [0x86, 0x84]
        XCTAssertEqual(TypedStream.extractString(Data(bytes)), "hello")
        let long = String(repeating: "a", count: 300)
        bytes = Array("NSString".utf8) + [0x01, 0x2B, 0x81, 0x2C, 0x01] + Array(long.utf8)
        XCTAssertEqual(TypedStream.extractString(Data(bytes)), long)
    }

    func testGunzipAndProtobufWalk() throws {
        // gzip a tiny protobuf: field 2 (len-delimited) containing field 2 string "Grocery list for Sunday"
        let inner: [UInt8] = [0x12, 23] + Array("Grocery list for Sunday".utf8)
        let outer: [UInt8] = [0x12, UInt8(inner.count)] + inner
        let raw = Data(outer)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var gz = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0]); gz.append(deflated); gz.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(NoteBody.text(fromGzippedProtobuf: gz), "Grocery list for Sunday")
    }
}
