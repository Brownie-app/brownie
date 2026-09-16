import Foundation
import AppKit
import Domain
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

    /// Whether a vault-relative path is knowledge: Markdown, not hidden, and not `Today.md` — Brownie's own checklist
    /// for the phone, which lives in the vault so it syncs but is never indexed, searched, counted or shown to the brain.
    public static func isNote(_ rel: String) -> Bool {
        guard rel.hasSuffix(".md"), !rel.hasPrefix("."), !rel.contains("/.") else { return false }
        return rel != TodayNote.path
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
    /// Notes deleted on the Mac since the last sync, so taken off the phone too instead of coming back.
    public var deletedOnMac = 0
    public var at: Date
    public init(at: Date) { self.at = at }
    enum CodingKeys: String, CodingKey { case toPhone, fromPhone, conflicts, removedOnPhone, deletedOnMac, at }
    /// A report saved before `deletedOnMac` existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toPhone = try c.decodeIfPresent(Int.self, forKey: .toPhone) ?? 0; fromPhone = try c.decodeIfPresent(Int.self, forKey: .fromPhone) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0; removedOnPhone = try c.decodeIfPresent(Int.self, forKey: .removedOnPhone) ?? 0
        deletedOnMac = try c.decodeIfPresent(Int.self, forKey: .deletedOnMac) ?? 0; at = try c.decode(Date.self, forKey: .at)
    }
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
    /// - new on the phone → added; deleted on the phone → restored from the Mac (the Mac is the truth for deletions);
    /// - deleted on the Mac (gone here, its base copy still there) → taken off the phone too, never copied back — unless
    ///   the phone changed it since the last sync, in which case what was written there comes home instead;
    /// - gone on both sides → its base copy is dropped.
    /// `ignoringFrontMatter` (the household) compares bodies with the front-matter stripped — every Mac stamps its own
    /// block, and that is no change — and what comes home is wrapped in this Mac's own block, so the local meta stays.
    public static func sync(_ root: URL, to dest: URL, now: Date = Date(), base baseName: String = ".sync", include: (String) -> Bool = { _ in true }, ignoringFrontMatter: Bool = false) throws -> SyncReport {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let base = root.appendingPathComponent(baseName)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var report = SyncReport(at: now)
        let macNotes = notes(under: root).filter { include($0.key) }, phoneNotes = notes(under: dest).filter { include($0.key) }
        for rel in notes(under: base).keys where include(rel) && macNotes[rel] == nil && phoneNotes[rel] == nil { try? fm.removeItem(at: base.appendingPathComponent(rel)) }
        for rel in Set(macNotes.keys).union(phoneNotes.keys) {
            let macURL = root.appendingPathComponent(rel), phoneURL = dest.appendingPathComponent(rel), baseURL = base.appendingPathComponent(rel)
            let mac = macNotes[rel], phone = phoneNotes[rel]
            let baseText = try? String(contentsOf: baseURL, encoding: .utf8)
            func substance(_ t: String) -> String { ignoringFrontMatter ? NoteMeta.parse(t, path: rel).body : t }
            func same(_ a: String?, _ b: String?) -> Bool { a.map(substance) == b.map(substance) }
            /// The other side's text as it lands here: under this Mac's own front-matter when there is one to keep.
            func local(_ t: String) -> String {
                guard ignoringFrontMatter, let m = mac, let meta = NoteMeta.parse(m, path: rel).meta else { return t }
                return meta.render() + substance(t)
            }
            switch (mac, phone) {
            case (let m?, nil):
                if baseText != nil, same(baseText, m) { /* deleted on the phone; the Mac is the truth for deletions */ report.removedOnPhone += 1 }
                try copy(macURL, to: phoneURL); try copy(macURL, to: baseURL); report.toPhone += 1
            case (nil, let p?):
                if baseText != nil, same(baseText, p) {
                    // It was here at the last sync and the user removed it on the Mac: the deletion goes out; the note does not come back.
                    try? fm.removeItem(at: phoneURL); try? fm.removeItem(at: baseURL); report.deletedOnMac += 1; continue
                }
                // New on the phone, or written there since the last sync while the Mac's copy went: what was written comes home.
                try write(p, to: macURL); try write(p, to: baseURL); report.fromPhone += 1
            case (let m?, let p?):
                if same(m, p) { if baseText != m { try write(m, to: baseURL) }; continue }
                let macChanged = !same(baseText, m), phoneChanged = !same(baseText, p)
                switch (macChanged, phoneChanged) {
                case (false, _): let t = local(p); try write(t, to: macURL); try write(t, to: baseURL); report.fromPhone += 1
                case (true, false): try copy(macURL, to: phoneURL); try copy(macURL, to: baseURL); report.toPhone += 1
                case (true, true):
                    let merged = local(merge(yours: substance(p), brownies: substance(m), at: now))
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

/// The household's shared folder: `Household/` notes and the group-chat notes every member is in, two-way,
/// with its own base copies so it never confuses the phone sync. `People/` and everything else stay home.
public enum HouseholdVault {
    public static let defaultFolderName = "Brownie Household"
    public static var defaultFolder: URL? { Vault.icloudFolder?.deletingLastPathComponent().appendingPathComponent(defaultFolderName) }
    /// Which vault paths cross over: the Household folder, plus the notes of the shared group chats.
    public static func isShared(_ rel: String, sharedGroupNotes: Set<String>) -> Bool {
        rel.hasPrefix("Household/") || sharedGroupNotes.contains(rel)
    }
    /// Bodies are what is compared: each member's Brownie stamps its own front-matter on its own copy, and two blocks
    /// that differ over the same words are not two versions of the note.
    public static func sync(_ root: URL, to shared: URL, sharedGroupNotes: Set<String>, now: Date = Date()) throws -> SyncReport {
        try Vault.sync(root, to: shared, now: now, base: ".household-sync", include: { isShared($0, sharedGroupNotes: sharedGroupNotes) }, ignoringFrontMatter: true)
    }
}
