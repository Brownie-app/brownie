import Foundation
import Domain
import Support

/// The nightly pass over People/ and Groups/: every note put back into its shape (`NoteSkeleton`), aged
/// (`NoteAging`, with the status-block lines that retired lately handed in by the pipeline), and written back through
/// `NoteMeta.restamp` — so a rewrite that is code's is never later read as the user's edit and `updated` does not
/// move for tidying alone; a note the pass leaves as it was is not touched, byte for byte. Then the quiet notes go
/// to Archive/. Runs after the status block is written each night, and once at launch alongside the migration.
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

    /// `retiredLines` answers, for a note's vault path ("People/Kanika Pandey.md"), the status-block lines that left it
    /// lately (`StatusBlock.retiredLines` in Proactive; the pipeline passes it so Knowledge never imports Proactive). It is
    /// keyed by path, not title, so the lines go where the registry routed the block — never re-derived from a name,
    /// which is how "Arjun"'s promise once landed in both Arjuns' notes. `archive` false skips the move; `keep` names
    /// the notes the move never takes (`NoteArchive.archive`).
    @discardableResult
    public static func run(root: URL, registry: PersonRegistry? = nil, now: Date, timeZone: TimeZone = .current,
                           retiredLines: (String) -> [String] = { _ in [] }, archive: Bool = true, keep: Set<String> = []) async -> Summary {
        var s = Summary()
        for folder in ["People", "Groups"] {
            for rel in NoteArchive.notes(in: folder, under: root) {
                let url = root.appendingPathComponent(rel)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                s.notes += 1
                let (meta, _) = NoteMeta.parse(raw, path: rel)
                let kind = meta.flatMap { NoteMeta.Kind(rawValue: $0.brownie) } ?? NoteMeta.Kind(rawValue: NoteMeta.kind(forPath: rel)) ?? .topic
                let retired = retiredLines(rel)
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
        if archive { s.archived = await NoteArchive.archive(root: root, registry: registry, now: now, timeZone: timeZone, keep: keep).count }
        if s.notes > 0 { log.info(s.line) }
        return s
    }

    /// The pass at launch: tidying only — nothing is archived here, the nightly run does that after its swap — and
    /// nothing at all while a sync is mid-way (`syncPending`: a resume token exists). The builder froze every live
    /// note's stamp when it seeded its staging copy, and a note rewritten now would be taken, when the sync resumes and
    /// finishes, for the user's edit — kept over the brain's merged work, from summaries already marked merged and
    /// never fed again. Nil when nothing ran.
    @discardableResult
    public static func atLaunch(root: URL, registry: PersonRegistry? = nil, now: Date, timeZone: TimeZone = .current, syncPending: Bool) async -> Summary? {
        guard !syncPending else { log.info("a sync is mid-way; the vault is left as it is until it finishes"); return nil }
        return await run(root: root, registry: registry, now: now, timeZone: timeZone, archive: false)
    }
}
