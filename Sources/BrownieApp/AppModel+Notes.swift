import Foundation
import AppKit
import Domain
import Knowledge
import Proactive
import Pipeline

/// The Notes screen's side of the model: the rail's lists, Today's ticks, the header's facts, the watcher.
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

    // MARK: from a note to elsewhere

    /// Ask, with the question started for the user: "about Meera: ".
    func askAbout(_ name: String) { askPrefill = "about \(name): "; overlay = .none; screen = .ask }
    /// The chat with this person, by the first handle the registry knows ("whatsapp:+91…" → WhatsApp).
    func openChat(with person: Person) {
        guard let h = person.handles.first, let colon = h.firstIndex(of: ":") else { return }
        openChatApp(String(h[..<colon]), name: person.name)
    }
    func openInObsidian(_ path: String? = nil) {
        guard let path, let enc = knowledge.rootURL.appendingPathComponent(path).path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let u = URL(string: "obsidian://open?path=\(enc)") else { Vault.openInObsidian(knowledge.rootURL); return }
        NSWorkspace.shared.open(u)
    }
    func showInFinder(_ path: String? = nil) {
        if let path { NSWorkspace.shared.activateFileViewerSelecting([knowledge.rootURL.appendingPathComponent(path)]) } else { NSWorkspace.shared.open(knowledge.rootURL) }
    }

    // MARK: Today

    /// Today.md as the morning stands: the ready cards as boxes. The file on disk is the same text as of the last sync.
    var todayMarkdown: String { TodayNote.render(cards: cards + snoozedCards, date: Date()) }
    var todayOpenCount: Int { TodayNote.parse(todayMarkdown).filter { !$0.checked }.count }
    /// A box ticked on the Mac goes the way a tick on the phone does: the same parse, the same apply, the card done.
    func tickToday(cardID: String) {
        let md = NoteBlocks.setCheckbox(in: todayMarkdown, cardID: cardID, checked: true)
        let file = knowledge.rootURL.appendingPathComponent(TodayNote.path)
        if FileManager.default.fileExists(atPath: file.path) { try? md.write(to: file, atomically: true, encoding: .utf8) }   // the phone sees the tick at the next sync
        let store = self.store
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            let done = TodayNote.apply(TodayNote.parse(md), to: &all, now: Date())
            if !done.isEmpty { try? await RunCoordinator.saveCards(all, store: store) }
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

    /// A note changed on disk — Obsidian, the phone, the household — and the screen reads it again.
    func startVaultWatcher() {
        // Before the first run there is no vault yet; an empty folder is nothing (exists() counts notes) and gives FSEvents a path to hold.
        try? FileManager.default.createDirectory(at: knowledge.rootURL, withIntermediateDirectories: true)
        vaultWatcher.start(knowledge.rootURL) { [weak self] _ in Task { @MainActor in await self?.reload() } }
    }
}
