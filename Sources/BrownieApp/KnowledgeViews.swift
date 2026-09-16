import SwiftUI
import AppKit
import Domain
import Knowledge

/// Notes, made for a person at 7:30 in the morning: the body drawn (not raw Markdown), search that answers as
/// you type, a rail that remembers what you opened and what you pinned, a header on a person's note that says
/// where things stand, and an editor that never loses what Brownie keeps on the file.
struct KnowledgeView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    enum Selection: Equatable { case none, today, note(String) }
    @State private var selection: Selection = .none
    @State private var editing = false
    @State private var draft = ""
    @State private var query = ""
    @State private var results: FileKnowledgeStore.SearchResults?
    @State private var searchTask: Task<Void, Never>?
    @State private var expanded: Set<String> = Set((UserDefaults.standard.string(forKey: "notes.expanded") ?? "").split(separator: "\n").map(String.init))
    @State private var archivesOpen: Set<String> = []
    @State private var confirmDelete: Note?
    @State private var backlinks: [Note] = []
    @State private var exchange: (them: Date?, you: Date?) = (nil, nil)

    var links: LinkIndex { LinkIndex(folders: m.folders) }
    var note: Note? { if case .note(let p) = selection { return m.note(at: p) }; return nil }
    var notePath: String? { note?.relativePath }
    var noteCount: Int { m.folders.reduce(0) { $0 + $1.notes.count } }
    var subtitle: String { m.folders.isEmpty ? "Nothing yet · notes appear after the first run with a brain" : "\(noteCount) notes · plain Markdown in ~/Brownie Knowledge Base" }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Notes", subtitle: subtitle) {
                if let h = m.vaultHealth {
                    Button { m.openSettings(.knowledge) } label: { Chip(text: h.line) }.buttonStyle(.plain).help("Last night's measure of the vault — opens Settings → Knowledge")
                }
                SearchField(query: $query)
                BButton(title: "⌘K", kind: .quiet) { m.quickOpenShown = true }.help("Quick open: any note by name")
                BButton(title: "Open in Obsidian", kind: .quiet, systemImage: "arrow.up.forward.app") { m.openInObsidian(notePath) }
                BButton(title: "Show in Finder", kind: .quiet) { m.showInFinder(notePath) }
            }
            HStack(spacing: 0) {
                rail.frame(width: 260).overlay(alignment: .trailing) { Rectangle().fill(t.sep).frame(width: 1) }.walkthroughTarget("knowledge")
                content.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { arrive() }
        .onChange(of: m.pendingNote) { _, p in if p != nil { arrive() } }
        .onChange(of: query) { _, q in search(q) }
        .onChange(of: selection) { _, _ in loadSide() }
        .onChange(of: m.folders) { _, _ in loadSide() }
        .onChange(of: expanded) { _, e in UserDefaults.standard.set(e.sorted().joined(separator: "\n"), forKey: "notes.expanded") }
        .sheet(item: $confirmDelete) { n in DeleteSheet(note: n) { delete(n) } }
    }

    // MARK: arriving and opening

    /// A note asked for from elsewhere (Graph, a card, a link) — or, first time here, the last one opened.
    func arrive() {
        if let p = m.pendingNote {
            m.pendingNote = nil
            if m.note(at: p) != nil { open(p) } else { m.announcement = "That note isn't there any more."; m.noteGone(p) }
            return
        }
        guard selection == .none else { return }
        if let p = m.recentNotes.paths.first(where: { m.note(at: $0) != nil }) { open(p) }
        else if let p = m.folders.first?.notes.first?.relativePath { open(p) }
    }
    func open(_ path: String) {
        selection = .note(path); editing = false
        m.noteOpened(path)
        if let f = m.note(at: path)?.folder, !f.isEmpty { expanded.insert(f) }
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

    // MARK: the rail

    var pinned: [Note] { m.pinnedNotes.paths.compactMap { m.note(at: $0) } }
    var recent: [Note] { m.recentNotes.paths.compactMap { m.note(at: $0) } }

    var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let r = results {
                    Text(r.total == 0 ? "No matches for “\(r.query)”" : "\(r.total) match\(r.total == 1 ? "" : "es")").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink2).padding(10)
                    ForEach(r.hits) { h in hitRow(h) }
                    if r.total > r.hits.count { Text("Showing \(r.hits.count) of \(r.total) — add a word to narrow it").font(.system(size: 11)).foregroundStyle(t.ink2).padding(10) }
                } else {
                    row("Today", sub: m.todayOpenCount > 0 ? "\(m.todayOpenCount)" : "", on: selection == .today, icon: "sun.max") { selection = .today; editing = false }
                    if !pinned.isEmpty {
                        Eyebrow(text: "Pinned").padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
                        ForEach(pinned) { n in noteRow(n, icon: "pin") }
                    }
                    if !recent.isEmpty {
                        Eyebrow(text: "Recent").padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
                        ForEach(recent) { n in noteRow(n, icon: "clock") }
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

    func noteRow(_ n: Note, icon: String? = nil, indent: Int = 0, muted: Bool = false) -> some View {
        row(n.title, sub: "", on: selection == .note(n.relativePath), icon: icon, indent: indent, muted: muted) { open(n.relativePath) }
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
    func hitRow(_ h: FileKnowledgeStore.SearchHit) -> some View {
        Button { open(h.note.relativePath) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(h.note.title).lineLimit(1).fontWeight(selection == .note(h.note.relativePath) ? .medium : .regular); Spacer(); Text(h.note.folder.isEmpty ? "Home" : h.note.folder).font(.system(size: 11)).foregroundStyle(t.ink2) }
                Text(NoteMarkdown.highlighted(h.snippet, theme: t)).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(selection == .note(h.note.relativePath) ? t.ctl2 : .clear))
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
                    else { VStack(alignment: .leading, spacing: 8) { Text("That note isn't there any more.").font(.system(size: 15, weight: .semibold)); Text("It was deleted, renamed or archived since it was opened. Pick another from the rail.").foregroundStyle(t.ink2) }.padding(.top, 20) }
                case .none:
                    VStack(alignment: .leading, spacing: 8) { Text("No notes yet").font(.system(size: 17, weight: .semibold)); Text("Run an analysis with a brain configured and your knowledge base appears here as plain Markdown files.").foregroundStyle(t.ink2) }.padding(.top, 20)
                }
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var todayPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoteBody(blocks: NoteBlocks.parse(m.todayMarkdown), links: links, onTick: { m.tickToday(cardID: $0) })
            Text("A tick here does what a tick on the phone does: the card is marked done. Sending, paying and deleting stay yours.").font(.system(size: 11)).foregroundStyle(t.ink2)
        }
    }

    @ViewBuilder func notePane(_ n: Note) -> some View {
        HStack(spacing: 8) {
            Text("\(n.folder.isEmpty ? "Home" : n.folder) / \(n.title)").font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1)
            Spacer()
            if n.userEdited { Chip(text: "edited by you") }
            if m.pinnedNotes.contains(n.relativePath) { Chip(text: "pinned", accent: true) }
            if editing {
                BButton(title: "Save", kind: .primary) { save(n) }
                BButton(title: "Cancel", kind: .quiet) { editing = false }
            } else {
                BButton(title: "Edit", kind: .quiet) { draft = NoteEdit.forEditing(n.body); editing = true }
                Menu {
                    Button(m.pinnedNotes.contains(n.relativePath) ? "Unpin" : "Pin to the rail") { m.togglePin(n.relativePath) }
                    Button("Ask about \(n.title)") { m.askAbout(n.title) }
                    Button("Open in Obsidian") { m.openInObsidian(n.relativePath) }
                    Button("Show in Finder") { m.showInFinder(n.relativePath) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = n }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(t.ink2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            }
        }
        if isPerson(n) { PersonHeader(note: n, person: m.people.first { $0.notePath == n.relativePath }, exchange: exchange) }
        // `updated` is the day the note's substance last changed (its front-matter), never the file's mtime: the nightly block rewrite and iCloud do not move it.
        Text(NoteFacts.metaLine(n)).font(.system(size: 12)).foregroundStyle(t.ink2)
        if editing {
            Text("What you see is the prose. Brownie keeps the front-matter and the “Between you” block on the file; both go back on save.").font(.system(size: 11)).foregroundStyle(t.ink2)
            TextEditor(text: $draft).font(.system(size: 13, design: .monospaced)).frame(minHeight: 400).scrollContentBackground(.hidden).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
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

    /// The edited prose goes back under the note's own front-matter with its status block put back exactly.
    func save(_ n: Note) {
        let body = NoteEdit.reattach(edited: draft, original: n.body)
        let updated = Note(relativePath: n.relativePath, title: n.title, body: body, sources: n.sources, updatedAt: Date(), userEdited: true)
        Task { try? await m.knowledge.save(updated); await m.reload(); editing = false }
    }
    func delete(_ n: Note) {
        let p = n.relativePath
        Task {
            try? await m.knowledge.delete(relativePath: p)
            m.noteGone(p); selection = .none
            await m.reload()
            if let next = m.recentNotes.paths.first(where: { m.note(at: $0) != nil }) { selection = .note(next) }
        }
    }
}

/// The toolbar's search box: answers appear in the rail as you type.
struct SearchField: View {
    @Environment(\.theme) var t
    @Binding var query: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(t.ink2)
            TextField("Search notes", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.ink3) }.buttonStyle(.plain) }
        }.padding(.horizontal, 8).frame(width: 220, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(t.ctl)).overlay(RoundedRectangle(cornerRadius: 6).stroke(t.cardBorder, lineWidth: 1))
    }
}

/// The top of a person's or a group's note: who they are and where things stand, with the three things you do next.
struct PersonHeader: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let note: Note
    let person: Person?
    let exchange: (them: Date?, you: Date?)
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
                    BButton(title: "Ask about \(firstName)", systemImage: "bubble.left") { m.askAbout(note.title) }
                    if let p = person, !p.handles.isEmpty { BButton(title: "Open the chat", systemImage: "message") { m.openChat(with: p) } }
                    BButton(title: "Open in Obsidian", kind: .quiet) { m.openInObsidian(note.relativePath) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Delete asks first, naming the note.
struct DeleteSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    let note: Note
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(note.title)”?").font(.system(size: 15, weight: .semibold))
            Text("\(note.relativePath) leaves the knowledge base for good. Brownie will not write it again from what it has already read.").foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
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

