import Foundation

/// The user's word on one note: right, or not right and why. The note builder reads these before it writes at night,
/// the way the judge reads a card's thumbs-down — so the notes get better for this person without a model update.
/// `contentHash` is the hash of the body that was rated, so the evidence export can tell that body from a later rewrite.
public struct NoteFeedback: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case good, notRight
        /// The words on the screen.
        public var label: String { self == .good ? "good" : "not right" }
    }
    public let path: String
    public let title: String
    public let contentHash: String
    public let verdict: Verdict
    /// What was wrong, in the user's words; nil for a note called right, or a "not right" with nothing typed.
    public let reason: String?
    public let at: Date
    public init(path: String, title: String, contentHash: String, verdict: Verdict, reason: String? = nil, at: Date) {
        let words = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = path; self.title = title; self.contentHash = contentHash; self.verdict = verdict
        self.reason = (words?.isEmpty ?? true) ? nil : words; self.at = at
    }
}

/// Every rating, oldest first, kept under `SettingKey.noteFeedback` as a plain JSON array. One verdict per note per day:
/// a second word on the same note the same day replaces the first. Ratings older than 90 days fall away as new ones
/// arrive, and the newest 200 are all that is kept.
public struct NoteFeedbackList: Sendable, Equatable {
    public static let horizon: TimeInterval = 90 * 86400
    public static let cap = 200
    public private(set) var entries: [NoteFeedback]
    public init(_ entries: [NoteFeedback] = []) { self.entries = entries.sorted { $0.at < $1.at } }

    /// `now` judges the horizon; `calendar` says which day a rating falls on.
    public mutating func add(_ fb: NoteFeedback, now: Date, calendar: Calendar = .current) {
        entries.removeAll { $0.path == fb.path && calendar.isDate($0.at, inSameDayAs: fb.at) }
        entries.append(fb)
        entries.removeAll { now.timeIntervalSince($0.at) >= Self.horizon }
        entries.sort { $0.at < $1.at }
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
    }
    /// The newest word on a note, if any.
    public func latest(for path: String) -> NoteFeedback? { entries.last { $0.path == path } }
    /// Every rating made in the last `window` before `now`, newest first.
    public func recent(within window: TimeInterval, now: Date) -> [NoteFeedback] { entries.filter { now.timeIntervalSince($0.at) < window }.sorted { $0.at > $1.at } }

    public static func decode(_ json: String?) -> NoteFeedbackList {
        guard let j = json, let d = j.data(using: .utf8), let all = try? JSONDecoder().decode([NoteFeedback].self, from: d) else { return NoteFeedbackList() }
        return NoteFeedbackList(all)
    }
    public var json: String { String(data: (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
}
