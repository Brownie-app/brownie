import SwiftUI
import AppKit
import Domain
import Knowledge

/// Notes, made for a person at 7:30 in the morning: the body drawn (not raw Markdown), search that answers as
/// you type, a rail that remembers what you opened and what you pinned, a header on a person's note that says
/// where things stand, and an editor that never loses what Brownie keeps on the file — nor what you typed.
struct KnowledgeView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    enum Selection: Equatable { case none, today, note(String) }
    /// What a sheet is asking: delete this note; which words stay after the file changed under the editor; what to do
    /// with an unsaved edit before a move away. The last comes from the model, because the sidebar asks it too.
    enum Prompt { case delete(Note), conflict(Note), leave(NoteEditor.Leave) }
    @State private var selection: Selection = .none
    @State private var query = ""
    @State private var results: FileKnowledgeStore.SearchResults?
    @State private var hitIndex = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var expanded: Set<String> = Set((UserDefaults.standard.string(forKey: "notes.expanded") ?? "").split(separator: "\n").map(String.init))
    @State private var archivesOpen: Set<String> = []
    @State private var prompt: Prompt?
    /// What runs once a save asked for by a move away has gone through.
    @State private var afterSave: (() -> Void)?
    /// Today's boxes ticked this sitting: drawn ticked until the reload retires the line.
    @State private var ticked: Set<String> = []
    @State private var obsidian = true
    @State private var backlinks: [Note] = []
    @State private var exchange: (them: Date?, you: Date?) = (nil, nil)

    var links: LinkIndex { LinkIndex(folders: m.folders) }
    var note: Note? { if case .note(let p) = selection { return m.note(at: p) }; return nil }
    var notePath: String? { note?.relativePath }
    var noteCount: Int { m.folders.reduce(0) { $0 + $1.notes.count } }
    var subtitle: String { m.folders.isEmpty ? "Nothing yet · notes appear after the first run with a brain" : "\(noteCount) notes · plain Markdown in ~/Brownie Knowledge Base" }
    var session: EditSession? { m.noteEditor.session }
    var draft: Binding<String> { Binding(get: { m.noteEditor.session?.draft ?? "" }, set: { m.noteEditor.session?.draft = $0 }) }
    /// The sheet up now: a move away asked by the model first, else the view's own.
    var current: Prompt? { m.noteEditor.leaving.map { .leave($0) } ?? prompt }
    /// The hits whose note is still there — a delete or a rename between two keystrokes never leaves a dead row.
    var liveHits: [FileKnowledgeStore.SearchHit] { (results?.hits ?? []).filter { m.note(at: $0.note.relativePath) != nil } }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Notes", subtitle: subtitle) {
                if let h = m.vaultHealth {
                    Button { m.leaveNote { m.openSettings(.knowledge) } } label: { Chip(text: h.line) }.buttonStyle(.plain).help("Last night's measure of the vault — opens Settings → Knowledge")
                }
                SearchField(query: $query, index: $hitIndex, count: liveHits.count) { openHit() }
                BButton(title: "Open a note…", kind: .quiet, systemImage: "doc.text.magnifyingglass") { m.quickOpenShown = true }.help("⌘K from anywhere")
                if obsidian { BButton(title: "Open in Obsidian", kind: .quiet, systemImage: "arrow.up.forward.app") { m.openInObsidian(notePath) } }
                BButton(title: "Show in Finder", kind: .quiet) { m.showInFinder(notePath) }
            }
            HStack(spacing: 0) {
                rail.frame(width: 260).overlay(alignment: .trailing) { Rectangle().fill(t.sep).frame(width: 1) }.walkthroughTarget("knowledge")
                content.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { obsidian = Vault.obsidianInstalled; m.settleNoteLists(); arrive() }
        .onChange(of: m.pendingNote) { _, p in if p != nil { arrive() } }
        .onChange(of: query) { _, q in search(q) }
        .onChange(of: results) { _, _ in hitIndex = 0 }
        .onChange(of: selection) { _, _ in loadSide() }
        .onChange(of: m.folders) { _, _ in vaultChanged() }
        .onChange(of: expanded) { _, e in UserDefaults.standard.set(e.sorted().joined(separator: "\n"), forKey: "notes.expanded") }
        // One sheet for the three questions: its content follows `current`, so a Save that finds the file changed turns the leave sheet into the conflict sheet in place.
        .sheet(isPresented: Binding(get: { current != nil }, set: { if !$0 { m.noteEditor.leaving = nil; prompt = nil } })) { sheet }
    }

    @ViewBuilder var sheet: some View {
        switch current {
        case .delete(let n)?: DeleteSheet(note: n) { delete(n) }
        case .conflict(let n)?: ConflictSheet(note: n, keepMine: { keepMine(n) }, keepTheirs: { keepTheirs() }, keepBoth: { keepBoth(n) })
        case .leave(let l)?:
            LeaveSheet(title: session.map { m.note(at: $0.path)?.title ?? EditSession.title(of: $0.draft, path: $0.path) } ?? "",
                       save: { m.noteEditor.leaving = nil; save(then: l.go) },
                       discard: { m.endEdit(); l.go() },
                       keep: { m.noteEditor.leaving = nil })
        case nil: EmptyView()
        }
    }

    // MARK: arriving and opening

    /// A note asked for from elsewhere (Graph, a card, a link, ⌘K) — one that has since moved to the archive is followed
    /// and the screen says so. Back on the screen with no note open: the note being edited comes back up, draft and
    /// all; else the last one opened.
    func arrive() {
        if let p = m.pendingNote {
            m.pendingNote = nil
            if selection == .none, let s = session { select(s.path) }   // the editor first, so "Keep editing" has somewhere to stay
            guard let q = m.currentPath(p) else { m.announcement = "That note isn't there any more."; m.noteGone(p); return }
            if q != p, let n = m.note(at: q) { m.announcement = NoteLists.movedLine(title: n.title, intoArchive: NoteArchive.isArchived(q), quietDays: NoteFacts.quietDays(n)) }
            open(q); return
        }
        guard selection == .none else { return }
        if var s = session {
            if m.note(at: s.path) == nil, let q = m.movedPath(s.path) { s.path = q; m.noteEditor.session = s }
            select(s.path)
        }
        else if let p = m.recentNotes.paths.first(where: { m.note(at: $0) != nil }) { select(p) }
        else if let p = m.folders.first?.notes.first?.relativePath { select(p) }
    }
    /// A row, a link, ⌘K: an unsaved edit asks first (`leaveNote`); the note being edited is simply shown again.
    func open(_ path: String) {
        if session?.path == path { select(path); return }
        m.leaveNote { select(path) }
    }
    func select(_ path: String) {
        selection = .note(path)
        m.noteOpened(path)
        if let f = m.note(at: path)?.folder, !f.isEmpty { expanded.insert(f); if Self.isArchived(path) { archivesOpen.insert(f) } }
    }
    func showToday() { m.leaveNote { selection = .today } }
    /// The vault changed under the screen: the lists follow a note that moved, and so do the selection and the editor;
    /// a search that is showing runs again so its count and rows are true.
    func vaultChanged() {
        m.settleNoteLists()
        if case .note(let p) = selection, m.note(at: p) == nil, let q = m.movedPath(p) {
            selection = .note(q)
            if m.noteEditor.session?.path == p { m.noteEditor.session?.path = q }
            if let n = m.note(at: q) { m.announcement = NoteLists.movedLine(title: n.title, intoArchive: NoteArchive.isArchived(q), quietDays: NoteFacts.quietDays(n)) }
        }
        loadSide()
        if results != nil { search(query) }
    }
    /// What sits beside a note: who mentions it, and for a person, when you last heard from each other.
    func loadSide() {
        guard let n = note else { backlinks = []; exchange = (nil, nil); return }
        let person = m.people.first { $0.notePath == n.relativePath }
        Task {
            backlinks = (try? await m.knowledge.backlinks(to: n.title)) ?? []
            exchange = isPerson(n) ? await m.lastExchange(with: n.title, person: person) : (nil, nil)
        }
    }
    func isPerson(_ n: Note) -> Bool { n.relativePath.hasPrefix("People/") || n.relativePath.hasPrefix("Groups/") }

    // MARK: search as you type

    func search(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let r = try? await m.knowledge.find(trimmed, limit: 50)
            guard !Task.isCancelled else { return }
            results = r
        }
    }
    /// Return in the search box: the hit under the bar (the first, until ↓ moved it).
    func openHit() {
        let hits = liveHits
        guard !hits.isEmpty else { return }
        open(hits[min(hitIndex, hits.count - 1)].note.relativePath)
    }

    // MARK: the rail

    /// The pinned and recent notes as they are now: a path that moved is followed at draw time too, so the rail is
    /// right before the lists have been settled, and one note never appears twice.
    var pinned: [Note] { Self.unique(m.pinnedNotes.paths.compactMap { m.currentPath($0).flatMap(m.note(at:)) }) }
    var recent: [Note] { Self.unique(m.recentNotes.paths.compactMap { m.currentPath($0).flatMap(m.note(at:)) }) }
    static func unique(_ notes: [Note]) -> [Note] { notes.reduce(into: []) { out, n in if !out.contains(where: { $0.relativePath == n.relativePath }) { out.append(n) } } }

    var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let r = results {
                    let hits = liveHits, total = r.total - (r.hits.count - hits.count)
                    Text(total == 0 ? "No matches for “\(r.query)”" : "\(total) match\(total == 1 ? "" : "es")").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink2).padding(10)
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in hitRow(h, on: i == hitIndex) { hitIndex = i; open(h.note.relativePath) } }
                    if total > hits.count { Text("Showing \(hits.count) of \(total) — add a word to narrow it").font(.system(size: 11)).foregroundStyle(t.ink2).padding(10) }
                } else {
                    row("Today", sub: m.todayOpenCount > 0 ? "\(m.todayOpenCount)" : "", on: selection == .today, icon: "sun.max") { showToday() }
                    if !pinned.isEmpty {
                        Eyebrow(text: "Pinned").padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
                        ForEach(pinned) { n in noteRow(n, icon: "pin", sub: Self.isArchived(n.relativePath) ? "archived" : "", muted: Self.isArchived(n.relativePath)) }
                    }
                    if !recent.isEmpty {
                        Eyebrow(text: "Recent").padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
                        ForEach(recent) { n in noteRow(n, icon: "clock", sub: Self.isArchived(n.relativePath) ? "archived" : "", muted: Self.isArchived(n.relativePath)) }
                    }
                    if !m.folders.isEmpty { Eyebrow(text: "Folders").padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10)) }
                    ForEach(m.folders) { f in folderRows(f) }
                }
            }.padding(8)
        }
    }

    /// A folder opens and closes on its own; clicking it no longer jumps to its first note. Archived notes sit
    /// under a muted "Archive" row inside their folder, closed until asked for.
    @ViewBuilder func folderRows(_ f: KnowledgeFolder) -> some View {
        let isOpen = expanded.contains(f.name)
        let live = f.notes.filter { !Self.isArchived($0.relativePath) }, archived = f.notes.filter { Self.isArchived($0.relativePath) }
        let mutedFolder = f.name == "Archive"
        row(f.name, sub: "\(f.notes.count)", on: false, icon: isOpen ? "chevron.down" : "chevron.right", muted: mutedFolder) {
            if isOpen { expanded.remove(f.name) } else { expanded.insert(f.name) }
            m.markWalkthrough("knowledge")
        }
        if isOpen {
            ForEach(live) { n in noteRow(n, indent: 1) }
            if !archived.isEmpty {
                let open = archivesOpen.contains(f.name)
                row("Archive", sub: "\(archived.count)", on: false, icon: open ? "chevron.down" : "chevron.right", indent: 1, muted: true) { if open { archivesOpen.remove(f.name) } else { archivesOpen.insert(f.name) } }
                if open { ForEach(archived) { n in noteRow(n, indent: 2, muted: true) } }
            }
        }
    }
    static func isArchived(_ path: String) -> Bool { path.split(separator: "/").dropLast().contains("Archive") }

    func noteRow(_ n: Note, icon: String? = nil, sub: String = "", indent: Int = 0, muted: Bool = false) -> some View {
        row(n.title, sub: sub, on: selection == .note(n.relativePath), icon: icon, indent: indent, muted: muted) { open(n.relativePath) }
    }
    func row(_ title: String, sub: String, on: Bool, icon: String? = nil, indent: Int = 0, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(t.ink2).frame(width: 12) }
                Text(title).lineLimit(1).fontWeight(on ? .medium : .regular).foregroundStyle(muted ? t.ink2 : t.ink)
                Spacer()
                if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.leading, CGFloat(indent) * 14).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(on ? t.ctl2 : .clear))
        }.buttonStyle(.plain)
    }
    /// One search hit; `on` is the keyboard's bar (↓ and ↑ move it, Return opens), the open note is the heavier title.
    func hitRow(_ h: FileKnowledgeStore.SearchHit, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(h.note.title).lineLimit(1).fontWeight(selection == .note(h.note.relativePath) ? .medium : .regular); Spacer(); Text(h.note.folder.isEmpty ? "Home" : h.note.folder).font(.system(size: 11)).foregroundStyle(t.ink2) }
                Text(NoteMarkdown.highlighted(h.snippet, theme: t)).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(on ? t.ctl2 : .clear))
        }.buttonStyle(.plain)
    }

    // MARK: the note

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PeopleMergeBanner()
                switch selection {
                case .today: todayPane
                case .note(let p):
                    if let n = m.note(at: p) { notePane(n) }
                    else if let s = session, s.path == p { gonePane(s) }
                    else { VStack(alignment: .leading, spacing: 8) { Text("That note isn't there any more.").font(.system(size: 15, weight: .semibold)); Text("It was deleted, renamed or archived since it was opened. Pick another from the rail.").foregroundStyle(t.ink2) }.padding(.top, 20) }
                case .none:
                    VStack(alignment: .leading, spacing: 8) { Text("No notes yet").font(.system(size: 17, weight: .semibold)); Text("Run an analysis with a brain configured and your knowledge base appears here as plain Markdown files.").foregroundStyle(t.ink2) }.padding(.top, 20)
                }
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Today's boxes. A box ticked this sitting is drawn ticked at once; the reload that follows retires the line.
    var todayPane: some View {
        let md = ticked.reduce(m.todayMarkdown) { NoteBlocks.setCheckbox(in: $0, cardID: $1, checked: true) }
        return VStack(alignment: .leading, spacing: 12) {
            NoteBody(blocks: NoteBlocks.parse(md), links: links, onTick: { id in ticked.insert(id); m.tickToday(cardID: id) })
            Text("A tick here does what a tick on the phone does: the card is marked done. Sending, paying and deleting stay yours.").font(.system(size: 11)).foregroundStyle(t.ink2)
        }
    }

    @ViewBuilder func notePane(_ n: Note) -> some View {
        let editing = session?.path == n.relativePath
        HStack(spacing: 8) {
            Text("\(n.folder.isEmpty ? "Home" : n.folder) / \(n.title)").font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1)
            Spacer()
            if n.userEdited { Chip(text: "edited by hand").help("Changed by a person, not by the brain — in this app, Obsidian, on the phone or by someone at home. Brownie keeps hand edits when it rewrites the note at night.") }
            if m.pinnedNotes.contains(n.relativePath) { Chip(text: "pinned", accent: true) }
            if Self.isArchived(n.relativePath) { Chip(text: "archived").help("Quiet for a long while, so it left the working set. It comes back on its own the night someone mentions them.") }
            if editing {
                BButton(title: "Save", kind: .primary) { save() }
                BButton(title: "Cancel", kind: .quiet) { m.leaveNote { } }
            } else {
                BButton(title: "Edit", kind: .quiet) { m.beginEdit(n) }
                Menu {
                    Button(m.pinnedNotes.contains(n.relativePath) ? "Unpin" : "Pin to the rail") { m.togglePin(n.relativePath) }
                    Button("Ask about \(n.title)") { m.leaveNote { m.askAbout(n.title) } }
                    if obsidian { Button("Open in Obsidian") { m.openInObsidian(n.relativePath) } }
                    Button("Show in Finder") { m.showInFinder(n.relativePath) }
                    Divider()
                    Button("Delete…", role: .destructive) { prompt = .delete(n) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(t.ink2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            }
        }
        if isPerson(n) { PersonHeader(note: n, person: m.people.first { $0.notePath == n.relativePath }, exchange: exchange, obsidian: obsidian) }
        // `updated` is the day the note's substance last changed (its front-matter), never the file's mtime: the nightly block rewrite and iCloud do not move it.
        Text(NoteFacts.metaLine(n)).font(.system(size: 12)).foregroundStyle(t.ink2)
        if editing {
            Text("What you see is the prose. Brownie keeps the front-matter and the “Between you” block on the file; both go back on save.").font(.system(size: 11)).foregroundStyle(t.ink2)
            if let s = session, case .changedOnDisk = s.check(onDisk: NoteEdit.forEditing(n.body)) {
                HStack(spacing: 8) { Image(systemName: "exclamationmark.triangle").foregroundStyle(t.accentInk); Text("This note changed on disk while you were editing — from the phone, the night's run or someone at home. Save will ask which words stay.").font(.system(size: 12)) }
            }
            editor
        } else {
            NoteBody(blocks: NoteBlocks.parse(n.body), links: links)
        }
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Mentioned in").padding(.top, 8)
                ForEach(backlinks) { b in
                    Button { open(b.relativePath) } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.turn.up.left").font(.system(size: 11)).foregroundStyle(t.ink2); Text(b.title).foregroundStyle(t.accentInk); Text(b.folder.isEmpty ? "Home" : b.folder).font(.system(size: 11)).foregroundStyle(t.ink2) }
                    }.buttonStyle(.plain)
                }
            }
        }
        CardBox(padding: 12) { HStack(spacing: 10) { Image(systemName: "lock").foregroundStyle(t.ink2); Text("Anything you delete here is gone from the knowledge base for good.").font(.system(size: 11)).foregroundStyle(t.ink2) } }
    }

    /// The note went while it was being edited — deleted, renamed, moved by hand. The words typed are still here:
    /// they can go back as a copy at the path the note had, or be let go.
    @ViewBuilder func gonePane(_ s: EditSession) -> some View {
        HStack(spacing: 8) {
            Text(EditSession.title(of: s.draft, path: s.path)).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1)
            Spacer()
            BButton(title: "Save a copy", kind: .primary) { if let live = m.noteEditor.session { m.saveCopy(live) } }
            BButton(title: "Discard", kind: .quiet) { m.endEdit() }
        }
        Text("This note isn't on disk any more — it was deleted, renamed or moved while you were editing. Your words are still here: save them as a copy, or let them go.").font(.system(size: 12)).foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
        editor
    }
    var editor: some View {
        TextEditor(text: draft).font(.system(size: 13, design: .monospaced)).frame(minHeight: 400).scrollContentBackground(.hidden).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
    }

    // MARK: saving and deleting

    /// Save: the draft goes back when the file still says what the editor opened on. If it changed underneath — the
    /// phone's edit at the quarter-hour sync, the night's run, someone at home — the conflict sheet asks which words
    /// stay rather than writing over them. `then` runs once the words are safe (a move away that asked to save first).
    func save(then: (() -> Void)? = nil) {
        guard let s = session else { return }
        afterSave = then
        guard let n = m.note(at: s.path) else { m.saveCopy(s, then: finishSave); return }
        switch s.check(onDisk: NoteEdit.forEditing(n.body)) {
        case .clean, .gone: m.saveEdit(prose: s.draft, over: n, then: finishSave)
        case .changedOnDisk: prompt = .conflict(n)
        }
    }
    func finishSave() { let go = afterSave; afterSave = nil; go?() }
    func keepMine(_ n: Note) { prompt = nil; if let s = session { m.saveEdit(prose: s.draft, over: n, then: finishSave) } }
    func keepTheirs() { prompt = nil; m.endEdit(); finishSave() }
    func keepBoth(_ n: Note) { prompt = nil; if let s = session { m.saveEdit(prose: EditSession.merge(theirs: NoteEdit.forEditing(n.body), mine: s.draft, at: Date()), over: n, then: finishSave) } }
    /// Delete, and only on success move on to the last note opened; a failure leaves the screen where it was, the model having said why.
    func delete(_ n: Note) {
        Task {
            guard await m.deleteNote(n), selection == .note(n.relativePath) else { return }
            selection = .none
            if let next = m.recentNotes.paths.first(where: { m.note(at: $0) != nil }) { selection = .note(next) }
        }
    }
}

