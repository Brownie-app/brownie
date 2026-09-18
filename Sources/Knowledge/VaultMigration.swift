import Foundation
import Domain
import Support

/// The one-time pass that gives every note in a live vault the code-owned front-matter: the kind from its folder,
/// `created` from the file's birth date, `updated` today, the hash of its body, and for a People note the registry's
/// id and spellings. A note that already carries the block is left alone, so the pass is safe at every start; a
/// legacy block (the old `sources`/`updated`/`user_edited` keys) keeps its sources and its edited flag.
public enum VaultMigration {
    private static let log = Log("vault.migrate")

    @discardableResult
    public static func addFrontMatter(root: URL, registry: PersonRegistry?, now: Date, timeZone: TimeZone = .current) async -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return 0 }
        let today = NoteMeta.day(now, timeZone)
        var done = 0
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            guard Vault.isNote(rel), let raw = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let (parsed, body) = NoteMeta.parse(raw, path: rel)
            if let m = parsed, !m.created.isEmpty { continue }   // already Brownie's
            var meta = parsed ?? NoteMeta(brownie: NoteMeta.kind(forPath: rel), created: "", updated: "")
            let birth = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            meta.created = NoteMeta.day(birth, timeZone); meta.updated = today; meta.contentHash = NoteMeta.hash(body)
            if rel.hasPrefix("People/"), let registry {
                let title = body.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? String(rel.dropFirst("People/".count).dropLast(3))
                if let id = await registry.resolve(label: title, handle: nil), let p = await registry.person(id) {
                    meta.id = id
                    // the user's own `aliases:` (their [[links]] resolve by them) stay first; the registry's spellings join, none twice
                    meta.aliases = (meta.aliases + ([p.name] + p.aliases).filter { $0 != title }).reduce(into: [String]()) { acc, a in
                        if !acc.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) { acc.append(a) }
                    }
                }
            }
            do { try (meta.render() + body).write(to: u, atomically: true, encoding: .utf8); done += 1 }
            catch { log.warn("could not stamp \(rel): \(error)") }
        }
        if done > 0 { log.info("front-matter added to \(done) note(s)") }
        return done
    }

    /// The one-time pass that takes the user out of their own People folder. A People note whose title is the user
    /// under any spelling ("Vivek Upreti.md"), or opens with a self name and a dash ("Vivek Upreti — Career Materials
    /// (Jul–Aug 2026).md"), is about the user, not about a person: it moves to `Life/` under the title with the name
    /// gone ("Life/Career Materials (Jul–Aug 2026).md" — never over a note already there, " 2" is added instead), its
    /// front-matter becomes a topic's, and the registry record that claimed it (or that carries a self name) goes.
    /// Loops whose other party is the user are dropped from the ledger, whatever their status: the user owes nothing
    /// to themselves. Returns how many notes moved. Safe every start: a vault with no such note is untouched.
    @discardableResult
    public static func moveSelfNotes(root: URL, registry: PersonRegistry?, store: (any RunStore)?, selfNames rawNames: [String], now: Date, timeZone: TimeZone = .current) async -> Int {
        let names = SelfNames.clean(rawNames)
        guard !names.isEmpty else { return 0 }
        let fm = FileManager.default
        let people = root.appendingPathComponent("People", isDirectory: true)
        var moved = 0
        // The listing is taken whole before anything moves, so the walk never meets its own work.
        let files = (fm.enumerator(at: people, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
        for u in files {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            guard Vault.isNote(rel), let raw = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let (meta, body) = NoteMeta.parse(raw, path: rel)
            let stem = String(u.deletingPathExtension().lastPathComponent)
            let heading = body.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let title = heading ?? stem
            guard SelfNames.isSelf(title, among: names) || SelfNames.isSelf(stem, among: names) else { continue }
            let newTitle = SelfNames.stripped(title, among: names) ?? SelfNames.stripped(stem, among: names) ?? title
            let dest = freePath(in: root.appendingPathComponent("Life", isDirectory: true), title: newTitle)
            let destRel = "Life/" + dest.lastPathComponent
            // A topic's block: no person id, no registry spellings; the hash follows the retitled body so the move never reads as an edit.
            var m = meta ?? NoteMeta(brownie: NoteMeta.Kind.topic.rawValue, created: NoteMeta.day(now, timeZone), updated: NoteMeta.day(now, timeZone))
            let userEdited = m.bodyDiffers(body)
            m.brownie = NoteMeta.Kind.topic.rawValue; m.id = nil; m.aliases = m.aliases.filter { !SelfNames.isSelf($0, among: names) }
            if m.created.isEmpty { m.created = NoteMeta.day(now, timeZone) }
            var newBody = body
            if let heading, heading != newTitle, let r = body.range(of: "# \(heading)") { newBody.replaceSubrange(r, with: "# \(newTitle)") }
            if !userEdited { m.contentHash = NoteMeta.hash(newBody) }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (m.render() + newBody).write(to: dest, atomically: true, encoding: .utf8)
                try fm.removeItem(at: u)
                moved += 1
                log.info("\(rel) is about the user; moved to \(destRel)")
            } catch { log.warn("could not move \(rel) to \(destRel): \(error)"); continue }
            if let registry { for p in await registry.people() where p.notePath == rel { await registry.remove(p.id) } }
        }
        if let registry {
            let own = await registry.people().filter { p in ([p.name] + p.aliases).contains { SelfNames.isSelf($0, among: names) } }
            for p in own { await registry.remove(p.id); log.info("registry record \(p.name) was the user; removed") }
            if moved > 0 || !own.isEmpty { do { try await registry.save() } catch { log.warn("people registry not saved: \(error)") } }
        }
        if let store, let json = try? await store.value(SettingKey.loops), let data = json.data(using: .utf8), let loops = try? JSONDecoder().decode([Loop].self, from: data) {
            let kept = loops.filter { !SelfNames.isSelf($0.person, among: names) }
            if kept.count != loops.count {
                log.info("\(loops.count - kept.count) loop(s) had the user as the other party; dropped")
                try? await store.setValue(SettingKey.loops, String(data: (try? JSONEncoder().encode(kept)) ?? Data(), encoding: .utf8))
            }
        }
        if moved > 0 { log.info("\(moved) note(s) about the user moved out of People/") }
        return moved
    }

    /// `Life/<title>.md`, or `Life/<title> 2.md`, `… 3.md` when taken: a note is never written over.
    static func freePath(in folder: URL, title: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(title + ".md"), n = 2
        while fm.fileExists(atPath: candidate.path) { candidate = folder.appendingPathComponent("\(title) \(n).md"); n += 1 }
        return candidate
    }
}
