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
