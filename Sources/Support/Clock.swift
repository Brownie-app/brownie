import Foundation

/// Injectable clock so scheduling and "today is" prompts are testable.
public protocol Clock: Sendable {
    func now() -> Date
    var timeZone: TimeZone { get }
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public var timeZone: TimeZone { .current }
}

public struct FixedClock: Clock {
    public var date: Date
    public var timeZone: TimeZone
    public init(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Kolkata")!) {
        self.date = date; self.timeZone = timeZone
    }
    public func now() -> Date { date }
}
