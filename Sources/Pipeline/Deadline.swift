import Foundation
import Domain
import Support

/// A bound on how long the run waits for a piece of work that may never come back — a network call with no
/// timeout of its own, a Keychain read waiting for a click at 3 AM. The work runs unstructured, so an answer that
/// never comes does not hold the run: the deadline wins the race and the run moves on, the work left to finish or
/// hang on its own. What it writes late (a cursor, a summary) lands in the store for the next night to use.
public enum Deadline {
    public struct Passed: Error, Equatable { public let seconds: TimeInterval }

    public static func run<T: Sendable>(seconds: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }, work: @escaping @Sendable () async throws -> T) async throws -> T {
        let job = Task { try await work() }
        let timer = Task { try await sleep(seconds); return }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                let once = Once()
                Task { do { let v = try await job.value; if once.claim() { timer.cancel(); c.resume(returning: v) } } catch { if once.claim() { timer.cancel(); c.resume(throwing: error) } } }
                Task { do { try await timer.value; if once.claim() { job.cancel(); c.resume(throwing: Passed(seconds: seconds)) } } catch {} }
            }
        } onCancel: { job.cancel(); timer.cancel() }
    }

    /// The first of two racers to claim the continuation resumes it; the other finds it taken.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var taken = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
    }
}
