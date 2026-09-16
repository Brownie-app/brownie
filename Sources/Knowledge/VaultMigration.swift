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
                    meta.aliases = ([p.name] + p.aliases).filter { $0 != title }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                }
            }
            do { try (meta.render() + body).write(to: u, atomically: true, encoding: .utf8); done += 1 }
            catch { log.warn("could not stamp \(rel): \(error)") }
        }
        if done > 0 { log.info("front-matter added to \(done) note(s)") }
        return done
    }
}
