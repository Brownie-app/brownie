import SwiftUI
import AppKit
import Domain

struct KnowledgeView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var selectedFolder: String?
    @State private var selectedNote: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var query = ""
    @State private var results: [Note] = []

    var folder: KnowledgeFolder? { m.folders.first { $0.name == selectedFolder } ?? m.folders.first }
    var note: Note? { folder?.notes.first { $0.relativePath == selectedNote } ?? folder?.notes.first }

    func jump(to path: String) {
        guard let f = m.folders.first(where: { $0.notes.contains { $0.relativePath == path } }) else { return }
        selectedFolder = f.name; selectedNote = path; editing = false; query = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Knowledge", subtitle: m.folders.isEmpty ? "Nothing yet · notes appear after the first run with a brain" : "\(m.folders.reduce(0) { $0 + $1.notes.count }) notes · plain Markdown in ~/Brownie Knowledge Base") {
                TextField("Search notes", text: $query).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit { Task { results = (try? await m.knowledge.search(query, limit: 20)) ?? [] } }
                BButton(title: "Open in Finder") { NSWorkspace.shared.open(m.knowledge.rootURL) }
            }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if !query.isEmpty && !results.isEmpty {
                            Eyebrow(text: "Results").padding(10)
                            ForEach(results) { n in rail(n.title, sub: n.relativePath, on: selectedNote == n.relativePath) { selectedFolder = n.folder.isEmpty ? "Home" : n.folder; selectedNote = n.relativePath; editing = false } }
                        }
                        ForEach(m.folders) { f in
                            rail(f.name, sub: "\(f.notes.count)", on: folder?.name == f.name, icon: "folder") { selectedFolder = f.name; selectedNote = f.notes.first?.relativePath; editing = false; m.markWalkthrough("knowledge") }
                            if folder?.name == f.name {
                                ForEach(f.notes) { n in rail(n.title, sub: "", on: note?.relativePath == n.relativePath, indent: true) { selectedNote = n.relativePath; editing = false } }
                            }
                        }
                    }.padding(8)
                }.frame(width: 260).overlay(alignment: .trailing) { Rectangle().fill(t.sep).frame(width: 1) }.walkthroughTarget("knowledge")
                ScrollView {
                    if let n = note {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("\(folder?.name ?? "") / \(n.title)").font(.system(size: 11)).foregroundStyle(t.ink2); Spacer()
                                if n.userEdited { Chip(text: "edited by you") }
                                if editing { BButton(title: "Save", kind: .primary) { save(n) }; BButton(title: "Cancel", kind: .quiet) { editing = false } }
                                else { BButton(title: "Edit", kind: .quiet) { draft = n.body; editing = true }; BButton(title: "Delete", kind: .destructive) { Task { try? await m.knowledge.delete(relativePath: n.relativePath); await m.reload() } } } }
                            Text("Sources: \(n.sources.joined(separator: ", ")) · updated \(n.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(t.ink2)
                            if editing { TextEditor(text: $draft).font(.system(size: 13, design: .monospaced)).frame(minHeight: 400).scrollContentBackground(.hidden).background(t.code).cornerRadius(6) }
                            else { WikiText(body: n.body) }
                            CardBox(padding: 12) { HStack(spacing: 10) { Image(systemName: "lock").foregroundStyle(t.ink2); Text("Anything you delete here is gone from the knowledge base for good.").font(.system(size: 11)).foregroundStyle(t.ink2) } }
                        }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 8) { Text("No notes yet").font(.system(size: 17, weight: .semibold)); Text("Run an analysis with a brain configured and your knowledge base appears here as plain Markdown files.").foregroundStyle(t.ink2) }.padding(40)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)   // the note pane takes the rest; the rail stays flush left
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if let p = m.pendingNote { jump(to: p); m.pendingNote = nil } }
        .onChange(of: m.pendingNote) { _, p in if let p { jump(to: p); m.pendingNote = nil } }
    }

    func rail(_ title: String, sub: String, on: Bool, icon: String? = nil, indent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(t.ink2) }; Text(title).lineLimit(1).fontWeight(on ? .medium : .regular); Spacer(); if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) } }
                .padding(.horizontal, 10).padding(.leading, indent ? 14 : 0).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(on ? t.ctl2 : .clear))
        }.buttonStyle(.plain)
    }

    func save(_ n: Note) {
        let updated = Note(relativePath: n.relativePath, title: n.title, body: draft, sources: n.sources, updatedAt: Date(), userEdited: true)
        Task { try? await m.knowledge.save(updated); await m.reload(); editing = false }
    }
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
                        stat("Not worth keeping", rows.filter { $0.reason.verdict == .drop && $0.reason != .loadFailed && $0.reason != .readerFailed }.count, "Banter, logistics, installers, duplicates", t.ink)
                        stat("Sensitive · erased on sight", rows.filter { $0.reason.verdict == .sensitive }.count, "Model \(rows.filter { $0.reason == .modelSensitive }.count) · pattern match \(rows.filter { $0.reason == .piiBackstop }.count)", t.bad)
                        stat("Couldn't read", rows.filter { $0.reason == .loadFailed || $0.reason == .readerFailed || $0.reason == .parseFailed }.count, "Load or model errors", t.ink)
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


/// The note body with `[[Name]]` rendered as links to the note of that name (grey when it doesn't exist yet).
struct WikiText: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let text: String
    init(body: String) { text = body }
    var pieces: [(String, Bool)] {
        var out: [(String, Bool)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            out.append((String(rest[..<open.lowerBound]), false))
            out.append((String(rest[open.upperBound..<close.lowerBound]), true))
            rest = rest[close.upperBound...]
        }
        out.append((String(rest), false))
        return out
    }
    var body: some View {
        // One Text with attributed runs keeps selection and wrapping; links become buttons via the openURL handler.
        Text(attributed).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "brownie-note", let name = url.host?.removingPercentEncoding ?? url.path.dropFirst().removingPercentEncoding else { return .systemAction }
                if let p = m.notePath(named: name) { m.openNote(p) } else { m.announcement = "No note called “\(name)” yet." }
                return .handled
            })
    }
    var attributed: AttributedString {
        var a = AttributedString()
        for (piece, isLink) in pieces {
            var run = AttributedString(piece)
            if isLink {
                let exists = m.notePath(named: piece) != nil
                run.foregroundColor = exists ? t.accentInk : t.ink2
                run.underlineStyle = .single
                if let u = URL(string: "brownie-note://" + (piece.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "")) { run.link = u }
            }
            a += run
        }
        return a
    }
}
