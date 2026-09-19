import Testing
import Foundation
@testable import Pipeline

@Suite struct DeadlineTests {
    @Test func workThatFinishesInTimeReturnsItsValue() async throws {
        let v = try await Deadline.run(seconds: 5, sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) }, work: { 42 })
        #expect(v == 42)
    }
    @Test func workThatNeverComesBackLosesToTheDeadlineAndTheRunMovesOn() async {
        let started = Date()
        do {
            _ = try await Deadline.run(seconds: 0.05, sleep: { s in try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }, work: { () async throws -> Int in
                try await Task.sleep(nanoseconds: 60_000_000_000); return 1
            })
            Issue.record("the deadline did not fire")
        } catch let p as Deadline.Passed { #expect(p.seconds == 0.05) }
        catch { Issue.record("unexpected \(error)") }
        #expect(Date().timeIntervalSince(started) < 2, "the run did not wait for the work")
    }
    @Test func anErrorFromTheWorkIsTheCallersError() async {
        struct Boom: Error {}
        do { _ = try await Deadline.run(seconds: 5, work: { () async throws -> Int in throw Boom() }); Issue.record("no throw") }
        catch is Boom {} catch { Issue.record("unexpected \(error)") }
    }
}
