import Testing
import Foundation
@testable import Knowledge
import Domain
import Platform

/// The MCP server as another app sees it: the protocol, the off switch, the log.
@Suite struct MCPServerTests {
    func makeServer() async throws -> (MCPServer, SQLiteRunStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "# Karan\n\nPriya's brother. Owes his villa share.".write(to: root.appendingPathComponent("People/Karan.md"), atomically: true, encoding: .utf8)
        let kb = try FileKnowledgeStore(root: root, indexPath: root.appendingPathComponent("index.sqlite").path)
        let store = try SQLiteRunStore.inMemory()
        return (MCPServer(knowledge: kb, store: store, client: "Test"), store, root)
    }
    func call(_ s: MCPServer, _ req: [String: Any]) async -> [String: Any]? { await s.handle(req) }

    @Test func testInitializeAndToolsList() async throws {
        let (s, _, _) = try await makeServer()
        let hello = await call(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        #expect((hello?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersion)
        let list = await call(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["search_notes", "read_note", "who_is", "open_loops", "recent_cards"])
    }
    @Test func testNotificationsGetNoReply() async throws {
        let (s, _, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(r == nil)
    }
    @Test func testRefusesWhenSwitchedOff() async throws {
        let (s, store, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "who_is", "arguments": ["name": "Karan"]]])
        let res = r?["result"] as? [String: Any]
        #expect(res?["isError"] as? Bool == true)
        let log = try await store.value(SettingKey.mcpLog)
        #expect(log == nil, "a refused call is not a read and is not logged as one")
    }
    @Test func testAnswersAndLogsWhenOn() async throws {
        let (s, store, _) = try await makeServer()
        try await store.setValue(SettingKey.mcpEnabled, "true")
        let r = await call(s, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "who_is", "arguments": ["name": "Karan"]]])
        let text = (((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("villa share"))
        let log = try await store.value(SettingKey.mcpLog)
        let asks = try JSONDecoder().decode([MCPAsk].self, from: Data((log ?? "[]").utf8))
        #expect(asks.first?.tool == "who_is"); #expect(asks.first?.client == "Test"); #expect(asks.first?.result.contains("People/Karan.md") ?? false)
    }
    @Test func testUnknownMethodIsAnError() async throws {
        let (s, _, _) = try await makeServer()
        let r = await call(s, ["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        #expect(r?["error"] != nil)
    }
    @Test func testConfigInstallMergesWithoutClobbering() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.write(to: f, atomically: true, encoding: .utf8)
        try MCPServer.install(into: f, executable: "/App/Brownie", client: "Claude Desktop")
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        let servers = j["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil); #expect(j["theme"] as? String == "dark")
        #expect((servers["brownie"] as? [String: Any])?["args"] as? [String] == ["mcp", "--client", "Claude Desktop"])
        #expect(MCPServer.isInstalled(in: f))
    }
}