/// The toolbar's search box: answers appear in the rail as you type; ↓ and ↑ walk them, Return opens the one under
/// the bar, Escape clears the box — the keys the ⌘K palette answers to.
struct SearchField: View {
    @Environment(\.theme) var t
    @Binding var query: String
    @Binding var index: Int
    let count: Int
    let open: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(t.ink2)
            TextField("Search notes", text: $query).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(open)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.ink3) }.buttonStyle(.plain) }
        }.padding(.horizontal, 8).frame(width: 220, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(t.ctl)).overlay(RoundedRectangle(cornerRadius: 6).stroke(t.cardBorder, lineWidth: 1))
        .onKeyPress(.downArrow) { guard count > 0 else { return .ignored }; index = min(index + 1, count - 1); return .handled }
        .onKeyPress(.upArrow) { guard count > 0 else { return .ignored }; index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { guard !query.isEmpty else { return .ignored }; query = ""; return .handled }
        .onExitCommand { query = "" }
    }
}

/// A move away from an unsaved edit asks first.
struct LeaveSheet: View {
    @Environment(\.theme) var t
    let title: String
    let save: () -> Void, discard: () -> Void, keep: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save your changes to “\(title)”?").font(.system(size: 15, weight: .semibold))
            Text("You edited this note and haven't saved it. Leaving without saving lets those words go.").foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            HStack { BButton(title: "Discard", kind: .destructive, action: discard); Spacer(); BButton(title: "Keep editing", kind: .quiet, action: keep); BButton(title: "Save", kind: .primary, action: save) }
        }.padding(20).frame(width: 440)
    }
}

