import XCTest
@testable import Knowledge
import Domain
import Platform

/// The MCP server as another app sees it: the protocol, the off switch, the log.
final class MCPServerTests: XCTestCase {
    func makeServer() async throws -> (MCPServer, SQLiteRunStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "# Karan\n\nPriya's brother. Owes his villa share.".write(to: root.appendingPathComponent("People/Karan.md"), atomically: true, encoding: .utf8)
        let kb = try FileKnowledgeStore(root: root, indexPath: root.appendingPathComponent("index.sqlite").path)
        let store = try SQLiteRunStore.inMemory()
        return (MCPServer(knowledge: kb, store: store, client: "Test"), store, root)
    }
    func call(_ s: MCPServer, _ req: [String: Any]) async -> [String: Any]? { await s.handle(req) }

    func testInitializeAndToolsList() async throws {
        let (s, _, _) = try await makeServer()
        let hello = await call(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertEqual((hello?["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.protocolVersion)
        let list = await call(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["search_notes", "read_note", "who_is", "open_loops", "recent_cards"])
    }
    func testNotificationsGetNoReply() async throws {
        let (s, _, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(r)
    }
    func testRefusesWhenSwitchedOff() async throws {
        let (s, store, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "who_is", "arguments": ["name": "Karan"]]])
        let res = r?["result"] as? [String: Any]
        XCTAssertEqual(res?["isError"] as? Bool, true)
        let log = try await store.value(SettingKey.mcpLog)
        XCTAssertNil(log, "a refused call is not a read and is not logged as one")
    }
    func testAnswersAndLogsWhenOn() async throws {
        let (s, store, _) = try await makeServer()
        try await store.setValue(SettingKey.mcpEnabled, "true")
        let r = await call(s, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "who_is", "arguments": ["name": "Karan"]]])
        let text = (((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("villa share"))
        let log = try await store.value(SettingKey.mcpLog)
        let asks = try JSONDecoder().decode([MCPAsk].self, from: Data((log ?? "[]").utf8))
        XCTAssertEqual(asks.first?.tool, "who_is"); XCTAssertEqual(asks.first?.client, "Test"); XCTAssertTrue(asks.first?.result.contains("People/Karan.md") ?? false)
    }
    func testUnknownMethodIsAnError() async throws {
        let (s, _, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        XCTAssertNotNil(r?["error"])
    }
    func testConfigInstallMergesWithoutClobbering() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.write(to: f, atomically: true, encoding: .utf8)
        try MCPServer.install(into: f, executable: "/App/Brownie", client: "Claude Desktop")
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        let servers = j["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"]); XCTAssertEqual(j["theme"] as? String, "dark")
        XCTAssertEqual((servers["brownie"] as? [String: Any])?["args"] as? [String], ["mcp", "--client", "Claude Desktop"])
        XCTAssertTrue(MCPServer.isInstalled(in: f))
    }
}
