import Foundation
import AppKit
import Support

/// The knowledge base as an Obsidian vault: open it there, mirror it to iCloud Drive for the phone.
public enum Vault {
    private static let log = Log("vault")

    /// Where a mirror goes: iCloud Drive/Brownie. Nil when iCloud Drive is off on this Mac.
    public static var icloudFolder: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u.appendingPathComponent("Brownie")
    }

    public static var obsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    /// Obsidian's URL scheme adds a folder as a vault the first time and opens it after that.
    @MainActor public static func openInObsidian(_ root: URL) {
        guard let path = root.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "obsidian://open?path=\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// One-way mirror Mac → iCloud: copy changed Markdown, remove what no longer exists. The vault on
    /// the Mac stays the truth; edits made on the phone are not merged back (yet).
    public static func mirror(_ root: URL, to destination: URL? = nil) throws -> Int {
        guard let dest = destination ?? icloudFolder else { throw NSError(domain: "Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive is off on this Mac"]) }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        var seen = Set<String>()
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) {
            for case let src as URL in e {
                let rel = String(src.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                if rel.hasPrefix(".") || rel.contains("/.") { continue }
                let dst = dest.appendingPathComponent(rel)
                if (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { try? fm.createDirectory(at: dst, withIntermediateDirectories: true); continue }
                guard src.pathExtension == "md" else { continue }
                seen.insert(rel)
                let sm = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dm = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if sm > dm { try? fm.removeItem(at: dst); try fm.copyItem(at: src, to: dst); copied += 1 }
            }
        }
        if let e = fm.enumerator(at: dest, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "md" {
                let rel = String(u.standardizedFileURL.path.dropFirst(dest.standardizedFileURL.path.count + 1))
                if !seen.contains(rel) { try? fm.removeItem(at: u) }
            }
        }
        log.info("mirrored \(copied) changed notes to iCloud Drive")
        return copied
    }
}

// MARK: - Two-way sync

/// What one sync did, for the Settings line: "2 notes came back from your iPhone and were merged · 0 conflicts".
public struct SyncReport: Sendable, Equatable, Codable {
    public var toPhone = 0, fromPhone = 0, conflicts = 0, removedOnPhone = 0
    public var at: Date
    public init(at: Date) { self.at = at }
    public var line: String {
        var parts: [String] = []
        if fromPhone > 0 { parts.append("\(fromPhone) note\(fromPhone == 1 ? "" : "s") came back from your iPhone and \(fromPhone == 1 ? "was" : "were") merged") }
        if toPhone > 0 { parts.append("\(toPhone) sent to the phone") }
        parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

extension Vault {
    /// Three-way sync between the Mac vault and its iCloud copy, using the last synced content as the base
    /// (kept under `.sync/` in the vault). Rules, in order:
    /// - changed only on the phone → the phone's text replaces the Mac's (your words come back);
    /// - changed only on the Mac → copied to the phone (Brownie's night's work goes out);
    /// - changed on both → the phone's text stays on top, Brownie's version goes under its own heading — nothing you wrote is overwritten;
    /// - new on the phone → added; deleted on the phone → restored from the Mac (the Mac is the truth for deletions).
    public static func sync(_ root: URL, to dest: URL, now: Date = Date()) throws -> SyncReport {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let base = root.appendingPathComponent(".sync")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var report = SyncReport(at: now)
        let macNotes = notes(under: root), phoneNotes = notes(under: dest)
        for rel in Set(macNotes.keys).union(phoneNotes.keys) {
            let macURL = root.appendingPathComponent(rel), phoneURL = dest.appendingPathComponent(rel), baseURL = base.appendingPathComponent(rel)
            let mac = macNotes[rel], phone = phoneNotes[rel]
            let baseText = try? String(contentsOf: baseURL, encoding: .utf8)
            switch (mac, phone) {
            case (let m?, nil):
                if baseText != nil, baseText == m { /* deleted on the phone; the Mac is the truth for deletions */ report.removedOnPhone += 1 }
                try copy(macURL, to: phoneURL); try copy(macURL, to: baseURL); report.toPhone += 1
            case (nil, let p?):
                try write(p, to: macURL); try write(p, to: baseURL); report.fromPhone += 1
            case (let m?, let p?):
                if m == p { if baseText != m { try write(m, to: baseURL) }; continue }
                let macChanged = baseText != m, phoneChanged = baseText != p
                switch (macChanged, phoneChanged) {
                case (false, _): try write(p, to: macURL); try write(p, to: baseURL); report.fromPhone += 1
                case (true, false): try copy(macURL, to: phoneURL); try copy(macURL, to: baseURL); report.toPhone += 1
                case (true, true):
                    let merged = merge(yours: p, brownies: m, at: now)
                    try write(merged, to: macURL); try write(merged, to: phoneURL); try write(merged, to: baseURL)
                    report.conflicts += 1; report.fromPhone += 1
                }
            default: break
            }
        }
        log.info("sync: \(report.line)")
        return report
    }

    /// The conflict shape: what you wrote on the phone stays as the note; Brownie's version follows under its own heading.
    public static func merge(yours: String, brownies: String, at: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        return yours.trimmingCharacters(in: .newlines) + "\n\n## Brownie's version (\(f.string(from: at)) — you edited this note on your phone at the same time; pick what you want to keep)\n\n" + brownies.trimmingCharacters(in: .newlines) + "\n"
    }

    static func notes(under root: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let u as URL in e where u.pathExtension == "md" {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if rel.hasPrefix(".") || rel.contains("/.") { continue }
            if let t = try? String(contentsOf: u, encoding: .utf8) { out[rel] = t }
        }
        return out
    }
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func copy(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: to); try FileManager.default.copyItem(at: from, to: to)
    }
}
