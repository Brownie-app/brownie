import Foundation
import Domain
import Support

/// Quiet people leave the working set: a People note whose substance has not changed in 180 days (`updated`, the
/// file's own date when the body was edited outside Brownie, the newest date on its status block, or the day it last
/// came back from Archive/ — whichever is latest) and whose status block holds nothing open (no ⏳ line) moves to
/// `People/Archive/`; a Groups note after 120 days to `Groups/Archive/`. An archived note is still a note — indexed,
/// searched, served over MCP and mirrored to the phone — but the brain's `list_dir` does not show it, the vault's
/// measure does not count it, and the quiet check never sees it as evidence. It comes back on its own the night a new
/// ask, loop or summary names that person — by name, or by the handle the registry ties to them — before the brain
/// writes, so the brain always finds one file per person where it expects it; the night it comes back is stamped on
/// it, so a chat that is read every night while its note stays as it was is not sent away again the same night.
/// The registry's `notePath` follows every move.
public enum NoteArchive {
    public static let personDays = 180, groupDays = 120
    public static let folder = "Archive"
    /// The front-matter key that records the day a note last came back from Archive/: activity, for the quiet rule.
    public static let unarchivedKey = "brownie_unarchived"
    private static let log = Log("archive")
    private static let dayMonth = try! NSRegularExpression(pattern: #"\b(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b"#)

    /// Who a note is named by tonight: a label as a source spells it, with the chat's stable handle when there is one.
    public struct Mention: Sendable, Equatable {
        public let label: String, handle: String?
        public init(_ label: String, handle: String? = nil) { self.label = label; self.handle = handle }
    }

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
    /// Quiet is measured from the latest sign of life: the `updated` day; the file's own date when the body no longer
    /// hashes to what Brownie last wrote (an edit in Obsidian moves the file's date and nothing else — code's own
    /// rewrites keep the hash in step, so the gardener's tidying is not life) or when there is no block to say;
    /// the newest date on the status block; and the day the note last came back from Archive/.
    public static func isDue(path rel: String, raw: String, mtime: Date, now: Date, timeZone: TimeZone = .current) -> Bool {
        guard !isArchived(rel), rel.split(separator: "/").count == 2, Vault.isNote(rel), let days = quietDays(rel) else { return false }
        let (meta, body) = NoteMeta.parse(raw, path: rel)
        let block = NoteStatus.extract(from: body)
        if let block, block.contains("⏳") { return false }
        var signs: [Date] = [NoteMeta.date(meta?.updated ?? "", timeZone) ?? mtime]
        if meta.map({ $0.contentHash.isEmpty || $0.bodyDiffers(body) }) ?? true { signs.append(mtime) }
        if let day = meta?.extra[unarchivedKey], let d = NoteMeta.date(day.trimmingCharacters(in: .whitespaces), timeZone) { signs.append(d) }
        if let block, let d = newestDay(in: block, now: now, timeZone: timeZone) { signs.append(d) }
        return now.timeIntervalSince(signs.max()!) >= Double(days) * 86400
    }

    /// The latest "d MMM" in a status block, read against now's year (the year before when that would be ahead of today).
    static func newestDay(in block: String, now: Date, timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "d MMM yyyy"
        let year = cal.component(.year, from: now), ns = block as NSString
        return dayMonth.matches(in: block, range: NSRange(location: 0, length: ns.length)).compactMap { m -> Date? in
            guard var d = f.date(from: ns.substring(with: m.range) + " \(year)") else { return nil }
            if d > now, let back = cal.date(byAdding: .year, value: -1, to: d) { d = back }
            return d
        }.max()
    }

    /// Every due note moved under its folder's Archive/, the registry told. `keep` names the notes that stay whatever
    /// their age: the household's shared group notes (the sync would take an archived one off the shared folder for
    /// everyone, and the other Mac would bring it back beside the archived copy) and the notes brought back tonight.
    /// Returns the paths that moved (their old spelling).
    @discardableResult
    public static func archive(root: URL, registry: PersonRegistry?, now: Date, timeZone: TimeZone = .current, keep: Set<String> = []) async -> [String] {
        var moved: [String] = []
        for folder in ["People", "Groups"] {
            for rel in notes(in: folder, under: root) where !keep.contains(rel) {
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
    /// it, the handle first (a chat saved under a bare number has no name to match, and a chat renamed since still
    /// carries the same handle) — moved back where the brain writes, and stamped with the day it came back.
    /// Returns the paths that came back (their active spelling).
    @discardableResult
    public static func unarchive(root: URL, registry: PersonRegistry?, mentioned: [Mention], now: Date, timeZone: TimeZone = .current) async -> [String] {
        let mentions = mentioned.map { Mention($0.label.trimmingCharacters(in: .whitespacesAndNewlines), handle: $0.handle) }
            .filter { !PersonKey.normalise($0.label).isEmpty || !($0.handle ?? "").isEmpty }
        guard !mentions.isEmpty else { return [] }
        let people = await registry?.people() ?? []
        var back: [String] = []
        for folder in ["People", "Groups"] {
            for rel in notes(in: folder + "/" + Self.folder, under: root) {
                let url = root.appendingPathComponent(rel)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let title = NoteMeta.parse(raw, path: rel).body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? String(rel.split(separator: "/").last!.dropLast(3))
                let owner = people.first { $0.notePath == rel }
                let named = mentions.contains { m in PersonKey.same(title, m.label) || (owner.map { o in PersonRegistry.resolve(label: m.label, handle: m.handle, among: people) == o.id } ?? false) }
                guard named else { continue }
                if let to = move(rel, to: activePath(rel), under: root) {
                    back.append(to); await retarget(registry, from: rel, to: to)
                    stamp(to, under: root, day: NoteMeta.day(now, timeZone))
                }
            }
        }
        if !back.isEmpty { await save(registry); log.info("brought back \(back.count) archived note(s): \(back.joined(separator: ", "))") }
        return back
    }
    /// The older shape, for callers that know only names.
    @discardableResult
    public static func unarchive(root: URL, registry: PersonRegistry?, mentioned: [String], now: Date, timeZone: TimeZone = .current) async -> [String] {
        await unarchive(root: root, registry: registry, mentioned: mentioned.map { Mention($0) }, now: now, timeZone: timeZone)
    }

    // MARK: helpers

    /// The day a note came back, written into its front-matter as code's own change (the hash and `updated` stand, so
    /// nothing reads it as the user's edit); a note with no front-matter has nowhere to carry it and is left as it is.
    static func stamp(_ rel: String, under root: URL, day: String) {
        let url = root.appendingPathComponent(rel)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), var meta = NoteMeta.parse(raw, path: rel).meta else { return }
        let body = NoteMeta.parse(raw, path: rel).body
        meta.extra[unarchivedKey] = " " + day
        if !meta.extraOrder.contains(unarchivedKey) { meta.extraOrder.append(unarchivedKey) }
        do { try (meta.render() + body).write(to: url, atomically: true, encoding: .utf8) } catch { log.warn("could not stamp \(rel): \(error)") }
    }

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
