import Foundation
import Domain
import Support

/// The nightly pass over People/ and Groups/: every note put back into its shape (`NoteSkeleton`), aged
/// (`NoteAging`, with the status-block lines that retired today handed in by the pipeline), and written back through
/// `NoteMeta.restamp` — so a rewrite that is code's is never later read as the user's edit and `updated` does not
/// move for tidying alone; a note the pass leaves as it was is not touched, byte for byte. Then the quiet notes go
/// to Archive/. Runs after the status block is written each night, and once at bootstrap alongside the migration.
public enum VaultGardener {
    private static let log = Log("gardener")

    public struct Summary: Sendable, Equatable {
        public var notes = 0, tidied = 0, movedToEarlier = 0, retired = 0, archived = 0
        public var changed: [String] = []
        public init() {}
        /// "gardener: 12 notes tidied, 3 bullets moved to Earlier, 1 person archived"
        public var line: String {
            func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v) \(v == 1 ? one : many)" }
            var parts = [n(tidied, "note tidied", "notes tidied"), n(movedToEarlier, "bullet moved to Earlier", "bullets moved to Earlier")]
            if retired > 0 { parts.append(n(retired, "retired line kept", "retired lines kept")) }
            parts.append(n(archived, "person archived", "archived"))
            return "gardener: " + parts.joined(separator: ", ")
        }
    }

    /// `retiredLines` answers, for a note's title, the status-block lines that left it today (`StatusBlock.retiredLines`
    /// in Proactive; the pipeline passes it so Knowledge never imports Proactive). `archive` false skips the move.
    @discardableResult
    public static func run(root: URL, registry: PersonRegistry? = nil, now: Date, timeZone: TimeZone = .current,
                           retiredLines: (String) -> [String] = { _ in [] }, archive: Bool = true) async -> Summary {
        var s = Summary()
        for folder in ["People", "Groups"] {
            for rel in NoteArchive.notes(in: folder, under: root) {
                let url = root.appendingPathComponent(rel)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                s.notes += 1
                let (meta, body) = NoteMeta.parse(raw, path: rel)
                let kind = meta.flatMap { NoteMeta.Kind(rawValue: $0.brownie) } ?? NoteMeta.Kind(rawValue: NoteMeta.kind(forPath: rel)) ?? .topic
                let title = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? String(rel.split(separator: "/").last!.dropLast(3))
                let retired = retiredLines(title)
                var report = NoteSkeleton.Report()
                // normalise, then age — one pass holds every invariant, so the shape and the clock are settled together
                guard let text = NoteMeta.restamp(raw, path: rel, body: { old in
                    guard let (new, r) = NoteAging.pass(body: old, kind: kind, now: now, retired: retired, timeZone: timeZone), new != old else { return nil }
                    report = r; return new
                }) else { continue }
                do { try text.write(to: url, atomically: true, encoding: .utf8); s.tidied += 1; s.movedToEarlier += report.movedToEarlier; s.retired += report.retired; s.changed.append(rel) }
                catch { log.warn("could not write \(rel): \(error)") }
            }
        }
        if archive { s.archived = await NoteArchive.archive(root: root, registry: registry, now: now, timeZone: timeZone).count }
        if s.notes > 0 { log.info(s.line) }
        return s
    }
}
