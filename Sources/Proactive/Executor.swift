import Foundation
import AppKit
import Domain
import Support

/// Part 3: the only write-capable step, on a user tap. Channel recipes stop before the
/// irreversible step; `computerUse` is delegated to Hands (injected).
public struct RecipeExecutor: CardExecutor {
    public typealias HandsRunner = @Sendable (String, @escaping @Sendable (FireEvent) -> Void) async throws -> FireOutcome
    private let hands: HandsRunner?
    private let knowledgeRoot: URL
    private let log = Log("executor")

    public init(knowledgeRoot: URL, hands: HandsRunner? = nil) { self.knowledgeRoot = knowledgeRoot; self.hands = hands }

    public func fire(_ card: Card, onEvent: @escaping @Sendable (FireEvent) -> Void) async throws -> FireOutcome {
        log.info("fire \(card.recipe.channelName)")
        switch card.recipe {
        case .imessage(let to, let body, _):
            onEvent(.step("Opening Messages to \(to)", done: false))
            try await Self.appleScript("""
            tell application "Messages"
              activate
            end tell
            """)
            onEvent(.step("Opening Messages to \(to)", done: true))
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(body, forType: .string)
            onEvent(.step("Draft copied to the clipboard — paste it into the chat with \(to)", done: true))
            onEvent(.pausedForUser("Press Send in Messages when you're ready")); return .pausedAtUserStep
        case .whatsapp(let chat, let body, let phone):
            onEvent(.step("Opening the WhatsApp chat with \(chat)", done: false))
            let q = body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let digits = (phone ?? "").filter(\.isNumber)
            if let url = URL(string: digits.isEmpty ? "whatsapp://send?text=\(q)" : "whatsapp://send?phone=\(digits)&text=\(q)") { NSWorkspace.shared.open(url) }
            onEvent(.step("Opening the WhatsApp chat with \(chat)", done: true))
            onEvent(.step(digits.isEmpty ? "Pick the chat with \(chat); the draft is in the message field" : "The draft is in the message field", done: true))
            onEvent(.pausedForUser("Press Send in WhatsApp when you're ready")); return .pausedAtUserStep
        case .mail(let to, let subject, let body, _):
            onEvent(.step("Composing an email to \(to)", done: false))
            var c = URLComponents(string: "mailto:\(to)")!
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = c.url { NSWorkspace.shared.open(url) }
            onEvent(.step("Composing an email to \(to)", done: true))
            onEvent(.pausedForUser("Press Send in Mail when you're ready")); return .pausedAtUserStep
        case .calendar(let title, let startISO, let endISO, let notes):
            let (start, end) = Self.eventTimes(startISO: startISO, endISO: endISO)
            let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
            onEvent(.step("Creating “\(title)” on \(f.string(from: start))", done: false))
            // Offsets from now avoid AppleScript's locale-dependent date literals.
            let s = Int(start.timeIntervalSinceNow), d = Int(end.timeIntervalSince(start))
            try await Self.appleScript("""
            tell application "Calendar"
              activate
              set s to (current date) + (\(s))
              tell calendar 1
                set e to make new event with properties {summary:"\(Self.esc(title))", start date:s, end date:(s + \(d)), description:"\(Self.esc(notes))"}
                show e
              end tell
            end tell
            """)
            onEvent(.step("Event is in Calendar at \(f.string(from: start)) — change the time if you like, then it's saved", done: true))
            onEvent(.pausedForUser("The event is in Calendar; adjust the time or leave it")); return .pausedAtUserStep
        case .note(let rel, let body):
            onEvent(.step("Writing \(rel)", done: false))
            let url = knowledgeRoot.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
            onEvent(.step("Writing \(rel)", done: true)); onEvent(.finished(.done)); return .done
        case .browser(let s):
            onEvent(.step("Opening \(s)", done: false))
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            onEvent(.step("Opening \(s)", done: true)); onEvent(.finished(.done)); return .done
        case .computerUse(let goal):
            guard let hands else { onEvent(.finished(.couldNot)); return .couldNot }
            return try await hands(goal, onEvent)
        }
    }

    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func appleScript(_ source: String) async throws {
        try await MainActor.run {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { throw NSError(domain: "AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(err)"]) }
        }
    }
}

extension RecipeExecutor {
    /// The event's times from the card, or a sensible proposal when none was agreed: the next weekday at 10:00, for an hour.
    /// A start the brain put years away is treated as no start at all, so the proposal wins over a 2033 event.
    static func eventTimes(startISO: String, endISO: String, now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let iso = ISO8601DateFormatter(); let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let local = DateFormatter(); local.calendar = calendar; local.timeZone = calendar.timeZone; local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        func parse(_ t: String) -> Date? { let t = t.trimmingCharacters(in: .whitespaces); return iso.date(from: t) ?? isoFrac.date(from: t) ?? local.date(from: String(t.prefix(16))) }
        if let s = DateSanity.due(parse(startISO), now: now) {
            let e = parse(endISO).flatMap { $0 > s ? $0 : nil } ?? s.addingTimeInterval(3600)
            return (s, e)
        }
        var day = calendar.startOfDay(for: now)
        repeat { day = calendar.date(byAdding: .day, value: 1, to: day)! } while calendar.isDateInWeekend(day)
        let s = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        return (s, s.addingTimeInterval(3600))
    }
}
