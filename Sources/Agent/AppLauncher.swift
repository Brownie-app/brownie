import AppKit

/// Opens an app by the name a person would say — "Calendar", "Chrome", "WhatsApp" — wherever macOS keeps it.
public enum AppLauncher {
    /// Everyday names that don't match the bundle's file name.
    static let aliases: [String: String] = ["chrome": "Google Chrome", "gchrome": "Google Chrome", "whatsapp desktop": "WhatsApp", "imessage": "Messages", "ical": "Calendar", "vscode": "Visual Studio Code", "vs code": "Visual Studio Code", "teams": "Microsoft Teams", "outlook": "Microsoft Outlook", "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings"]
    static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]

    /// Canonical name for matching: lower-cased, ".app" gone, alias applied.
    public static func canonical(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.lowercased().hasSuffix(".app") { n = String(n.dropLast(4)) }
        return aliases[n.lowercased()] ?? n
    }

    /// The .app on disk for a spoken name, or nil.
    public static func locate(_ name: String) -> URL? {
        let n = canonical(name)
        let fm = FileManager.default
        for f in folders {
            let u = URL(fileURLWithPath: f).appendingPathComponent(n + ".app")
            if fm.fileExists(atPath: u.path) { return u }
        }
        // case-insensitive pass over the same folders
        for f in folders {
            if let items = try? fm.contentsOfDirectory(atPath: f), let hit = items.first(where: { $0.lowercased() == n.lowercased() + ".app" }) { return URL(fileURLWithPath: f).appendingPathComponent(hit) }
        }
        if n.contains("."), let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: n) { return u }
        return nil
    }

    /// Activates the running app, or launches it. True when either happened.
    @MainActor public static func open(_ name: String) -> Bool {
        let n = canonical(name).lowercased()
        if let app = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").lowercased() == n || ($0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() ?? "") == n }) {
            app.activate(options: [.activateIgnoringOtherApps]); return true   // activate() may report false while still bringing the app up
        }
        guard let url = locate(name) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        return true
    }
}
