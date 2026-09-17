import SwiftUI
import Domain
import Knowledge

/// A note drawn, not shown raw: `NoteBlocks` parses, the pure functions here turn the inlines into attributed runs
/// (links resolved, missing ones muted), and the view lays the blocks out. The status block is its own card.
enum NoteMarkdown {
    static let scheme = "brownie-note"

    /// The link a wikilink becomes, so one openURL handler serves every note: `brownie-note://open?path=People/Meera.md&heading=Open`.
    static func url(path: String, heading: String?) -> URL? {
        var c = URLComponents(); c.scheme = scheme; c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)] + (heading.map { [URLQueryItem(name: "heading", value: $0)] } ?? [])
        return c.url
    }
    static func path(from url: URL) -> String? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == "path" }?.value
    }

    /// The runs of one line. `missing` names the wikilinks no note answers to, for the tooltip.
    static func attributed(_ inlines: [NoteBlocks.Inline], theme t: Theme, links: LinkIndex) -> (text: AttributedString, missing: [String]) {
        var a = AttributedString(), missing: [String] = []
        for i in inlines {
            var run: AttributedString
            switch i {
            case .text(let s): run = AttributedString(s)
            case .bold(let s): run = AttributedString(s); run.font = .system(size: 14, weight: .semibold)
            case .italic(let s): run = AttributedString(s); run.font = .system(size: 14).italic()
            case .code(let s): run = AttributedString(s); run.font = .system(size: 12.5, design: .monospaced); run.backgroundColor = t.code
            case .url(let label, let u):
                run = AttributedString(label); run.foregroundColor = t.accentInk; run.underlineStyle = .single
                if let url = URL(string: u) { run.link = url }
            case .wikilink(let target, let heading, let label):
                run = AttributedString(label); run.underlineStyle = .single
                if let p = links.path(for: target), let url = url(path: p, heading: heading) { run.foregroundColor = t.accentInk; run.link = url }
                else { run.foregroundColor = t.ink3; missing.append(target) }
            }
            a += run
        }
        return (a, missing)
    }

    /// A search snippet with the matched words (between the store's markers) set off from the rest.
    static func highlighted(_ snippet: String, theme t: Theme) -> AttributedString {
        var a = AttributedString()
        let parts = snippet.components(separatedBy: FileKnowledgeStore.SearchHit.mark)
        for (i, part) in parts.enumerated() {
            if i == 0 { a += AttributedString(part); continue }
            let halves = part.components(separatedBy: FileKnowledgeStore.SearchHit.unmark)
            var hit = AttributedString(halves[0]); hit.font = .system(size: 11, weight: .semibold); hit.foregroundColor = t.accentInk; hit.backgroundColor = t.accentSoft
            a += hit
            a += AttributedString(halves.dropFirst().joined(separator: FileKnowledgeStore.SearchHit.unmark))
        }
        return a
    }

}

/// The blocks, drawn. `onTick` makes the checkboxes live (Today); without it they are read-only.
struct NoteBody: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let blocks: [NoteBlocks.Block]
    let links: LinkIndex
    var onTick: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let p = NoteMarkdown.path(from: url) else { return .systemAction }
            // A link to a note the gardener has since archived still opens it; the screen says where it went.
            if m.currentPath(p) != nil { m.openNote(p) } else { m.announcement = "That note isn't there any more." }
            return .handled
        })
    }

    @ViewBuilder func block(_ b: NoteBlocks.Block) -> some View {
        switch b {
        case .heading(let level, let inlines):
            line(inlines).font(.system(size: level == 1 ? 22 : (level == 2 ? 16 : 14), weight: .semibold)).padding(.top, level == 1 ? 0 : 8)
        case .paragraph(let inlines):
            line(inlines)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text(it.ordinal.map { "\($0)." } ?? "•").foregroundStyle(t.ink2).frame(width: 16, alignment: .trailing)
                        line(it.inlines)
                    }.padding(.leading, CGFloat(it.indent) * 16)
                }
            }
        case .checklist(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Button { if let id = it.cardID { onTick?(id) } } label: {
                            Image(systemName: it.checked ? "checkmark.square.fill" : "square").font(.system(size: 15)).foregroundStyle(it.checked ? t.ok : (onTick != nil && it.cardID != nil ? t.accentInk : t.ink2))
                        }.buttonStyle(.plain).disabled(onTick == nil || it.cardID == nil || it.checked).help(onTick != nil && it.cardID != nil && !it.checked ? "Tick to mark the card done" : "")
                        line(it.inlines).strikethrough(it.checked).foregroundStyle(it.checked ? t.ink2 : t.ink)
                    }
                }
            }
        case .quote(let inlines):
            HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 1).fill(t.accent).frame(width: 3); line(inlines).foregroundStyle(t.ink2) }.padding(.vertical, 2)
        case .code(let s):
            Text(s).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
        case .rule:
            Rectangle().fill(t.sep).frame(height: 1).padding(.vertical, 4)
        case .status(let lines):
            StatusCard(lines: lines, links: links)
        }
    }

    func line(_ inlines: [NoteBlocks.Inline]) -> some View {
        let (text, missing) = NoteMarkdown.attributed(inlines, theme: t, links: links)
        return Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .help(missing.isEmpty ? "" : "No note yet for " + missing.joined(separator: ", "))
    }
}

/// The status block as the "Between you" card: what they asked, what was promised, what is still open. Each line is
/// drawn through the same inline renderer as the body, so "_(not checked)_" reads as italic, never as underscores.
struct StatusCard: View {
    @Environment(\.theme) var t
    let lines: [String]
    let links: LinkIndex
    var body: some View {
        CardBox(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Eyebrow(text: "Between you"); Spacer(); Text("kept by Brownie from the chats and the loops ledger").font(.system(size: 11)).foregroundStyle(t.ink3) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    let (icon, rest) = Self.split(l)
                    HStack(alignment: .top, spacing: 8) {
                        Text(icon).font(.system(size: 14)).frame(width: 18)
                        Text(NoteMarkdown.attributed(NoteBlocks.inlines(rest), theme: t, links: links).text).font(.system(size: 14)).foregroundStyle(icon == "⏳" ? t.ink : t.ink2).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    static func split(_ line: String) -> (String, String) {
        for icon in ["⏳", "✅", "⌛"] where line.hasPrefix(icon) { return (icon, String(line.dropFirst(icon.count)).trimmingCharacters(in: .whitespaces)) }
        return ("·", line)
    }
}
