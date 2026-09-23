import Foundation

/// One question another app asked Brownie over MCP, for the "What they asked" log.
public struct MCPAsk: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public let at: Date
    public let client: String
    public let tool: String
    public let query: String
    public let result: String   // "2 notes · People/Karan, Trips/Goa October"
    public init(id: String = UUID().uuidString, at: Date, client: String, tool: String, query: String, result: String) {
        self.id = id; self.at = at; self.client = client; self.tool = tool; self.query = query; self.result = result
    }
}