/// The file changed while the editor was open — the phone, the night's run, someone at home. Which words stay?
struct ConflictSheet: View {
    @Environment(\.theme) var t
    let note: Note
    let keepMine: () -> Void, keepTheirs: () -> Void, keepBoth: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This note changed while you were editing").font(.system(size: 15, weight: .semibold))
            Text("“\(note.title)” was changed on disk after you pressed Edit — from the phone, by last night's run, or by someone at home. Keep mine writes your version over it. Keep theirs lets your edit go. Keep both keeps the note as it is now with your edit under its own heading, for you to tidy later.").foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            HStack { BButton(title: "Keep theirs", kind: .quiet, action: keepTheirs); Spacer(); BButton(title: "Keep both", action: keepBoth); BButton(title: "Keep mine", kind: .primary, action: keepMine) }
        }.padding(20).frame(width: 460)
    }
}

/// The top of a person's or a group's note: who they are and where things stand, with the three things you do next.
struct PersonHeader: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let note: Note
    let person: Person?
    let exchange: (them: Date?, you: Date?)
    /// Whether Obsidian is on this Mac; without it the button is not offered.
    var obsidian = true
    var aliases: [String] { (note.meta.aliases + (person?.aliases ?? [])).filter { $0.lowercased() != note.title.lowercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    var openItems: Int { NoteBlocks.openItems(in: note.body) }
    var firstName: String { note.title.split(separator: " ").first.map(String.init) ?? note.title }
    func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d) }
    var body: some View {
        CardBox(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(note.title).font(.system(size: 22, weight: .semibold))
                    if !aliases.isEmpty { Text("also " + aliases.prefix(4).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(t.ink2).lineLimit(1) }
                }
                HStack(spacing: 8) {
                    Chip(text: openItems == 0 ? "nothing open" : "\(openItems) open", accent: openItems > 0)
                    if let d = exchange.them { Chip(text: "last from them \(day(d))") }
                    if let d = exchange.you { Chip(text: "last from you \(day(d))") }
                    if let q = NoteFacts.quietDays(note), q >= NoteFacts.quietAfter { Chip(text: "quiet for \(q) days") }
                }
                HStack(spacing: 8) {
                    BButton(title: "Ask about \(firstName)", systemImage: "bubble.left") { m.leaveNote { m.askAbout(note.title) } }
                    if let p = person, !p.handles.isEmpty { BButton(title: "Open the chat", systemImage: "message") { m.openChat(with: p) } }
                    if obsidian { BButton(title: "Open in Obsidian", kind: .quiet) { m.openInObsidian(note.relativePath) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Delete asks first, naming the note and where it lives in words — never the file's path.
struct DeleteSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    let note: Note
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(note.title)”?").font(.system(size: 15, weight: .semibold))
            Text("This note, \(NoteLists.placeWords(note.relativePath)), leaves the knowledge base for good. Brownie will not write it again from what it has already read.").foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); BButton(title: "Keep it", kind: .quiet) { dismiss() }; BButton(title: "Delete", kind: .destructive) { confirm(); dismiss() } }
        }.padding(20).frame(width: 400)
    }
}

