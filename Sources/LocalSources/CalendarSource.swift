import Foundation
import EventKit
import Domain
import Support

/// Apple Calendar via EventKit (local API, no sign-in). Reads the last 7 days + next 24 hours.
/// Also renders the plain-text calendar block the judge reads for timing.
public struct CalendarSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "calendar", name: "Calendar", detail: "Last 7 days and the next 24 hours · for timing",
        door: .localAPI, permissions: [.calendar])

    private let log = Log("source.calendar")
    public init() {}

    static let store = EKEventStore()

    public static var isAuthorized: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .fullAccess
    }

    /// Triggers the macOS prompt. Safe to call repeatedly.
    public static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func availability() async -> Availability { Self.isAuthorized ? .available : .needsPermission(.calendar) }

    static func window(now: Date = Date()) -> (Date, Date) { (now.addingTimeInterval(-7 * 86400), now.addingTimeInterval(24 * 3600)) }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        guard Self.isAuthorized else { throw SourceError.notAvailable(.needsPermission(.calendar)) }
        let (from, to) = Self.window()
        let events = Self.store.events(matching: Self.store.predicateForEvents(withStart: from, end: to, calendars: nil))
        var byCal: [String: [EKEvent]] = [:]
        for e in events where !e.isAllDay || e.hasNotes || e.hasAttendees { byCal[e.calendar.title, default: []].append(e) }
        return byCal.map { name, evs in
            let id = BucketID("calendar:\(name)")
            let items = evs.compactMap { e -> Candidate? in
                guard let start = e.startDate, let eid = e.eventIdentifier else { return nil }
                return Candidate(source: Self.descriptor.id, bucket: id, key: ItemKey(order: start.timeIntervalSince1970, tiebreak: eid), kind: .event,
                                 id: eid, itemDate: start, metadata: ["name": e.title ?? "Event", "displayPath": "Calendar/\(name)/\(e.title ?? "Event")"])
            }.sorted { $0.key > $1.key }
            return Bucket(id: id, name: name, items: items)
        }
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        guard let e = Self.store.event(withIdentifier: c.id) else { throw SourceError.itemGone }
        return Artifact(candidate: c, text: Self.render(e, detailed: true))
    }

    static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"; return f }()

    static func render(_ e: EKEvent, detailed: Bool) -> String {
        var s = "\(df.string(from: e.startDate))–\(DateFormatter.localizedString(from: e.endDate, dateStyle: .none, timeStyle: .short)) · \(e.title ?? "Event")"
        if let loc = e.location, !loc.isEmpty { s += " · \(loc)" }
        if let att = e.attendees, !att.isEmpty { s += " · with \(att.compactMap(\.name).prefix(6).joined(separator: ", "))" }
        if detailed, let n = e.notes, !n.isEmpty { s += "\nNotes: \(n.prefix(1500))" }
        return s
    }

    /// The judge's calendar block: every event in the window, one line each.
    public static func judgeContext() -> String? {
        guard isAuthorized else { return nil }
        let (from, to) = window()
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return nil }
        return events.prefix(120).map { render($0, detailed: false) }.joined(separator: "\n")
    }
}
