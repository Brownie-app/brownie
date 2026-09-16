import Foundation

/// The one gate every date passes before it can shape a note, a loop or a calendar event. Sources hand
/// over what their databases hold, and a database holds the odd row stamped in 2033 or 1904; the brain
/// writes a due date as free text and sometimes invents a year. Without a gate a single such date becomes
/// the newest thing Brownie knows, a loop due in seven years, or an event nobody meant. Pure functions
/// with an explicit `now`, so every rule is testable against a fixed day.
public enum DateSanity {
    static let day: TimeInterval = 86400
    static let year: TimeInterval = 365.25 * 86400

    /// When something happened: a message, a file, a recording. A day of clock skew ahead is tolerated;
    /// anything further ahead, or more than 15 years back, is not a date Brownie will believe.
    public static func item(_ d: Date?, now: Date) -> Date? {
        guard let d, d <= now.addingTimeInterval(day), d >= now.addingTimeInterval(-15 * year) else { return nil }
        return d
    }

    /// When something is due: a promise, a plan, an event. A year overdue is still a real deadline; two
    /// years ahead is the far edge of anything people actually agree to.
    public static func due(_ d: Date?, now: Date) -> Date? {
        guard let d, d >= now.addingTimeInterval(-year), d <= now.addingTimeInterval(2 * year) else { return nil }
        return d
    }

    /// A bare year, as the brain or a file name might state one: believable from 1990 up to two years out.
    public static func year(_ y: Int, now: Date, calendar: Calendar = .current) -> Bool {
        (1990...(calendar.component(.year, from: now) + 2)).contains(y)
    }
}
