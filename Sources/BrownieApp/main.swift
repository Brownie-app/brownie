import Foundation
import SwiftUI
import Scheduling
import Knowledge
import Platform
import Support

// The same binary doubles as the root wake helper when launchd starts it with --wake-helper.
if CommandLine.arguments.contains("--wake-helper") { WakeHelper.runDaemon() }

// …and as an MCP server when another AI app starts it with `mcp` (stdin/stdout, no port, no network).
if CommandLine.arguments.dropFirst().first == "mcp" {
    let ci = CommandLine.arguments.firstIndex(of: "--client").map { $0 + 1 }
    let client = ci.flatMap { $0 < CommandLine.arguments.count ? CommandLine.arguments[$0] : nil } ?? "an app"
    let store = try! SQLiteRunStore(path: Paths.store.path)
    let kb = try! FileKnowledgeStore(root: Paths.knowledgeBase, indexPath: Paths.applicationSupport.appendingPathComponent("knowledge-index.sqlite").path)
    let sem = DispatchSemaphore(value: 0)
    Task.detached { await MCPServer(knowledge: kb, store: store, client: client).serve(); sem.signal() }
    sem.wait()
    exit(0)
}

// Two Brownies would fight over the store, the vault and TDLib's database: the second one hands over and leaves.
if !SingleInstance.claim() { exit(0) }

BrownieApp.main()
