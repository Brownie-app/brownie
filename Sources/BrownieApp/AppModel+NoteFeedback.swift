import Foundation
import Domain
import Knowledge
import Proactive
import Support

/// The Notes screen's "Was this note right?": the word is kept under `SettingKey.noteFeedback`, the builder reads its
/// digest before it writes at night, and the rated note goes out at once with its evidence for the prompt evals.
extension AppModel {
    /// One word per note per day; a second the same day replaces the first. Said back in one line.
    func rateNote(path: String, verdict: NoteFeedback.Verdict, reason: String? = nil) {
        guard let n = note(at: path) else { announcement = "That note isn't there any more."; return }
        let entry = NoteFeedback(path: path, title: n.title, contentHash: NoteMeta.hash(n.body), verdict: verdict, reason: reason, at: Date())
        noteFeedback.add(entry, now: Date())
        set(SettingKey.noteFeedback, noteFeedback.json)
        announcement = "Noted. Brownie reads this before it writes tonight."
        // The rated words and tonight's evidence go out for the prompt evals now, off the main thread; FINISH refreshes the file each night.
        let store = self.store, people = self.people, log = self.log
        Task.detached {
            let rows = (try? await store.summaries(since: nil)) ?? []
            do { try NoteEvalExport.write(entry, note: n, rows: rows, people: people, folder: NoteEvalExport.folder, now: Date(), timeZone: .current) }
            catch { log.warn("eval export of \(path): \(error)") }
        }
    }
    /// The newest word on a note, if any.
    func feedback(for path: String) -> NoteFeedback? { noteFeedback.latest(for: path) }
}
