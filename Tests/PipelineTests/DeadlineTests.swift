import Testing
import Foundation
@testable import Pipeline

@Suite struct DeadlineTests {
    @Test func workThatFinishesInTimeReturnsItsValue() async throws {
        let v = try await Deadline.run(seconds: 5, sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) }, work: { 42 })
        #expect(v == 42)
    }
    @Test func workThatNeverComesBackLosesToTheDeadlineAndTheRunMovesOn() async {
        // The work would take a minute; the deadline is a twentieth of a second. The bound below is generous on
        // purpose — a loaded machine can take seconds to schedule anything, and this test is about the minute that
        // is not waited for, not about the milliseconds that are.
        let work: TimeInterval = 60, started = Date()
        let cancelled = Flag()
        do {
            _ = try await Deadline.run(seconds: 0.05, sleep: { s in try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }, work: { () async throws -> Int in
                do { try await Task.sleep(nanoseconds: UInt64(work * 1e9)) } catch { cancelled.raise(); throw error }
                return 1
            })
            Issue.record("the deadline did not fire")
        } catch let p as Deadline.Passed { #expect(p.seconds == 0.05) }
        catch { Issue.record("unexpected \(error)") }
        let waited = Date().timeIntervalSince(started)
        #expect(waited < work / 4, "the run waited \(Int(waited))s of the work's \(Int(work))s instead of moving on")
        // the work is told to stop, so nothing is left running behind the run
        for _ in 0..<50 where !cancelled.raised { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(cancelled.raised, "the work was left running after the deadline passed")
    }

    /// A box two tasks can see: the work sets it when it is cancelled, the test reads it afterwards.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    @Test func anErrorFromTheWorkIsTheCallersError() async {
        struct Boom: Error {}
        do { _ = try await Deadline.run(seconds: 5, work: { () async throws -> Int in throw Boom() }); Issue.record("no throw") }
        catch is Boom {} catch { Issue.record("unexpected \(error)") }
    }
}
