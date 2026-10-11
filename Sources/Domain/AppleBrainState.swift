import Foundation

/// Whether this Mac can lend Brownie Apple's on-device model, and what to say when it cannot.
///
/// Deliberately knows nothing about `FoundationModels`. That framework exists only on macOS 26, behind
/// `@available`, and cannot be referenced from a test running anywhere else — so everything that decides what
/// a person *sees* lives here, in plain Swift, where it can be tested on any machine and in CI. `AppleBrain`
/// does nothing but map the SDK's answer onto one of these cases.
public enum AppleBrainState: Equatable, Sendable {
    /// Ready. The tile is selectable and a night can use it.
    case available
    /// macOS 26 is where the framework starts. Below that the option is not offered at all.
    case needsNewerMacOS
    /// The Mac could, but Apple Intelligence is switched off. This is the one the user can fix in a few seconds,
    /// and the only one worth a button.
    case notEnabled
    /// Apple is still fetching its own model. Nothing to do but wait; it resolves itself.
    case notReady
    /// This hardware will never run it. Saying so plainly is kinder than a button that leads to a pane with no
    /// switch in it.
    case notEligible

    /// Offer it as a choice at all? An option that cannot be made to work is noise in a list of six.
    public var isOffered: Bool { self != .needsNewerMacOS && self != .notEligible }
    /// Can a night actually use it right now?
    public var isUsable: Bool { self == .available }
    /// Is there something the user can do about it, here, today?
    public var isFixable: Bool { self == .notEnabled }

    /// The line under the tile. Written for someone who has not heard of any of this.
    public var line: String {
        switch self {
        case .available: return "Ready — free, no key, and nothing leaves this Mac."
        case .notEnabled: return "Apple Intelligence is turned off on this Mac. Brownie can use it as the brain — free, no key, and nothing leaves."
        case .notReady: return "Apple is still setting up its model. This becomes available when it finishes; nothing for you to do."
        case .notEligible: return "This Mac can't run Apple Intelligence, so Brownie can't borrow it."
        case .needsNewerMacOS: return "Apple Intelligence needs macOS 26 or later."
        }
    }
    /// The button beside that line, when pressing something would help.
    public var action: String? { isFixable ? "Turn it on" : nil }
    /// Where that button goes. The Apple Intelligence pane in System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?AppleIntelligence")

    /// The one line offered to someone who has just chosen the small local reader as their brain, on a Mac that
    /// has something better switched off. Said once, under the tile — never a dialog, and never repeated.
    /// Nil whenever there is nothing better to offer, so the caller cannot nag by accident.
    public var nudgeFromLocalReader: String? {
        switch self {
        case .notEnabled: return "This Mac has Apple Intelligence, which Brownie can use instead — it builds your notes, which this reader can't yet."
        case .available: return "This Mac has Apple Intelligence, which builds your notes — this reader can't yet."
        case .notReady, .notEligible, .needsNewerMacOS: return nil
        }
    }
}
