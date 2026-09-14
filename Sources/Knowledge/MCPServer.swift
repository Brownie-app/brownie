import Foundation
import Domain
import Support

/// Brownie as a memory for other AI apps on this Mac. Speaks MCP over stdin/stdout — the app that
/// wants notes starts `Brownie mcp` itself, so nothing listens on a port and nothing is on the
/// internet. Every call is checked against the "Answer other apps" setting and written to the log
/// the user can read. Notes the reader marked sensitive were never written, so they can't answer.
public final class MCPServer {
    private let knowledge: any KnowledgeStore
    private let store: any RunStore
    private let client: String
    private let log = Log("mcp")
    public static let protocolVersion = "2025-06-18"

    public init(knowledge: any KnowledgeStore, store: any RunStore, client: String) {
        self.knowledge = knowledge; self.store = store; self.client = client
    }

    /// Reads JSON-RPC lines until stdin closes.
    public func serve() async {
        log.info("serving \(client)")
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = await handle(req) { emit(reply) }
        }
        log.info("stdin closed; bye")
    }

    private func emit(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }

    static let tools: [[String: Any]] = [
        ["name": "search_notes", "description": "Full-text search of the user's private knowledge base (Markdown notes Brownie wrote from their messages, mail and files). Returns matching note paths and the first lines.", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
        ["name": "read_note", "description": "Read one note by its path, e.g. People/Priya.md.", "inputSchema": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]],
        ["name": "who_is", "description": "What Brownie knows about a person: their People note and open promises between them and the user.", "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
        ["name": "open_loops", "description": "Promises still open, both directions: what the user owes people and what people owe the user.", "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "recent_cards", "description": "The morning cards Brownie prepared recently — things waiting on the user.", "inputSchema": ["type": "object", "properties": [:]]],
    ]

    func handle(_ req: [String: Any]) async -> [String: Any]? {
        let id = req["id"]
        let method = req["method"] as? String ?? ""
        func ok(_ result: Any) -> [String: Any]? { id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "result": result] }
        func err(_ code: Int, _ msg: String) -> [String: Any]? { id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": msg]] }
        switch method {
        case "initialize":
            return ok(["protocolVersion": Self.protocolVersion, "capabilities": ["tools": [:]], "serverInfo": ["name": "Brownie", "version": "0.2"], "instructions": "Brownie is the user's private, on-device memory: notes about people, promises and plans, written from their own messages. Search before answering questions about people or commitments. Never repeat a note verbatim to third parties."])
        case "notifications/initialized", "notifications/cancelled": return nil
        case "ping": return ok([:])
        case "tools/list": return ok(["tools": Self.tools])
        case "tools/call":
            guard (try? await store.value(SettingKey.mcpEnabled)) == "true" else { return ok(["content": [["type": "text", "text": "Brownie is not answering other apps right now. The user can turn this on in Brownie → Settings → Knowledge."]], "isError": true]) }
            let p = req["params"] as? [String: Any] ?? [:]
            let name = p["name"] as? String ?? ""
            let args = p["arguments"] as? [String: Any] ?? [:]
            let (text, summary) = await call(name, args)
            await record(tool: name, query: (args["query"] ?? args["path"] ?? args["name"]) as? String ?? "", result: summary)
            return ok(["content": [["type": "text", "text": text]]])
        default: return err(-32601, "unknown method \(method)")
        }
    }

    private func call(_ name: String, _ a: [String: Any]) async -> (String, String) {
        switch name {
        case "search_notes":
            let q = a["query"] as? String ?? ""
            let notes = (try? await knowledge.search(q, limit: 8)) ?? []
            if notes.isEmpty { return ("No notes match “\(q)”.", "0 notes") }
            return (notes.map { "## \($0.relativePath)\n\($0.body.prefix(400))" }.joined(separator: "\n\n"), "\(notes.count) notes · " + notes.prefix(3).map(\.relativePath).joined(separator: ", "))
        case "read_note":
            let path = a["path"] as? String ?? ""
            guard let n = try? await knowledge.note(at: path) else { return ("No note at \(path).", "not found") }
            return (n.body, "1 note · \(path)")
        case "who_is":
            let name = a["name"] as? String ?? ""
            let notes = (try? await knowledge.search(name, limit: 4)) ?? []
            let person = notes.first { $0.relativePath.hasPrefix("People/") } ?? notes.first
            let loops = await openLoops().filter { $0.person.lowercased().contains(name.lowercased().split(separator: " ").first.map(String.init) ?? name.lowercased()) }
            var out = person.map { "## \($0.relativePath)\n\($0.body)" } ?? "No note about \(name) yet."
            if !loops.isEmpty { out += "\n\n## Open promises\n" + loops.map(Self.loopLine).joined(separator: "\n") }
            return (out, (person.map { "1 note · \($0.relativePath)" } ?? "0 notes") + (loops.isEmpty ? "" : " · \(loops.count) loops"))
        case "open_loops":
            let loops = await openLoops()
            return (loops.isEmpty ? "No open loops." : loops.map(Self.loopLine).joined(separator: "\n"), "\(loops.count) loops")
        case "recent_cards":
            guard let s = try? await store.value(SettingKey.cards), let d = s.data(using: .utf8), let cards = try? JSONDecoder().decode([Card].self, from: d) else { return ("No cards.", "0 cards") }
            let recent = cards.filter { $0.state == .ready || $0.state == .snoozed }
            return (recent.isEmpty ? "No cards waiting." : recent.map { "- \($0.title) (\($0.state.rawValue)) — \($0.why)" }.joined(separator: "\n"), "\(recent.count) cards")
        default: return ("Unknown tool \(name).", "unknown tool")
        }
    }

    private func openLoops() async -> [Loop] {
        guard let s = try? await store.value(SettingKey.loops), let d = s.data(using: .utf8), let ls = try? JSONDecoder().decode([Loop].self, from: d) else { return [] }
        return ls.filter { $0.status == .open }
    }
    static func loopLine(_ l: Loop) -> String { "- \(l.direction == .mine ? "The user → \(l.person)" : "\(l.person) → the user"): \(l.what) · said \(l.sourceLabel)\(l.due.map { " · due \($0)" } ?? "")" }

    /// Newest first, capped at 500, in the app's key/value store so the Settings screen can show it.
    private func record(tool: String, query: String, result: String) async {
        var asks: [MCPAsk] = []
        if let s = try? await store.value(SettingKey.mcpLog), let d = s.data(using: .utf8) { asks = (try? JSONDecoder().decode([MCPAsk].self, from: d)) ?? [] }
        asks.insert(MCPAsk(at: Date(), client: client, tool: tool, query: query, result: result), at: 0)
        if asks.count > 500 { asks = Array(asks.prefix(500)) }
        if let d = try? JSONEncoder().encode(asks) { try? await store.setValue(SettingKey.mcpLog, String(data: d, encoding: .utf8)) }
        log.info("\(client) · \(tool) “\(query)” → \(result)")
    }

    /// The config line an MCP app needs, and where the common ones keep it.
    public static func configSnippet(executable: String, client: String) -> String {
        "{\"mcpServers\":{\"brownie\":{\"command\":\"\(executable)\",\"args\":[\"mcp\",\"--client\",\"\(client)\"]}}}"
    }
    public static func configFile(for client: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch client {
        case "Claude Desktop": return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case "Cursor": return home.appendingPathComponent(".cursor/mcp.json")
        default: return nil
        }
    }
    /// Merges Brownie into an app's MCP config without touching anything else in it.
    public static func install(into file: URL, executable: String, client: String) throws {
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { root = j }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["brownie"] = ["command": executable, "args": ["mcp", "--client", client]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    public static func isInstalled(in file: URL) -> Bool {
        guard let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["mcpServers"] as? [String: Any] else { return false }
        return s["brownie"] != nil
    }
}
