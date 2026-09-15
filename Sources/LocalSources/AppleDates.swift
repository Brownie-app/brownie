import Foundation

enum AppleDates {
    /// Seconds since 2001-01-01 (Core Data / WhatsApp)
    static func fromReference(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    /// iMessage stores nanoseconds since 2001 on modern macOS; older rows are seconds.
    static func fromMessagesDate(_ raw: Int64) -> Date {
        raw > 1_000_000_000_000 ? Date(timeIntervalSinceReferenceDate: Double(raw) / 1e9) : Date(timeIntervalSinceReferenceDate: Double(raw))
    }
    /// Modern Messages stores nanoseconds since the reference date.
    static func toMessagesDate(_ d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate * 1e9) }
}
