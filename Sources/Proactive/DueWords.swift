import Foundation
import Domain

/// The date behind a due said in words, worked out from the run's clock when the judge gave no `dueISO` (or the
/// words the brain wrote could not be a date it worked out): "September6", "Sept 6", "6th Sept", "by the 30th",
/// "Tuesday", "this week", "next week", "end of month". The words stay on the loop as said; this only adds the
/// date, at 9 AM local like every due, so "due Tuesday" sorts before the day is over. Nothing that parses is nothing:
/// the loop keeps its words and no date, and nobody is nudged on a guess.
public enum DueWords {
    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]   // Calendar's weekday order, 1 = Sunday
    static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple of": 2]

    public static func date(_ words: String?, now: Date, timeZone: TimeZone) -> Date? {
        guard let words else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        func at9(_ d: Date?) -> Date? {
            guard let d else { return nil }
            var c = cal.dateComponents([.year, .month, .day], from: d); c.hour = 9
            return DateSanity.due(cal.date(from: c), now: now)
        }
        func days(_ n: Int, from d: Date = today) -> Date? { cal.date(byAdding: .day, value: n, to: d) }
        /// The coming `weekday` (1 = Sunday): today when `orToday` and today is that day, else the next one.
        func coming(_ weekday: Int, orToday: Bool) -> Date? {
            let todayWeekday = cal.component(.weekday, from: today)
            var ahead = (weekday - todayWeekday + 7) % 7
            if ahead == 0, !orToday { ahead = 7 }
            return days(ahead)
        }
        func endOfMonth(_ monthsAhead: Int) -> Date? {
            guard let first = cal.date(from: cal.dateComponents([.year, .month], from: today)), let next = cal.date(byAdding: .month, value: monthsAhead + 1, to: first) else { return nil }
            return days(-1, from: next)
        }
        /// A month and a day: this year, unless that is more than 90 days gone — then it means next year.
        func monthDay(_ month: Int, _ day: Int, year: Int?) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            let thisYear = cal.component(.year, from: today)
            if let year { return cal.date(from: DateComponents(year: year, month: month, day: day)) }
            guard let d = cal.date(from: DateComponents(year: thisYear, month: month, day: day)), let cutoff = days(-90) else { return nil }
            return d < cutoff ? cal.date(from: DateComponents(year: thisYear + 1, month: month, day: day)) : d
        }
        func month(_ token: String) -> Int? {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard t.count >= 3 else { return nil }
            return monthNames.firstIndex { $0.hasPrefix(t) || (t == "sept" && $0 == "september") }.map { $0 + 1 }
        }

        var s = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        for lead in ["due by ", "due on ", "due ", "by ", "before ", "on ", "until ", "till ", "for ", "this coming ", "coming "] where s.hasPrefix(lead) { s = String(s.dropFirst(lead.count)); break }
        for tail in [" morning", " afternoon", " evening", " night", " eod", " at the latest", " latest", " or so"] where s.hasSuffix(tail) { s = String(s.dropLast(tail.count)); break }
        s = s.replacingOccurrences(of: "  ", with: " ")
        guard !s.isEmpty else { return nil }

        // 2026-09-06, whatever came before it
        if let m = s.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let p = s[m].split(separator: "-").compactMap { Int($0) }
            return at9(cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])))
        }
        switch s {
        case "today", "tonight", "eod", "end of day", "end of the day", "now", "asap", "right away": return at9(today)
        case "tomorrow", "tmrw", "tmr": return at9(days(1))
        case "day after tomorrow", "the day after tomorrow": return at9(days(2))
        case "this week", "end of week", "end of the week", "eow", "by end of week", "this weekend", "the weekend", "weekend", "over the weekend": return at9(coming(1, orToday: true))
        case "next week", "end of next week", "next weekend": return at9(coming(1, orToday: true).flatMap { days(7, from: $0) })
        case "end of month", "end of the month", "eom", "month end", "month-end", "this month": return at9(endOfMonth(0))
        case "end of next month", "next month": return at9(endOfMonth(1))
        default: break
        }
        // "in 2 days", "in a week", "in two weeks", "within 3 days"
        if let m = try? NSRegularExpression(pattern: #"^(?:in|within) (\d+|[a-z]+(?: of)?) (day|days|week|weeks|month|months)$"#).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let nr = Range(m.range(at: 1), in: s), let ur = Range(m.range(at: 2), in: s) {
            let nWord = String(s[nr]), unit = String(s[ur])
            guard let n = Int(nWord) ?? numberWords[nWord] else { return nil }
            if unit.hasPrefix("day") { return at9(days(n)) }
            if unit.hasPrefix("week") { return at9(days(7 * n)) }
            return at9(cal.date(byAdding: .month, value: n, to: today))
        }
        // a weekday, plain ("Tuesday", "tue") or "next Tuesday"
        let next = s.hasPrefix("next "), plainDay = next || s.hasPrefix("this ") ? String(s.dropFirst(5)) : s
        if plainDay.count >= 3, let i = dayNames.firstIndex(where: { $0.hasPrefix(plainDay) }) {
            return at9(coming(i + 1, orToday: !next))
        }
        // "the 30th", "30th", "30"
        if let m = try? NSRegularExpression(pattern: #"^(?:the )?(\d{1,2})(?:st|nd|rd|th)?$"#).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s), let day = Int(s[r]) {
            let thisMonth = cal.component(.month, from: today), thisYear = cal.component(.year, from: today), todayDay = cal.component(.day, from: today)
            if day >= todayDay, let d = cal.date(from: DateComponents(year: thisYear, month: thisMonth, day: day)) { return at9(d) }
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: today) else { return nil }
            let c = cal.dateComponents([.year, .month], from: nextMonth)
            return at9(cal.date(from: DateComponents(year: c.year, month: c.month, day: day)))
        }
        // "September6", "Sept 6", "Sep 6th", "6th Sept", "6 September", "6th of September", "September 6, 2026", "6 Sep 2026"
        let dayFirst = #"^(\d{1,2})(?:st|nd|rd|th)?(?: of)?[ .-]*([a-z]{3,9})\.?(?:,? ?(\d{4}))?$"#
        let monthFirst = #"^([a-z]{3,9})\.?[ .-]*(\d{1,2})(?:st|nd|rd|th)?(?:,? ?(\d{4}))?$"#
        for (pattern, dayGroup, monthGroup) in [(dayFirst, 1, 2), (monthFirst, 2, 1)] {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let dr = Range(m.range(at: dayGroup), in: s), let mr = Range(m.range(at: monthGroup), in: s), let day = Int(s[dr]), let mo = month(String(s[mr])) else { continue }
            let year = Range(m.range(at: 3), in: s).flatMap { Int(s[$0]) }
            return at9(monthDay(mo, day, year: year))
        }
        return nil
    }
}
