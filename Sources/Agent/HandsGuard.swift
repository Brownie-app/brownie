import Foundation

/// The rails that keep Hands on the task: no app-switching shortcuts, no wandering into apps the goal never named,
/// no repeating the same step until the turn cap. Pure, so the rules are tested.
public enum HandsGuard {
    /// Shortcuts that change context instead of acting in the app — Hands must use `open_app` instead.
    public static let contextSwitchKeys: Set<String> = ["cmd+space", "cmd+tab", "cmd+shift+tab", "cmd+q", "cmd+opt+esc", "cmd+alt+esc", "cmd+h", "cmd+opt+h", "cmd+alt+h", "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right", "cmd+`", "cmd+shift+`", "cmd+w", "cmd+shift+w", "cmd+opt+w", "cmd+alt+w", "cmd+m"]

    /// Apps that can change the Mac itself. Off limits unless the goal names them.
    public static let riskyApps = ["terminal", "iterm", "iterm2", "script editor", "automator", "system settings", "system preferences", "keychain access", "console", "activity monitor", "disk utility", "finder", "installer", "shortcuts"]

    public static func normalise(_ combo: String) -> String {
        combo.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "command", with: "cmd").replacingOccurrences(of: "option", with: "opt").replacingOccurrences(of: "control", with: "ctrl").replacingOccurrences(of: "escape", with: "esc")
    }
    public static func isContextSwitch(_ combo: String) -> Bool { contextSwitchKeys.contains(normalise(combo)) }

    public static func isOffLimits(app: String, goal: String) -> Bool {
        let a = app.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard riskyApps.contains(where: { a == $0 || a.hasPrefix($0) }) else { return false }
        return !goal.lowercased().contains(a)
    }

    /// Notices the same call made three times in a row (allowing `screen`/`wait`/`look` in between) — the sign of a loop.
    public struct RepeatGuard: Sendable {
        public static let lookers: Set<String> = ["screen", "look", "wait", "list_apps"]
        private var recent: [String] = []
        public var limit = 3
        public init() {}
        /// Returns true when this call is the `limit`-th identical action in a row.
        public mutating func record(tool: String, args: String) -> Bool {
            if Self.lookers.contains(tool) { return false }
            let key = tool + " " + args
            recent.append(key); if recent.count > limit { recent.removeFirst() }
            return recent.count == limit && recent.allSatisfy { $0 == key }
        }
    }
}
