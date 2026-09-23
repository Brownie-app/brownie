import AppKit
import Support

/// One Brownie at a time. Two copies of the app — the one in Applications and the one still mounted from the DMG, or
/// an old build that outlived a relaunch — share the store, the vault and TDLib's database, and TDLib in particular
/// dies when a second process opens the same directory (nine crashes in an hour on this Mac before this existed).
/// The second copy brings the first to the front and leaves, which is also what a person expects from an app they
/// opened twice.
enum SingleInstance {
    /// True when this process is the only Brownie and may go on. False when another already holds the place, in which
    /// case it has been brought forward and this one should quit at once.
    static func claim(log: Log = Log("app")) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard let first = others.min(by: { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }) else { return true }
        log.warn("another Brownie is already running (pid \(first.processIdentifier), \(first.bundleURL?.path ?? "?")) — bringing it forward and leaving")
        first.activate(options: [.activateAllWindows])
        return false
    }
}