/// ⌘K: any note by name, the recent ones first, Return opens.
struct QuickOpenPalette: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    var entries: [QuickOpen.Entry] { m.folders.flatMap { $0.notes.map { QuickOpen.Entry(path: $0.relativePath, title: $0.title) } } }
    var ranked: [QuickOpen.Entry] { QuickOpen.rank(query, entries: entries, recent: m.recentNotes.paths) }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { m.quickOpenShown = false }
            CardBox(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(t.ink2)
                        TextField("Open a note…", text: $query).textFieldStyle(.plain).font(.system(size: 15)).focused($focused).onSubmit { pick() }
                        Text("esc").font(.system(size: 11)).foregroundStyle(t.ink3)
                    }.padding(12)
                    Divider()
                    if ranked.isEmpty { Text(entries.isEmpty ? "No notes yet." : "Nothing called “\(query)”.").foregroundStyle(t.ink2).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                    VStack(spacing: 1) {
                        ForEach(Array(ranked.enumerated()), id: \.element.path) { i, e in
                            Button { open(e.path) } label: {
                                HStack { Text(e.title).lineLimit(1); Spacer(); Text(e.path.contains("/") ? String(e.path.split(separator: "/").first!) : "Home").font(.system(size: 11)).foregroundStyle(t.ink2) }
                                    .padding(.horizontal, 12).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(i == index ? t.ctl2 : .clear))
                            }.buttonStyle(.plain)
                        }
                    }.padding(6)
                }
            }.frame(width: 520).padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, ranked.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { m.quickOpenShown = false; return .handled }
        .background(Button("Close") { m.quickOpenShown = false }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false))
    }
    func pick() { if ranked.indices.contains(index) { open(ranked[index].path) } }
    func open(_ p: String) { m.quickOpenShown = false; m.openNote(p) }
}

