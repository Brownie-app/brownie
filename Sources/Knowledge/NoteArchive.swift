import Foundation
import Domain
import Support

/// Quiet people leave the working set: a People note whose substance has not changed in 180 days (`updated`, else
/// the file's date) and whose status block holds nothing open (no ⏳ line) moves to `People/Archive/`; a Groups note
/// after 120 days to `Groups/Archive/`. An archived note is still a note — indexed, searched, served over MCP and
/// mirrored to the phone — but the brain's `list_dir` does not show it, the vault's measure does not count it, and
/// the quiet check never sees it as evidence. It comes back on its own the night a new ask, loop or summary names
/// that person, before the brain writes, so the brain always finds one file per person where it expects it.
/// The registry's `notePath` follows every move.
public enum NoteArchive {
    public static let personDays = 180, groupDays = 120
    public static let folder = "Archive"
    private static let log = Log("archive")

    /// `People/Archive/X.md` and `Groups/Archive/X.md`, and nothing else.
    public static func isArchived(_ rel: String) -> Bool { rel.hasPrefix("People/\(folder)/") || rel.hasPrefix("Groups/\(folder)/") }
    /// `People/X.md` → `People/Archive/X.md`.
    public static func archivedPath(_ rel: String) -> String {
        guard let slash = rel.firstIndex(of: "/"), !isArchived(rel) else { return rel }
        return rel[..<slash] + "/\(folder)" + rel[slash...]
    }
    /// `People/Archive/X.md` → `People/X.md`.
    public static func activePath(_ rel: String) -> String { rel.replacingOccurrences(of: "/\(folder)/", with: "/") }

    /// How long a note may be quiet before it goes, by where it lives; nil for a note the rule does not cover.
    public static func quietDays(_ rel: String) -> Int? {
        if rel.hasPrefix("People/") { return personDays }
        if rel.hasPrefix("Groups/") { return groupDays }
        return nil
    }

    /// Whether one note is due to go: a People or Groups note not yet archived, quiet past its term, with nothing open.
    public static func isDue(path rel: String, raw: String, mtime: Date, now: Date, timeZone: TimeZone = .current) -> Bool {
        guard !isArchived(rel), rel.split(separator: "/").count == 2, Vault.isNote(rel), let days = quietDays(rel) else { return false }
        let (meta, body) = NoteMeta.parse(raw, path: rel)
        let updated = meta.flatMap { NoteMeta.date($0.updated, timeZone) } ?? mtime
        guard now.timeIntervalSince(updated) >= Double(days) * 86400 else { return false }
        if let block = NoteStatus.extract(from: body), block.contains("⏳") { return false }
        return true
    }

    /// Every due note moved under its folder's Archive/, the registry told. Returns the paths that moved (their old spelling).
    @discardableResult
    public static func archive(root: URL, registry: PersonRegistry?, now: Date, timeZone: TimeZone = .current) async -> [String] {
        var moved: [String] = []
        for folder in ["People", "Groups"] {
            for rel in notes(in: folder, under: root) {
                let url = root.appendingPathComponent(rel)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                guard isDue(path: rel, raw: raw, mtime: mtime, now: now, timeZone: timeZone) else { continue }
                if let to = move(rel, to: archivedPath(rel), under: root) { moved.append(rel); await retarget(registry, from: rel, to: to) }
            }
        }
        if !moved.isEmpty { await save(registry); log.info("archived \(moved.count) quiet note(s): \(moved.joined(separator: ", "))") }
        return moved
    }

    /// Every archived note that one of `mentioned` names — by its title, or through the registry's record of who owns
    /// it — moved back where the brain writes. Returns the paths that came back (their active spelling).
    @discardableResult
    public static func unarchive(root: URL, registry: PersonRegistry?, mentioned: [String]) async -> [String] {
        let labels = mentioned.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !PersonKey.normalise($0).isEmpty }
        guard !labels.isEmpty else { return [] }
        let people = await registry?.people() ?? []
        var back: [String] = []
        for folder in ["People", "Groups"] {
            for rel in notes(in: folder + "/" + Self.folder, under: root) {
                let url = root.appendingPathComponent(rel)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let title = NoteMeta.parse(raw, path: rel).body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? String(rel.split(separator: "/").last!.dropLast(3))
                let owner = people.first { $0.notePath == rel }
                let named = labels.contains { l in PersonKey.same(title, l) || (owner.map { o in PersonRegistry.resolve(label: l, handle: nil, among: people) == o.id } ?? false) }
                guard named else { continue }
                if let to = move(rel, to: activePath(rel), under: root) { back.append(to); await retarget(registry, from: rel, to: to) }
            }
        }
        if !back.isEmpty { await save(registry); log.info("brought back \(back.count) archived note(s): \(back.joined(separator: ", "))") }
        return back
    }

    // MARK: helpers

    /// The notes directly in a folder, sorted, so two runs move the same files in the same order.
    static func notes(in folder: String, under root: URL) -> [String] {
        let dir = root.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.map { folder + "/" + $0 }.filter(Vault.isNote).sorted()
    }
    /// One move; a file already at the destination is never overwritten — that note is left where it is, with a line in the log.
    static func move(_ rel: String, to: String, under root: URL) -> String? {
        let fm = FileManager.default, dest = root.appendingPathComponent(to)
        guard !fm.fileExists(atPath: dest.path) else { log.warn("\(rel) stays: \(to) already exists"); return nil }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: root.appendingPathComponent(rel), to: dest)
            return to
        } catch { log.warn("could not move \(rel) to \(to): \(error)"); return nil }
    }
    static func retarget(_ registry: PersonRegistry?, from: String, to: String) async {
        guard let registry else { return }
        for p in await registry.people() where p.notePath == from { await registry.setNotePath(to, for: p.id) }
    }
    static func save(_ registry: PersonRegistry?) async {
        guard let registry else { return }
        do { try await registry.save() } catch { log.warn("people registry not saved: \(error)") }
    }
}
