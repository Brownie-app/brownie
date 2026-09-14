import Foundation
import UserNotifications
import Domain
import AppKit

/// Notifications, guarded: UNUserNotificationCenter needs a real bundle. In the bare SwiftPM
/// binary we log instead of crashing.
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }
    private static let delegate = NotificationDelegate()

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Banners while Brownie is frontmost, and actions that deep-link: Show me → For You / the card,
    /// Run now → a run, Stop → Hands.
    @MainActor static func install(model: AppModel) {
        guard available else { return }
        delegate.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let cards = UNNotificationCategory(identifier: "cards", actions: [UNNotificationAction(identifier: "show", title: "Show me", options: [.foreground]), UNNotificationAction(identifier: "later", title: "Later")], intentIdentifiers: [])
        let skipped = UNNotificationCategory(identifier: "skipped", actions: [UNNotificationAction(identifier: "run", title: "Run now", options: [.foreground]), UNNotificationAction(identifier: "ok", title: "OK")], intentIdentifiers: [])
        let paused = UNNotificationCategory(identifier: "paused", actions: [UNNotificationAction(identifier: "show", title: "Show", options: [.foreground]), UNNotificationAction(identifier: "stop", title: "Stop")], intentIdentifiers: [])
        let brief = UNNotificationCategory(identifier: "brief", actions: [UNNotificationAction(identifier: "show", title: "Open the brief", options: [.foreground]), UNNotificationAction(identifier: "later", title: "Later")], intentIdentifiers: [])
        center.setNotificationCategories([cards, skipped, paused, brief])
    }

    static func post(_ title: String, body: String, id: String = UUID().uuidString, respectQuietHours: Bool = false, category: String? = nil, cardID: String? = nil, briefID: String? = nil) {
        guard available else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        if let category { c.categoryIdentifier = category }
        if let cardID { c.userInfo = ["card": cardID] }
        if let briefID { c.userInfo = ["brief": briefID] }
        var trigger: UNNotificationTrigger? = nil
        if respectQuietHours {
            // Never before 7 AM: a run that ends at 3:41 AM notifies at 7:30.
            let hour = Calendar.current.component(.hour, from: Date())
            if hour < 7 {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date()); comps.hour = 7; comps.minute = 30
                trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }

    static func runFinished(_ outcome: RunOutcome, stats: RunStats) {
        switch outcome {
        case .ran(let n) where n > 0: post("\(n) thing\(n == 1 ? "" : "s") for this morning", body: "Prepared on your Mac. Nothing has been sent.", id: "cards.ready", respectQuietHours: true, category: "cards")
        case .ran: post("Done reading", body: "\(stats.read) new items · \(stats.kept) kept · \(stats.sensitive) sensitive erased.", category: "cards")
        case .skippedOnBattery: post("Last night didn't run", body: "Your Mac was on battery. Plug in tonight, or run now.", id: "run.skipped", respectQuietHours: true, category: "skipped")
        case .failedBrain(.usageLimit): post("Brownie got half-way", body: "Your brain's usage limit was hit. It will retry.")
        case .failedBrain(.unauthorized): post("Brownie needs a key", body: "The brain rejected the key. Check Settings → Brain.")
        default: break
        }
    }

    static func paused(_ title: String, body: String) { post(title, body: body, id: "hands.paused", category: "paused") }

    /// Ten minutes before: the first line of the brief, and a button to the rest.
    static func brief(_ b: Brief) {
        let mins = max(1, Int(b.startsAt.timeIntervalSinceNow / 60))
        let first = b.text.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? "Your brief is ready."
        post("\(b.title) in \(mins) minute\(mins == 1 ? "" : "s")", body: String(first.prefix(160)), id: "brief.\(b.id)", category: "brief", briefID: b.id)
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let action = r.actionIdentifier, info = r.notification.request.content.userInfo
        await MainActor.run {
            guard let m = model else { return }
            NSApp.activate(ignoringOtherApps: true)
            switch action {
            case "run": m.analyzeNow()
            case "stop": Task { await m.hands?.stop() }
            case "later", "ok": break
            default:   // "show" or the notification body itself
                m.overlay = .none; m.screen = .forYou
                if let id = info["card"] as? String { m.overlay = .card(id) }
                if let id = info["brief"] as? String { m.overlay = .brief(id) }
            }
        }
    }
}