// MARK: - Graph

struct GraphView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var selected: Note?
    var people: [Note] { m.folders.first { $0.name.lowercased() == "people" }?.notes ?? [] }
    var work: [Note] { m.folders.first { $0.name.lowercased() == "work" }?.notes ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Graph", subtitle: "People and threads from your notes") { EmptyView() }
            GeometryReader { geo in
                let nodes = layout(in: geo.size)
                ZStack {
                    RadialGradient(colors: [t.accentSoft, .clear], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 500)
                    Canvas { ctx, _ in
                        for n in nodes { var p = Path(); p.move(to: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)); p.addLine(to: n.point); ctx.stroke(p, with: .color(t.sep), lineWidth: 1.5) }
                        // co-mention edges: A's title appears in B's note or vice versa
                        for (i, a) in nodes.enumerated() { for b in nodes[(i + 1)...] where mentions(a.note, b.note) || mentions(b.note, a.note) {
                            var p = Path(); p.move(to: a.point); p.addLine(to: b.point); ctx.stroke(p, with: .color(t.accent.opacity(0.45)), lineWidth: 1.5)
                        } }
                    }
                    ZStack { Circle().fill(t.accent).frame(width: 68, height: 68); Text("You").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x1A1205)) }.position(x: geo.size.width / 2, y: geo.size.height / 2)
                    ForEach(nodes, id: \.note.relativePath) { n in
                        VStack(spacing: 4) {
                            Circle().fill(t.card).overlay(Circle().stroke(selected?.relativePath == n.note.relativePath ? t.accent : t.cardBorder, lineWidth: selected?.relativePath == n.note.relativePath ? 3 : 1)).frame(width: n.size, height: n.size)
                            Text(n.note.title).font(.system(size: 12)).lineLimit(1)
                        }.position(n.point).onTapGesture { selected = n.note; m.markWalkthrough("graph") }.walkthroughTarget(n.note.relativePath == nodes.first?.note.relativePath ? "graph" : nil)
                    }
                    if nodes.isEmpty { Text("No people or projects in your notes yet.").foregroundStyle(t.ink2) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let s = selected {
                        CardBox(padding: 14) { VStack(alignment: .leading, spacing: 6) { Text(s.title).fontWeight(.semibold); Text("\(mentionCount(s)) mentions across your notes").font(.system(size: 11)).foregroundStyle(t.ink2); Text(String(s.body.prefix(280))).font(.system(size: 12.5)); BButton(title: "Open note", kind: .quiet) { m.openNote(s.relativePath) } }.frame(width: 260, alignment: .leading) }.padding(24)
                    }
                }
            }
        }
    }

    struct NodeLayout { let note: Note; let point: CGPoint; let size: CGFloat }
    func mentions(_ a: Note, _ b: Note) -> Bool {
        let key = a.title.split(separator: " ").first.map(String.init) ?? a.title
        return key.count >= 3 && b.body.localizedCaseInsensitiveContains(key)
    }
    /// How often a node's name shows up across every note — the graph's "how much comes up" measure.
    func mentionCount(_ n: Note) -> Int {
        let key = n.title.split(separator: " ").first.map(String.init) ?? n.title
        guard key.count >= 3 else { return 0 }
        return m.folders.flatMap(\.notes).reduce(0) { $0 + $1.body.components(separatedBy: key).count - 1 }
    }
    func layout(in size: CGSize) -> [NodeLayout] {
        let all = (people + work).sorted { mentionCount($0) > mentionCount($1) }.prefix(14)
        let n = all.count; guard n > 0 else { return [] }
        let r = min(size.width, size.height) * 0.36
        return all.enumerated().map { i, note in
            let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
            let rr = r * (i % 2 == 0 ? 1 : 0.72)
            return NodeLayout(note: note, point: CGPoint(x: size.width / 2 + cos(a) * rr, y: size.height / 2 + sin(a) * rr), size: CGFloat(28 + min(36, mentionCount(note) * 3)))
        }
    }
}

