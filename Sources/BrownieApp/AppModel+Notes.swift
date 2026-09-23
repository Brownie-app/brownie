import Foundation
import AppKit
import Domain
import Knowledge
import Proactive
import Pipeline

/// The raw editor outside the view: the sitting (`EditSession`), and a move away from the note that found an unsaved
/// edit and waits for Save, Discard or Keep editing before it goes.
struct NoteEditor {
    var session: EditSession?
    var leaving: Leave?
    struct Leave: Identifiable { let id = UUID(); let go: () -> Void }
}

/// The Notes screen's side of the model: the rail's lists, the editor, Today's ticks, the header's facts, the watcher.
extension AppModel {
    // MARK: the rail's lists

    func noteOpened(_ path: String) { recentNotes.open(path); UserDefaults.standard.set(recentNotes.paths, forKey: "notes.recent") }
    func togglePin(_ path: String) { pinnedNotes.toggle(path); UserDefaults.standard.set(pinnedNotes.paths, forKey: "notes.pinned") }
    /// A note that is gone leaves both lists, so neither points at nothing.
    func noteGone(_ path: String) {
        recentNotes.remove(path); pinnedNotes.remove(path)
        UserDefaults.standard.set(recentNotes.paths, forKey: "notes.recent"); UserDefaults.standard.set(pinnedNotes.paths, forKey: "notes.pinned")
    }
    func note(at path: String) -> Note? { for f in folders { if let n = f.notes.first(where: { $0.relativePath == path }) { return n } }; return nil }
    /// Where a note that is not at `path` went, when it only moved: `People/X.md` to `People/Archive/X.md` or back.
    func movedPath(_ path: String) -> String? { [NoteArchive.archivedPath(path), NoteArchive.activePath(path)].first { $0 != path && note(at: $0) != nil } }
    /// The path a note answers to now — itself, or where it moved; nil when it is nowhere.
    func currentPath(_ path: String) -> String? { note(at: path) != nil ? path : movedPath(path) }
    /// After the vault changed: a pinned or recent note that moved is followed, one that is gone is dropped, and what
    /// UserDefaults holds says the same. An empty listing is the vault not read yet, not a vault with nothing in it.
    func settleNoteLists() {
        guard !folders.isEmpty else { return }
        let existing = Set(folders.flatMap { $0.notes.map(\.relativePath) })
        let r = recentNotes.settled(existing: existing, moved: movedPath), p = pinnedNotes.settled(existing: existing, moved: movedPath)
        if r != recentNotes { recentNotes = r; UserDefaults.standard.set(r.paths, forKey: "notes.recent") }
        if p != pinnedNotes { pinnedNotes = p; UserDefaults.standard.set(p.paths, forKey: "notes.pinned") }
    }

    // MARK: the editor

    /// Edit pressed: the sitting starts from the note as it stands, so Save can tell whether the file moved under it.
    func beginEdit(_ n: Note) { noteEditor.session = EditSession(path: n.relativePath, opened: NoteEdit.forEditing(n.body)) }
    func endEdit() { noteEditor.session = nil; noteEditor.leaving = nil }
    /// Every way off the note being edited passes through here — a rail row, a link, ⌘K, the sidebar. With nothing
    /// typed the editor simply closes and `then` runs; with an unsaved edit on the Notes screen it asks first, and
    /// `then` runs only after Save or Discard. Off the Notes screen nothing can ask, so the sitting is kept and the
    /// move goes ahead; the editor is still up, draft and all, when the screen comes back.
    func leaveNote(then: @escaping () -> Void) {
        if let s = noteEditor.session {
            if s.dirty {
                if screen == .notes && overlay == .none { noteEditor.leaving = NoteEditor.Leave(go: then); return }
            } else { noteEditor.session = nil }
        }
        then()
    }
    /// The edited prose goes back under the note's own front-matter with its status block put back exactly. The outcome
    /// is said either way; on failure the sitting stays, draft intact, so nothing typed is lost.
    func saveEdit(prose: String, over n: Note, then: (() -> Void)? = nil) {
        let body = NoteEdit.reattach(edited: prose, original: n.body)
        let updated = Note(relativePath: n.relativePath, title: n.title, body: body, sources: n.sources, updatedAt: Date(), userEdited: true)
        Task {
            do { try await knowledge.save(updated); await reload(); endEdit(); announcement = "Saved “\(n.title)”."; then?() }
            catch { announcement = "Couldn't save “\(n.title)”: \(error.localizedDescription)" }
        }
    }
    /// The note went while it was being edited: the draft is written as a note of its own at the path it had.
    func saveCopy(_ s: EditSession, then: (() -> Void)? = nil) {
        let title = EditSession.title(of: s.draft, path: s.path)
        let copy = Note(relativePath: s.path, title: title, body: s.draft, sources: [], updatedAt: Date(), userEdited: true)
        Task {
            do { try await knowledge.save(copy); await reload(); endEdit(); announcement = "Saved a copy of “\(title)”."; then?() }
            catch { announcement = "Couldn't save “\(title)”: \(error.localizedDescription)" }
        }
    }
    /// Delete, with the outcome said. On failure nothing else moves: the lists keep the note and the screen stays on it.
    func deleteNote(_ n: Note) async -> Bool {
        do { try await knowledge.delete(relativePath: n.relativePath) }
        catch { announcement = "Couldn't delete “\(n.title)”: \(error.localizedDescription)"; return false }
        noteGone(n.relativePath)
        if noteEditor.session?.path == n.relativePath { endEdit() }
        announcement = "Deleted “\(n.title)”."
        await reload()
        return true
    }

