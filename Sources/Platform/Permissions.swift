import Foundation
import AppKit
import ApplicationServices
import EventKit
import Contacts
import Domain

/// Read-only probes for macOS grants. Requesting is the app's job (it opens the right pane);
/// these only answer "do we have it right now?".
public enum PermissionProbe {
    public static func status(_ p: Permission) -> Bool {
        switch p {
        case .fullDiskAccess:
            // The canonical probe: the Messages database is unreadable without FDA.
            let chat = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
            return WALSafeCopy.isReadable(chat)
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        default:
            return false
        }
    }

    /// Opens System Settings at the pane for a permission.
    public static func openSettings(for p: Permission) {
        let anchor: String
        switch p {
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .speech: anchor = "Privacy_SpeechRecognition"
        case .contacts: anchor = "Privacy_Contacts"
        case .calendar: anchor = "Privacy_Calendars"
        case .automation: anchor = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