// MARK: - Excluded

struct ExcludedView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var window = "Last night"
    var rows: [DropRecord] { window == "Last night" ? m.drops.filter { $0.runID == m.lastRun?.id } : m.drops }
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Excluded", subtitle: "What Brownie chose not to keep, and why. The content itself is gone.") {
                Segmented(options: ["Last night", "7 days"], selection: $window).walkthroughTarget("excluded").onChange(of: window) { _, _ in m.markWalkthrough("excluded") }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        // A bad-dated item never reached the reader, so it is not something the reader judged unworthy.
                        stat("Not worth keeping", rows.filter { $0.reason.verdict == .drop && ![.loadFailed, .readerFailed, .badDate].contains($0.reason) }.count, "Banter, logistics, installers, duplicates", t.ink)
                        stat("Sensitive · erased on sight", rows.filter { $0.reason.verdict == .sensitive }.count, "Model \(rows.filter { $0.reason == .modelSensitive }.count) · pattern match \(rows.filter { $0.reason == .piiBackstop }.count)", t.bad)
                        stat("Couldn't read", rows.filter { [.loadFailed, .readerFailed, .parseFailed, .badDate].contains($0.reason) }.count, "Load or model errors, dates that can't be believed", t.ink)
                    }
                    CardBox(padding: 0) {
                        VStack(spacing: 0) {
                            HStack { th("Time", 90); th("Source", 160); th("Kind", 150); th("Reason", 0) }.padding(.horizontal, 12).frame(height: 32)
                            Divider()
                            if rows.isEmpty { Text("Nothing excluded in this window.").foregroundStyle(t.ink2).padding(20) }
                            ForEach(rows.prefix(200)) { d in
                                HStack { td(d.at.formatted(date: .omitted, time: .shortened), 90); td("\(d.source.rawValue) · \(d.bucketName)", 160); Text(kind(d.reason)).foregroundStyle(d.reason.verdict == .sensitive ? t.bad : t.ink).fontWeight(d.reason.verdict == .sensitive ? .medium : .regular).frame(width: 150, alignment: .leading); td(reason(d.reason), 0) }
                                    .font(.system(size: 12.5)).padding(.horizontal, 12).frame(height: 34)
                                Divider()
                            }
                        }
                    }
                    Text("The log records the decision, never the content.").font(.system(size: 11)).foregroundStyle(t.ink2)
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            }
        }
    }
    func th(_ s: String, _ w: CGFloat) -> some View { Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink2).frame(width: w == 0 ? nil : w, alignment: .leading).frame(maxWidth: w == 0 ? .infinity : nil, alignment: .leading) }
    func td(_ s: String, _ w: CGFloat) -> some View { Text(s).lineLimit(1).frame(width: w == 0 ? nil : w, alignment: .leading).frame(maxWidth: w == 0 ? .infinity : nil, alignment: .leading) }
    func stat(_ l: String, _ n: Int, _ sub: String, _ c: Color) -> some View { CardBox(padding: 14) { VStack(alignment: .leading, spacing: 2) { Text(l).font(.system(size: 11)).foregroundStyle(t.ink2); Text("\(n)").font(.system(size: 22, weight: .semibold)).foregroundStyle(c); Text(sub).font(.system(size: 11)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity, alignment: .leading) } }
    func kind(_ r: VerdictReason) -> String { switch r.verdict { case .sensitive: return "Sensitive"; case .drop: return r == .loadFailed || r == .readerFailed || r == .parseFailed ? "Couldn't read" : "Not worth keeping"; case .keep: return "Kept" } }
    func reason(_ r: VerdictReason) -> String {
        switch r { case .modelDrop: return "The reader judged it not vault-worthy"; case .emptySummary: return "Nothing to say about it"; case .parseFailed: return "The reader's reply couldn't be read (dropped, fail-closed)"
        case .modelSensitive: return "The reader flagged it sensitive"; case .piiBackstop: return "Matched an ID / card / account pattern"; case .loadFailed: return "The item couldn't be opened"; case .readerFailed: return "The reader errored"; case .badDate: return "Dated years ahead or too far back to be believed"; case .kept: return "" }
    }
}

