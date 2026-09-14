import XCTest
@testable import Brain
import Domain

/// "What left your Mac" must see every request, with its purpose, and never lose the size.
final class SendLoggerTests: XCTestCase {
    struct Echo: Brain {
        let descriptor = BrainDescriptor(id: "echo", name: "Echo", capabilities: [.json], costLine: "")
        func validate() async throws {}
        func complete(_ r: BrainRequest) async throws -> BrainResult { BrainResult(text: "ok:" + r.input.prefix(5), usage: Usage(inputTokens: 1, outputTokens: 2)) }
    }
    actor Sink { var rows: [(String, String, Int, String, String)] = []; var results: [(Int64, String)] = []
        func add(_ p: String, _ m: String, _ b: Int, _ d: String, _ pl: String) -> Int64 { rows.append((p, m, b, d, pl)); return Int64(rows.count) }
        func done(_ id: Int64, _ back: String) { results.append((id, back)) } }

    func testCompleteIsLoggedWithPurposeAndBytes() async throws {
        let sink = Sink()
        let logger = SendLogger(sink: { p, m, b, d, pl in await sink.add(p, m, b, d, pl) }, result: { id, back in await sink.done(id, back) })
        let brain = SendLogger.wrap(Echo(), model: "m1", logger: logger)
        logger.setPurpose("Judge what matters", detail: "3 summaries")
        let r = try await brain.complete(BrainRequest(system: "sys", input: "hello world"))
        XCTAssertEqual(r.text, "ok:hello")
        let rows = await sink.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, "Judge what matters"); XCTAssertEqual(rows[0].1, "m1"); XCTAssertEqual(rows[0].3, "3 summaries")
        XCTAssertEqual(rows[0].2, "SYSTEM:\nsys\n\nINPUT:\nhello world".utf8.count, "bytes are the exact payload")
        let results = await sink.results
        XCTAssertEqual(results.first?.0, 1); XCTAssertTrue(results.first?.1.contains("tokens") ?? false)
    }
    func testPayloadIsCappedButSizeIsHonest() async throws {
        let sink = Sink()
        let logger = SendLogger(sink: { p, m, b, d, pl in await sink.add(p, m, b, d, pl) }, result: { _, _ in })
        let brain = SendLogger.wrap(Echo(), model: "m", logger: logger)
        let big = String(repeating: "y", count: SendLogger.payloadCap + 5000)
        _ = try await brain.complete(BrainRequest(system: "", input: big))
        let row = await sink.rows[0]
        XCTAssertGreaterThan(row.2, SendLogger.payloadCap, "reported bytes are the real size")
        XCTAssertLessThan(row.4.utf8.count, SendLogger.payloadCap + 200, "stored text is capped")
        XCTAssertTrue(row.4.contains("more bytes"))
    }
    func testNonAgenticBrainStaysNonAgentic() {
        XCTAssertFalse(SendLogger.wrap(Echo(), model: "m", logger: SendLogger(sink: { _, _, _, _, _ in nil }, result: { _, _ in })).isAgentic)
    }
    func testFormattedBytes() {
        XCTAssertEqual(512.formattedBytes, "512 B"); XCTAssertEqual(14_540.formattedBytes, "14.2 KB"); XCTAssertEqual(3_000_000.formattedBytes, "2.9 MB")
    }
}