    // MARK: from a note to elsewhere

    /// Ask, with the question started for the user: "about Meera: ".
    func askAbout(_ name: String) { askPrefill = "about \(name): "; overlay = .none; screen = .ask }
    /// The chat with this person, by the handle's own address (`ChatLink`): WhatsApp or iMessage straight to the chat;
    /// a handle with no address, or an app with no per-person link, goes the evidence sheet's way (Contacts, else the app).
    func openChat(with person: Person) {
        guard let pick = ChatLink.pick(person.handles) else { return }
        if let u = ChatLink.url(app: pick.app, address: pick.address) { NSWorkspace.shared.open(u) } else { openChatApp(pick.app, name: person.name) }
    }
    /// The note in Obsidian, or the vault when there is no note. Without Obsidian the button says so instead of doing nothing.
    func openInObsidian(_ path: String? = nil) {
        guard Vault.obsidianInstalled else { announcement = "Obsidian isn't installed — it's free at obsidian.md (Settings → Knowledge)."; return }
        guard let path, let enc = knowledge.rootURL.appendingPathComponent(path).path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let u = URL(string: "obsidian://open?path=\(enc)") else { Vault.openInObsidian(knowledge.rootURL); return }
        if !NSWorkspace.shared.open(u) { announcement = "Obsidian isn't installed — it's free at obsidian.md (Settings → Knowledge)." }
    }
    func showInFinder(_ path: String? = nil) {
        if let path { NSWorkspace.shared.activateFileViewerSelecting([knowledge.rootURL.appendingPathComponent(path)]) } else { NSWorkspace.shared.open(knowledge.rootURL) }
    }

    // MARK: Today

    /// Today.md as the morning stands: the ready cards as boxes. The file on disk is the same text as of the last sync.
    var todayMarkdown: String { TodayNote.render(cards: cards + snoozedCards, date: Date()) }
    var todayOpenCount: Int { TodayNote.parse(todayMarkdown).filter { !$0.checked }.count }
    /// A box ticked on the Mac goes the way a tick on the phone does: the same parse, the same apply, the card done — and said.
    func tickToday(cardID: String) {
        let md = NoteBlocks.setCheckbox(in: todayMarkdown, cardID: cardID, checked: true)
        let file = knowledge.rootURL.appendingPathComponent(TodayNote.path)
        if FileManager.default.fileExists(atPath: file.path) { try? md.write(to: file, atomically: true, encoding: .utf8) }   // the phone sees the tick at the next sync
        let title = (cards + snoozedCards).first { $0.id == cardID }?.title
        let store = self.store
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            let done = TodayNote.apply(TodayNote.parse(md), to: &all, now: Date())
            if !done.isEmpty { try? await RunCoordinator.saveCards(all, store: store) }
            if let title, done.contains(cardID) { announcement = "“\(title)” marked done." }
            await reload()
        }
    }

    // MARK: the person header

    /// When they last wrote and when the user last replied, from the asks ledger; nil when it has nothing for them.
    func lastExchange(with title: String, person: Person?) async -> (them: Date?, you: Date?) {
        let asks = RunCoordinator.loadAsks(try? await store.value(SettingKey.asks))
        let theirs = asks.filter { a in AskLedger.samePerson(a.person, title) || (person.map { p in a.handle.map { p.handles.contains($0) } ?? false || p.keys.contains(PersonKey.normalise(a.person)) } ?? false) }
        return (theirs.map(\.askedAt).max(), theirs.compactMap(\.answeredAt).max())
    }

    // MARK: the watcher

    /// A note changed on disk — Obsidian, the phone, the household, the gardener — and the screen reads it again; the
    /// rail's lists follow a note that moved.
    func startVaultWatcher() {
        // Before the first run there is no vault yet; an empty folder is nothing (exists() counts notes) and gives FSEvents a path to hold.
        try? FileManager.default.createDirectory(at: knowledge.rootURL, withIntermediateDirectories: true)
        vaultWatcher.start(knowledge.rootURL) { [weak self] _ in Task { @MainActor in await self?.reload(); self?.settleNoteLists() } }
    }
}
