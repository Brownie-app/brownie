import SwiftUI
import AppKit
import Domain
import Brain
import Agent
import Proactive

// MARK: - Loops

struct LoopsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var tab = "You owe"
    var shown: [Loop] {
        switch tab {
        case "You owe": return m.loops.filter { $0.status == .open && $0.direction == .mine }.sorted { $0.openedAt < $1.openedAt }
        case "Owed to you": return m.loops.filter { $0.status == .open && $0.direction == .theirs }.sorted { $0.openedAt < $1.openedAt }
        default: return m.loops.filter { $0.status != .open }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        }
    }
    var body: some View {
        let mine = m.loops.filter { $0.status == .open && $0.direction == .mine }.count
        let theirs = m.loops.filter { $0.status == .open && $0.direction == .theirs }.count
        let closed = m.loops.filter { $0.status != .open }.count
        VStack(spacing: 0) {
            Toolbar(title: "Loops", subtitle: "Promises in both directions, found in your chats and mail") {
                Segmented(options: ["You owe", "Owed to you", "Closed"], selection: $tab)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        stat("You owe", "\(mine)", mine > 0 ? t.warn : t.ink2); stat("Owed to you", "\(theirs)", t.ink); stat("Closed", "\(closed)", t.ok)
                    }
                    if shown.isEmpty { EmptyLoops(tab: tab) }
                    else {
                        CardBox(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { i, l in
                                    LoopRow(loop: l).walkthroughTarget(i == 0 && l.status == .open ? "loops" : nil)
                                    if i < shown.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    CardBox(padding: 14) {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Nudge before a deadline").fontWeight(.semibold)
                                Text("When a loop has a date, a card appears ahead of it — even if nothing new was said. “Villa hold ends Tuesday” becomes a card on Monday morning.").font(.system(size: 11)).foregroundStyle(t.ink2)
                            }
                            Spacer()
                            Segmented(options: ["The morning before", "2 days before", "Only when asked"], selection: Binding(get: { m.nudgeDays == 1 ? "The morning before" : (m.nudgeDays == 2 ? "2 days before" : "Only when asked") }, set: { m.setNudgeDays($0.hasPrefix("The") ? 1 : ($0.hasPrefix("2") ? 2 : 0)) }))
                        }
                    }
                    CardBox(padding: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How a loop closes").fontWeight(.semibold)
                            Text("A loop opens when someone — you included — says they’ll do something. It closes when the next overnight read sees it done: a reply, a file sent, a “done”. If you fired a card and nothing changed by the next read, the card comes back with a gentler nudge.").font(.system(size: 11)).foregroundStyle(t.ink2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            }
        }
    }
    func stat(_ k: String, _ v: String, _ c: Color) -> some View {
        CardBox(padding: 14) { VStack(alignment: .leading, spacing: 2) { Text(k).font(.system(size: 11)).foregroundStyle(t.ink2); Text(v).font(.system(size: 22, weight: .semibold)).foregroundStyle(c) }.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct EmptyLoops: View {
    @Environment(\.theme) var t
    let tab: String
    var body: some View {
        CardBox(padding: 28) {
            VStack(spacing: 6) {
                Text(tab == "Closed" ? "Nothing closed yet" : "No open loops here").fontWeight(.semibold)
                Text(tab == "Closed" ? "Loops that get done show up here for 30 days." : "Loops are found during the overnight read. If your chats have promises in them, they’ll appear after the next run.").font(.system(size: 12)).foregroundStyle(t.ink2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
        }
    }
}

struct LoopRow: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let loop: Loop
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack { Circle().fill(t.ctl2).frame(width: 28, height: 28); Text(String(loop.person.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink2) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(loop.person).fontWeight(.semibold); Text("·").foregroundStyle(t.ink2); Text(loop.what).lineLimit(1) }
                Text("“\(loop.quote)” · \(loop.sourceLabel)").font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let d = loop.due { Text(d).font(.system(size: 12)).foregroundStyle(t.warn) }
                if let n = DueNudger.nudgeLine(for: loop, days: m.nudgeDays, now: Date()) { HStack(spacing: 4) { Image(systemName: "clock").font(.system(size: 9)); Text(n) }.font(.system(size: 10.5, weight: .medium)).foregroundStyle(t.accentInk).padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(t.accentSoft)) }
            }
            HStack(spacing: 6) {
                Circle().fill(loop.status == .open ? (loop.cameBackCount > 0 ? t.bad : t.warn) : t.ok).frame(width: 7, height: 7)
                Text(loop.status == .open ? (loop.cameBackCount > 0 ? "Came back" : "Open") : (loop.status == .closed ? "Done" : "Not a loop")).font(.system(size: 12, weight: .medium))
            }.frame(width: 90, alignment: .leading)
            if loop.status == .open {
                if m.nudging == loop.id { ProgressView().controlSize(.small) }
                else { BButton(title: m.cards.contains { $0.loopID == loop.id } ? "Open card" : "Nudge") { m.nudge(loop) } }
                Menu { Button("Mark done") { m.closeLoop(loop.id, how: "you marked it done") }; Button("Not a promise") { m.dismissLoop(loop.id) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            } else if let how = loop.closedHow { Text(how).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1).frame(width: 160, alignment: .trailing) }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - What left your Mac

struct SendLogView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var range = "Last night"
    @State private var open: Set<Int64> = []
    var rows: [SendRecord] {
        switch range {
        case "Last night": guard let r = m.lastRun else { return [] }; return m.sendLog.filter { $0.at >= r.startedAt.addingTimeInterval(-60) }
        case "This week": return m.sendLog.filter { $0.at >= Date().addingTimeInterval(-7 * 86400) }
        default: return m.sendLog
        }
    }
    var body: some View {
        let total = rows.reduce(0) { $0 + $1.bytes }
        VStack(spacing: 0) {
            Toolbar(title: "What left your Mac", subtitle: "Every request to the brain, byte for byte · kept 30 days") { Segmented(options: ["Last night", "This week", "All"], selection: $range) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        stat("Requests", "\(rows.count)", "to \(m.brainName)")
                        stat("Sent", total.formattedBytes, "summaries, note titles, your instructions")
                        stat("Raw messages, files, mail", "0 bytes", "never sent, by design", color: t.ok)
                        stat("Reader", "on this Mac", "did all the reading")
                    }
                    if rows.isEmpty {
                        CardBox(padding: 28) { VStack(spacing: 6) { Text(m.brainConfig.engine == .local ? "Nothing leaves — the brain is this Mac" : "Nothing sent yet").fontWeight(.semibold); Text("Requests appear here as the overnight run, nudges and briefs talk to the brain.").font(.system(size: 12)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity) }
                    } else {
                        CardBox(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                    SendRow(record: r, isOpen: open.contains(r.id)) { m.markWalkthrough("sendlog"); if open.contains(r.id) { open.remove(r.id) } else { open.insert(r.id) } }
                                        .walkthroughTarget(i == 0 ? "sendlog" : nil)
                                    if i < rows.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    CardBox(padding: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) { Text("Want nothing to leave at all?").fontWeight(.semibold); Text("Switch the brain to “This Mac only”. Cards get plainer and slower; this page reads 0 bytes, every night.").font(.system(size: 11)).foregroundStyle(t.ink2) }
                            Spacer(); BButton(title: "Brain settings") { m.openSettings(.brain) }
                        }
                    }
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            }
        }
    }
    func stat(_ k: String, _ v: String, _ d: String, color: Color? = nil) -> some View {
        CardBox(padding: 14) { VStack(alignment: .leading, spacing: 2) { Text(k).font(.system(size: 11)).foregroundStyle(t.ink2); Text(v).font(.system(size: 20, weight: .semibold)).foregroundStyle(color ?? t.ink).lineLimit(1); Text(d).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct SendRow: View {
    @Environment(\.theme) var t
    let record: SendRecord; let isOpen: Bool; let toggle: () -> Void
    static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Text(Self.tf.string(from: record.at)).font(.system(size: 12)).monospacedDigit().frame(width: 100, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) { Text(record.purpose).fontWeight(.semibold); Text(record.detail).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) }
                    Spacer()
                    Text(record.bytes.formattedBytes).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(record.cameBack).font(.system(size: 11)).foregroundStyle(t.ink2).frame(width: 150, alignment: .trailing).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(t.ink3).rotationEffect(.degrees(isOpen ? 90 : 0))
                }.padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView { Text(record.payload).font(.system(size: 11.5, design: .monospaced)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12) }
                        .frame(maxHeight: 320).background(RoundedRectangle(cornerRadius: 8).fill(t.code))
                    Text("This is the exact text, as sent. Anything that looks like a message here is a summary the reader wrote on this Mac — never the message itself.").font(.system(size: 11)).foregroundStyle(t.ink2)
                }.padding(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            }
        }
    }
}

// MARK: - The Sunday letter

struct WeeklyView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Your week", subtitle: m.weeklyWeek.map { "Week \($0.suffix(2)) · written on this Mac from your notes" } ?? "", back: { m.overlay = .none }) {
                if m.brain != nil { BButton(title: "Write it again", kind: .quiet) { m.writeWeeklyNow() } }
            }
            if let w = m.weekly, !w.isEmpty {
                TwoColumn(sideWidth: 260) {
                        CardBox(padding: 36) { MarkdownText(w).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: 680)
                } side: {
                        VStack(alignment: .leading, spacing: 14) {
                            let runs = m.runs.filter { $0.startedAt >= Date().addingTimeInterval(-7 * 86400) }
                            CardBox(padding: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Eyebrow(text: "The week in numbers")
                                    kv("Nights run", "\(runs.count) of 7"); kv("Read · kept", "\(runs.reduce(0) { $0 + $1.stats.read }) · \(runs.reduce(0) { $0 + $1.stats.kept })")
                                    kv("Sensitive erased", "\(runs.reduce(0) { $0 + $1.stats.sensitive })")
                                    kv("Loops closed · open", "\(m.loops.filter { $0.status == .closed && ($0.closedAt ?? .distantPast) >= Date().addingTimeInterval(-7 * 86400) }.count) · \(m.openLoopCount)")
                                    kv("Raw data sent", "0 bytes", color: t.ok)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            BButton(title: "Open loops") { m.overlay = .none; m.screen = .loops }
                        }
                }
            } else {
                VStack(spacing: 12) {
                    Text("No letter yet").fontWeight(.semibold)
                    Text("Brownie writes one on the first run on or after Sunday. You can ask for one now.").foregroundStyle(t.ink2)
                    BButton(title: "Write my week now", kind: .primary) { m.writeWeeklyNow() }
                }.padding(.top, 80).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
    func kv(_ k: String, _ v: String, color: Color? = nil) -> some View { HStack { Text(k).font(.system(size: 12.5)); Spacer(); Text(v).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color ?? t.ink).monospacedDigit() } }
}

struct WeeklyTeaser: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        Button { m.openWeekly() } label: {
            CardBox {
                HStack(spacing: 16) {
                    ZStack { Circle().fill(t.accent).frame(width: 40, height: 40); Image(systemName: "envelope").foregroundStyle(Color(hex: 0x1A1205)) }
                    VStack(alignment: .leading, spacing: 2) { Text("Your week, in a letter").fontWeight(.semibold); Text("Seven nights: what closed, what’s still open, and who you went quiet on.").foregroundStyle(t.ink2) }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(t.ink3)
                }
            }
        }.buttonStyle(.plain)
    }
}

/// Just enough Markdown for the letters and briefs: ### headings, paragraphs, - bullets, **bold**.
struct MarkdownText: View {
    @Environment(\.theme) var t
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                let b = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if b.hasPrefix("### ") || b.hasPrefix("## ") { Text(b.drop(while: { $0 == "#" || $0 == " " })).font(.system(size: 11, weight: .semibold)).tracking(0.5).textCase(.uppercase).foregroundStyle(t.ink2).padding(.top, 8) }
                else if b.hasPrefix("- ") { ForEach(Array(b.split(separator: "\n").enumerated()), id: \.offset) { _, l in HStack(alignment: .top, spacing: 8) { Text("·"); Text(inline(String(l.dropFirst(2)))) } } }
                else if !b.isEmpty { Text(inline(b)).font(.system(size: 14.5)).lineSpacing(5) }
            }
        }
    }
    func inline(_ s: String) -> AttributedString { (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s) }
}

// MARK: - Pre-meeting brief

struct BriefView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let briefID: String
    static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    var body: some View {
        if let b = m.briefs.first(where: { $0.id == briefID }) {
            VStack(spacing: 0) {
                Toolbar(title: b.title, subtitle: "\(Self.tf.string(from: b.startsAt)) · \(b.attendees.joined(separator: ", "))", back: { m.overlay = .none }) {
                    BButton(title: "Open loops", kind: .quiet) { m.overlay = .none; m.screen = .loops }
                }
                TwoColumn(sideWidth: 320) {
                        CardBox(padding: 24) { MarkdownText(b.text).frame(maxWidth: .infinity, alignment: .leading) }
                } side: {
                        VStack(alignment: .leading, spacing: 14) {
                            CardBox(padding: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Eyebrow(text: "Open loops with them")
                                    if b.loops.isEmpty { Text("None that Brownie knows of.").font(.system(size: 12.5)).foregroundStyle(t.ink2) }
                                    ForEach(b.loops) { l in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) { Circle().fill(l.direction == .mine ? t.bad : t.warn).frame(width: 7, height: 7); Text(l.direction == .mine ? "You → \(l.person)" : "\(l.person) → you").font(.system(size: 12, weight: .medium)) }
                                            Text(l.what).font(.system(size: 12.5))
                                        }.padding(.vertical, 4); Divider()
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("Built on this Mac from your People notes at \(DateFormatter.localizedString(from: b.createdAt, dateStyle: .none, timeStyle: .short)). Only note excerpts went to the brain.").font(.system(size: 11)).foregroundStyle(t.ink2)
                        }
                }
            }
        } else { ForYouView() }
    }
}

// MARK: - Recipes

struct RecipesView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Recipes", subtitle: "Things you taught Hands once, and it does again") {
                if let n = m.runningRecipeName { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running “\(n)”").font(.system(size: 12)); BButton(title: "Stop", kind: .destructive) { m.stopRecipe() } } }
                BButton(title: "Teach Hands something", kind: .primary, systemImage: "record.circle") { m.startTeaching() }.walkthroughTarget("recipes").disabled(m.recipeRun.running)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if m.recipes.isEmpty {
                        CardBox(padding: 28) { VStack(spacing: 6) { Text("Nothing taught yet").fontWeight(.semibold); Text("Press “Teach Hands something”, do the thing once in the other app, press Stop. Hands turns what you did into a recipe.").font(.system(size: 12)).foregroundStyle(t.ink2).multilineTextAlignment(.center) }.frame(maxWidth: .infinity) }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                            ForEach(m.recipes) { r in RecipeTile(recipe: r) }
                        }
                    }
                    CardBox(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How Hands picks a way in — most reliable first, the screen last").fontWeight(.semibold)
                            HStack(spacing: 6) { Rung("1 · App link", on: true); arrow; Rung("2 · AppleScript", on: true); arrow; Rung("3 · The app’s own API (MCP)", on: true); arrow; Rung("4 · Look at the screen and click", on: false) }
                            Text("Every recipe shows which rung it uses. One that needs the screen says so, and you can forbid the screen per app in Settings → Hands.").font(.system(size: 11)).foregroundStyle(t.ink2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    CardBox(padding: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) { Text("From anywhere").fontWeight(.semibold); Text("⌘⇧Space, then the recipe’s name. Or an Apple Shortcut that opens brownie://run?recipe=<name> — then “Hey Siri, <shortcut name>”.").font(.system(size: 11)).foregroundStyle(t.ink2) }
                            Spacer(); BButton(title: "Shortcuts & Siri", kind: .quiet) { m.openSettings(.hands) }
                        }
                    }
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            }
        }
    }
    var arrow: some View { Text("→").font(.system(size: 11)).foregroundStyle(t.ink3) }
}

struct Rung: View {
    @Environment(\.theme) var t
    let text: String; let on: Bool
    init(_ text: String, on: Bool) { self.text = text; self.on = on }
    var body: some View {
        HStack(spacing: 4) { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }; Text(text) }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(on ? t.accentInk : t.ink2).padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(on ? t.accentSoft : t.card)).overlay(Capsule().stroke(on ? .clear : t.cardBorder))
    }
}

struct RecipeTile: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let recipe: TaughtRecipe
    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(recipe.name).font(.system(size: 14, weight: .semibold)).lineLimit(1); Spacer(); Menu { Button("Edit") { m.overlay = .editRecipe(recipe.id) }; Button("Copy Shortcuts link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brownie://run?recipe=\(recipe.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")", forType: .string) }; Button("Delete", role: .destructive) { m.deleteRecipe(recipe.id) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize() }
                Text(recipe.steps.filter { $0.kind != .launch }.map { s in s.kind == .type ? "type “\(s.text.prefix(40))”" : (s.kind == .click ? "press “\(s.target)”" : s.target) }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(t.ink2).lineLimit(2)
                Text("\(recipe.appsLine) · \(recipe.schedule.line)").font(.system(size: 11)).foregroundStyle(t.ink2)
                HStack(spacing: 6) { Rung(recipe.method, on: true); if recipe.method != "Screen" { Rung("Screen if needed", on: false) } }
                if m.recipeRun.running && m.recipeRun.recipeID == recipe.id {
                    HStack { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(m.recipeRun.steps.last ?? "Running…").font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) }; Spacer(); BButton(title: "Stop", kind: .destructive) { m.stopRecipe() } }
                } else {
                    HStack { Text(recipe.runs == 0 ? "Never run" : "Ran \(recipe.runs)× · last \(recipe.lastRunAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "")").font(.system(size: 11)).foregroundStyle(t.ink2); Spacer(); BButton(title: "Edit", kind: .quiet) { m.overlay = .editRecipe(recipe.id) }; BButton(title: "Run now") { m.runRecipe(recipe.id) }.disabled(m.recipeRun.running) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Teach Hands

struct TeachView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Teach Hands", subtitle: label, back: { if m.recorder.isRecording { m.recorder.stop() }; m.overlay = .none; m.screen = .recipes }, backLabel: "Recipes") {
                HStack(spacing: 2) { ForEach(["Show me", "Watching", "Make it reusable", "Saved"], id: \.self) { s in Text(s).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 24).foregroundStyle(stepName == s ? t.ink : t.ink2).background(RoundedRectangle(cornerRadius: 6).fill(stepName == s ? t.card : .clear)) } }.padding(3).background(RoundedRectangle(cornerRadius: 8).fill(t.ctl))
            }
            switch m.teach.step {
            case .show:
                VStack(spacing: 22) {
                    Button { m.teachRecord() } label: { ZStack { Circle().fill(t.bad).frame(width: 64, height: 64).overlay(Circle().stroke(t.bad.opacity(0.2), lineWidth: 8)); Circle().fill(.white).frame(width: 16, height: 16) } }.buttonStyle(.plain)
                    Text("Do it once, the way you always do.").font(.system(size: 26, weight: .bold))
                    Text("Press the button, then do the thing in the other app. Brownie watches the buttons you press and the text you type — the same accessibility tree screen readers use, not pixels, not a recording. Come back and press Stop when you’re done, before Send.").foregroundStyle(t.ink2).multilineTextAlignment(.center).frame(width: 520)
                    Text("It won’t record passwords, and it stops itself at Send, Pay and Delete.").font(.system(size: 11)).foregroundStyle(t.ink2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .watching:
                HStack(alignment: .top, spacing: 24) {
                    CardBox(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { HStack(spacing: 8) { Circle().fill(t.bad).frame(width: 12, height: 12).overlay(Circle().stroke(t.bad.opacity(0.25), lineWidth: 4)); Text("Watching").fontWeight(.semibold) }; Spacer(); BButton(title: "Stop", kind: .primary) { m.teachStop() } }
                            Divider()
                            ForEach(Array(m.teach.steps.enumerated()), id: \.offset) { _, s in StepRow(text: stepText(s), done: true) }
                            if !m.teach.pending.isEmpty { StepRow(text: "Typing “\(m.teach.pending)”…", done: false, current: true) }
                            StepRow(text: "Waiting for your next action…", done: false)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    CardBox(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "What’s being kept")
                            Text("Which app, which button (by its name in the accessibility tree), what you typed. Not a screenshot, not a video.").font(.system(size: 12.5))
                            Text("Password fields are skipped automatically. Press Stop before Send — Hands will always leave that to you.").font(.system(size: 12.5))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 340)
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)).frame(maxHeight: .infinity, alignment: .top)
            case .tune:
                TwoColumn(sideWidth: 340) {
                        VStack(alignment: .leading, spacing: 18) {
                            if let why = m.teach.stoppedBecause { CardBox(padding: 12) { HStack(spacing: 10) { Image(systemName: "hand.raised.fill").foregroundStyle(t.warn); Text(why).font(.system(size: 12.5)) }.frame(maxWidth: .infinity, alignment: .leading) } }
                            CardBox(padding: 18) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Eyebrow(text: "What you did — and what should change each time")
                                    ForEach(Array(m.teach.steps.enumerated()), id: \.offset) { i, s in
                                        HStack(alignment: .top, spacing: 10) { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(t.ink2).frame(width: 18, height: 18).background(Circle().fill(t.ctl2)); stepLabel(s) }
                                    }
                                    HStack(alignment: .top, spacing: 10) { ZStack { Circle().fill(t.warn).frame(width: 18, height: 18); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }; Text("Stop before Send · always yours") }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !m.teach.parameters.isEmpty {
                                CardBox(padding: 18) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(m.teach.parameters) { p in
                                            HStack(alignment: .center) {
                                                VStack(alignment: .leading, spacing: 2) { HStack(spacing: 6) { Param(p.original); Text("the \(p.name)").font(.system(size: 11)).foregroundStyle(t.ink2) }; if p.name == "message" { Text("Brownie can write it fresh from your notes each time, or ask you.").font(.system(size: 11)).foregroundStyle(t.ink2) } }
                                                Spacer()
                                                Segmented(options: p.name == "message" ? ["Keep as is", "Write from my notes", "Ask me"] : ["Keep as “\(p.original.prefix(14))”", "Ask me each time"], selection: Binding(get: { fillName(p) }, set: { setFill(p, $0) }))
                                            }
                                            if p.id != m.teach.parameters.last?.id { Divider() }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                } side: {
                        VStack(alignment: .leading, spacing: 14) {
                            CardBox(padding: 16) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Eyebrow(text: "Name and when")
                                    TextField("Name", text: $m.teach.name).textFieldStyle(.roundedBorder)
                                    Segmented(options: ["When I ask", "Every week"], selection: Binding(get: { m.teach.weekly ? "Every week" : "When I ask" }, set: { m.teach.weekly = $0 == "Every week" }))
                                    if m.teach.weekly {
                                        HStack(spacing: 8) {
                                            Picker("", selection: $m.teach.weekday) { ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) } }.labelsHidden().frame(width: 120)
                                            Picker("", selection: $m.teach.hour) { ForEach(0...23, id: \.self) { h in Text(String(format: "%02d", h)).tag(h) } }.labelsHidden().frame(width: 60)
                                            Text(":"); Picker("", selection: $m.teach.minute) { ForEach([0, 15, 30, 45], id: \.self) { mi in Text(String(format: "%02d", mi)).tag(mi) } }.labelsHidden().frame(width: 60)
                                        }
                                    }
                                    Text("Scheduled runs prepare everything and then wait for you at the last step.").font(.system(size: 11)).foregroundStyle(t.ink2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            CardBox(padding: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Eyebrow(text: "How Hands will do it")
                                    let method = TaughtRecipe(name: "", steps: m.teach.steps, parameters: [], createdAt: Date()).method
                                    HStack(spacing: 6) { Rung(method, on: true); if method != "Screen" { Rung("Screen, if that fails", on: false) } }
                                    Text(method == "WhatsApp link" ? "WhatsApp opens a chat with text already in the box from a link, so Hands never has to look at the screen for this one." : (method == "Screen" ? "This app has no link or script, so Hands works from the accessibility tree and, if it must, the screen." : "Hands drives this app by its accessibility tree; AppleScript where the app offers it.")).font(.system(size: 11)).foregroundStyle(t.ink2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            BButton(title: "Save recipe", kind: .primary) { m.teachSave() }
                        }
                }
            case .saved:
                VStack(spacing: 18) {
                    HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)); Text("Saved") }.font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(t.ok))
                    Text("“\(m.teach.name)” is a recipe now.").font(.system(size: 26, weight: .bold))
                    Text(m.teach.weekly ? "It runs every \(Calendar.current.weekdaySymbols[m.teach.weekday - 1]) at \(m.teach.hour):\(String(format: "%02d", m.teach.minute)) and waits for you at the last step. You can also say it: ⌘⇧Space, then its name." : "Run it from Recipes, or ⌘⇧Space and type its name. Add it to Shortcuts to say it to Siri.").foregroundStyle(t.ink2).multilineTextAlignment(.center).frame(width: 520)
                    HStack(spacing: 8) { if let id = m.teach.savedID { BButton(title: "Edit the steps", kind: .quiet) { m.overlay = .editRecipe(id) } }; BButton(title: "Copy Shortcuts link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brownie://run?recipe=\(m.teach.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")", forType: .string); m.announcement = "Link copied. In Shortcuts: new shortcut → “Open URLs” → paste → name it, and Siri knows it." }; BButton(title: "Done", kind: .primary) { m.overlay = .none; m.screen = .recipes } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    var stepName: String { switch m.teach.step { case .show: return "Show me"; case .watching: return "Watching"; case .tune: return "Make it reusable"; case .saved: return "Saved" } }
    var label: String { switch m.teach.step { case .show: return "Step 1 of 3 · show it once"; case .watching: return "Step 2 of 3 · Hands is watching"; case .tune: return "Step 3 of 3 · what changes each time"; case .saved: return "Done" } }
    func stepText(_ s: TaughtRecipe.Step) -> String {
        switch s.kind { case .launch: return "Opened \(s.app)"; case .click: return "Pressed “\(s.target)” in \(s.app)"; case .type: return "Typed “\(s.text)” into \(s.target)"; case .key: return "Pressed \(s.target)" }
    }
    @ViewBuilder func stepLabel(_ s: TaughtRecipe.Step) -> some View {
        let ps = m.teach.parameters
        switch s.kind {
        case .launch: Text("Open \(s.app)")
        case .click: if ps.contains(where: { $0.original == s.target }) { HStack(spacing: 4) { Text("Press"); Param(s.target) } } else { Text("Press “\(s.target)”") }
        case .type: if ps.contains(where: { $0.original == s.text }) { HStack(spacing: 4) { Text("Type"); Param(s.text) } } else { Text("Type “\(s.text)”") }
        case .key: Text("Press \(s.target)")
        }
    }
    func fillName(_ p: TaughtRecipe.Parameter) -> String {
        switch p.fill { case .fixed: return p.name == "message" ? "Keep as is" : "Keep as “\(p.original.prefix(14))”"; case .ask: return p.name == "message" ? "Ask me" : "Ask me each time"; case .fromNotes: return "Write from my notes" }
    }
    func setFill(_ p: TaughtRecipe.Parameter, _ v: String) {
        guard let i = m.teach.parameters.firstIndex(where: { $0.id == p.id }) else { return }
        m.teach.parameters[i].fill = v.hasPrefix("Ask") ? .ask : (v.hasPrefix("Write") ? .fromNotes : .fixed)
    }
}

struct Param: View {
    @Environment(\.theme) var t
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.count > 60 ? String(text.prefix(60)) + "…" : text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.accentInk).padding(.horizontal, 6).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 5).fill(t.accentSoft)).overlay(Rectangle().fill(t.accent).frame(height: 2), alignment: .bottom) }
}

// MARK: - Running a recipe

struct RecipeRunView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let recipeID: String
    @State private var answers: [String: String] = [:]
    var body: some View {
        let r = m.recipes.first { $0.id == recipeID }
        VStack(spacing: 0) {
            Toolbar(title: r?.name ?? "Recipe", subtitle: m.recipeRun.running ? "Hands is doing it" : (m.recipeRun.asking.isEmpty ? "" : "A couple of things first"), back: { m.overlay = .none; m.screen = .recipes }, backLabel: "Recipes") {
                if m.recipeRun.running { BButton(title: "Stop", kind: .destructive, systemImage: "stop.fill") { m.stopRecipe() } }
                if let o = m.recipeRun.outcome, !o.isEmpty { BButton(title: "Done", kind: .primary) { m.overlay = .none; m.screen = .recipes } }
            }
            VStack(alignment: .leading, spacing: 18) {
                if !m.recipeRun.asking.isEmpty && !m.recipeRun.running && m.recipeRun.outcome == nil {
                    CardBox(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(m.recipeRun.asking) { p in
                                VStack(alignment: .leading, spacing: 4) { Text("The \(p.name)").fontWeight(.semibold); Text("Last time: \(p.original)").font(.system(size: 11)).foregroundStyle(t.ink2)
                                    if p.name == "message" { TextEditor(text: Binding(get: { answers[p.name] ?? p.original }, set: { answers[p.name] = $0 })).font(.system(size: 13)).frame(minHeight: 70).padding(6).scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 6).fill(t.code)) }
                                    else { TextField(p.original, text: Binding(get: { answers[p.name] ?? p.original }, set: { answers[p.name] = $0 })).textFieldStyle(.roundedBorder).frame(width: 320) } }
                            }
                            BButton(title: "Go", kind: .primary, systemImage: "arrow.right") { var a = m.recipeRun.answers; for p in m.recipeRun.asking { a[p.name] = answers[p.name] ?? p.original }; m.runRecipe(recipeID, answers: a) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    CardBox(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(m.recipeRun.steps.enumerated()), id: \.offset) { _, s in StepRow(text: s, done: true) }
                            if m.recipeRun.running { StepRow(text: "Working…", done: false, current: true) }
                            if let o = m.recipeRun.outcome { HStack(spacing: 8) { Pulse(); Text(o).fontWeight(.medium) }.padding(.top, 4) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Hands never presses Send, Pay or Delete. The last step is yours.").font(.system(size: 11)).foregroundStyle(t.ink2)
                }
            }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}


// MARK: - Recipe editor

/// Two columns when there is room, one when there isn't (13-inch windows).
struct TwoColumn<Main: View, Side: View>: View {
    var sideWidth: CGFloat = 320
    var breakpoint: CGFloat = 1180
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if geo.size.width >= breakpoint - 220 {
                    HStack(alignment: .top, spacing: 22) { main.frame(maxWidth: .infinity, alignment: .topLeading); side.frame(width: sideWidth) }
                        .padding(EdgeInsets(top: 22, leading: 28, bottom: 24, trailing: 28))
                } else {
                    VStack(alignment: .leading, spacing: 18) { main; side }
                        .padding(EdgeInsets(top: 22, leading: 24, bottom: 24, trailing: 24))
                }
            }
        }
    }
}

/// Every recorded step can be edited, re-recorded, moved or removed; steps can be added by hand.
struct RecipeEditorView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let recipeID: String
    @State private var r: TaughtRecipe?
    @State private var newKind = "Type text"
    @State private var newText = ""
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "", subtitle: "", back: { m.overlay = .none; m.screen = .recipes }, backLabel: "Recipes") {
                if let rec = Binding($r) {
                    TextField("Recipe name", text: rec.name).textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).frame(minWidth: 160, maxWidth: 320)
                        .overlay(alignment: .bottom) { Rectangle().fill(t.ink3).frame(height: 1).opacity(0.6) }
                    Text("Hands does exactly these, in order, and stops before the last one").font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1)
                }
                Spacer()
                BButton(title: "Try it", kind: .quiet, systemImage: "play") { save(); m.runRecipe(recipeID) }
                BButton(title: "Save", kind: .primary) { save(); m.overlay = .none; m.screen = .recipes }
            }
            if let rec = Binding($r) {
                TwoColumn {
                    VStack(alignment: .leading, spacing: 18) {
                        CardBox(padding: 0) {
                            VStack(spacing: 0) {
                                HStack { Eyebrow(text: "Steps · \(rec.wrappedValue.steps.count)"); Spacer(); Text("Hover a step for its controls").font(.system(size: 11)).foregroundStyle(t.ink2) }.padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
                                ForEach(Array(rec.wrappedValue.steps.enumerated()), id: \.offset) { i, s in
                                    Divider()
                                    StepEditRow(index: i, step: Binding(get: { rec.wrappedValue.steps.indices.contains(i) ? rec.wrappedValue.steps[i] : s }, set: { if rec.wrappedValue.steps.indices.contains(i) { rec.wrappedValue.steps[i] = $0 } }),
                                                isFirst: i == 0, isLast: i == rec.wrappedValue.steps.count - 1,
                                                up: { if i > 0 { rec.wrappedValue.steps.swapAt(i, i - 1) } }, down: { if i < rec.wrappedValue.steps.count - 1 { rec.wrappedValue.steps.swapAt(i, i + 1) } },
                                                rerecord: { save(); m.rerecordStep(recipeID, at: i) }, remove: { rec.wrappedValue.steps.remove(at: i) })
                                }
                                Divider()
                                HStack(spacing: 12) {
                                    ZStack { Circle().fill(t.warn).frame(width: 22, height: 22); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                                    Text("Stop before Send · always yours").foregroundStyle(t.ink2)
                                }.padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)).frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                HStack(spacing: 8) {
                                    Segmented(options: ["Type text", "Press a button", "Press a key", "Open an app"], selection: $newKind)
                                    TextField(newKind == "Type text" ? "the text to type" : (newKind == "Press a key" ? "e.g. cmd+n" : (newKind == "Press a button" ? "the button's title" : "app name")), text: $newText).textFieldStyle(.roundedBorder).frame(minWidth: 140).onSubmit { addStep(rec) }
                                    BButton(title: "Add step", systemImage: "plus") { addStep(rec) }
                                }.padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
                            }
                        }
                        CardBox(padding: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                Eyebrow(text: "What changes each time")
                                if rec.wrappedValue.parameters.isEmpty { HStack { Text("Nothing — every run is identical.").font(.system(size: 12)).foregroundStyle(t.ink2); Spacer(); BButton(title: "Make the typed text a parameter", kind: .quiet) { if let typed = rec.wrappedValue.steps.last(where: { $0.kind == .type }) { rec.wrappedValue.parameters.append(.init(name: "message", original: typed.text)) } } } }
                                ForEach(rec.wrappedValue.parameters) { p in
                                    HStack(spacing: 10) {
                                        Param(p.original); Text("the \(p.name)").font(.system(size: 11)).foregroundStyle(t.ink2)
                                        Spacer()
                                        Segmented(options: p.name == "message" ? ["Keep as is", "Write from my notes", "Ask me"] : ["Keep", "Ask me each time"],
                                                  selection: Binding(get: { switch p.fill { case .fixed: return p.name == "message" ? "Keep as is" : "Keep"; case .ask: return p.name == "message" ? "Ask me" : "Ask me each time"; case .fromNotes: return "Write from my notes" } },
                                                                     set: { v in if let j = rec.wrappedValue.parameters.firstIndex(where: { $0.id == p.id }) { rec.wrappedValue.parameters[j].fill = v.hasPrefix("Ask") ? .ask : (v.hasPrefix("Write") ? .fromNotes : .fixed) } }))
                                        BButton(title: "", kind: .quiet, systemImage: "xmark") { rec.wrappedValue.parameters.removeAll { $0.id == p.id } }
                                    }
                                    if p.id != rec.wrappedValue.parameters.last?.id { Divider() }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } side: {
                    VStack(alignment: .leading, spacing: 14) {
                        CardBox(padding: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                Eyebrow(text: "When")
                                Segmented(options: ["When I ask", "Every week", "When a file arrives"], selection: Binding(get: { switch rec.wrappedValue.schedule { case .weekly: return "Every week"; case .folder: return "When a file arrives"; default: return "When I ask" } }, set: { v in rec.wrappedValue.schedule = v == "Every week" ? .weekly(weekday: 2, hour: 9, minute: 0) : (v == "When a file arrives" ? .folder(path: "~/Downloads", pattern: "*.pdf") : .onDemand) }))
                                if case .weekly(let d, let h, let mi) = rec.wrappedValue.schedule {
                                    HStack(spacing: 6) {
                                        Picker("", selection: Binding(get: { d }, set: { rec.wrappedValue.schedule = .weekly(weekday: $0, hour: h, minute: mi) })) { ForEach(1...7, id: \.self) { x in Text(Calendar.current.weekdaySymbols[x - 1]).tag(x) } }.labelsHidden().frame(width: 118)
                                        Picker("", selection: Binding(get: { h }, set: { rec.wrappedValue.schedule = .weekly(weekday: d, hour: $0, minute: mi) })) { ForEach(0...23, id: \.self) { x in Text(String(format: "%02d", x)).tag(x) } }.labelsHidden().frame(width: 58)
                                        Picker("", selection: Binding(get: { mi }, set: { rec.wrappedValue.schedule = .weekly(weekday: d, hour: h, minute: $0) })) { ForEach([0, 15, 30, 45], id: \.self) { x in Text(String(format: "%02d", x)).tag(x) } }.labelsHidden().frame(width: 58)
                                    }
                                }
                                if case .folder(let path, let pattern) = rec.wrappedValue.schedule {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 6) { Text("Folder").font(.system(size: 11)).foregroundStyle(t.ink2).frame(width: 56, alignment: .leading); TextField("~/Downloads", text: Binding(get: { path }, set: { rec.wrappedValue.schedule = .folder(path: $0, pattern: pattern) })).textFieldStyle(.roundedBorder); BButton(title: "Choose…", kind: .quiet) { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; if p.runModal() == .OK, let u = p.url { rec.wrappedValue.schedule = .folder(path: (u.path as NSString).abbreviatingWithTildeInPath, pattern: pattern) } } }
                                        HStack(spacing: 6) { Text("Matching").font(.system(size: 11)).foregroundStyle(t.ink2).frame(width: 56, alignment: .leading); TextField("*invoice*.pdf", text: Binding(get: { pattern }, set: { rec.wrappedValue.schedule = .folder(path: path, pattern: $0) })).textFieldStyle(.roundedBorder) }
                                        Text("Brownie watches the folder while it's open. A match runs the recipe with {file} filled in — type {file} or {filename} in a step to use it — and waits for you at the last step. Files already there don't count.").font(.system(size: 11)).foregroundStyle(t.ink2)
                                    }
                                }
                                if case .weekly = rec.wrappedValue.schedule { Text("Scheduled runs prepare everything and wait for you at the last step.").font(.system(size: 11)).foregroundStyle(t.ink2) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        CardBox(padding: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Eyebrow(text: "How Hands will do it")
                                HStack(spacing: 6) { Rung(rec.wrappedValue.method, on: true); if rec.wrappedValue.method != "Screen" { Rung("Screen, if that fails", on: false) } }
                                Text(rec.wrappedValue.runs == 0 ? "Never run yet" : "Ran \(rec.wrappedValue.runs)× · last \(rec.wrappedValue.lastRunAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "")").font(.system(size: 11)).foregroundStyle(t.ink2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        CardBox(padding: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Eyebrow(text: "From anywhere")
                                Text("brownie://run?recipe=\(rec.wrappedValue.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")").font(.system(size: 11, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(t.code)).textSelection(.enabled)
                                BButton(title: "Copy link for Shortcuts", kind: .quiet) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brownie://run?recipe=\(rec.wrappedValue.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")", forType: .string); m.announcement = "Link copied. In Shortcuts: new shortcut → “Open URLs” → paste → name it, and Siri knows it." }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        BButton(title: "Delete this recipe", kind: .destructive) { m.deleteRecipe(recipeID); m.overlay = .none; m.screen = .recipes }
                    }
                }
            } else { Text("This recipe is gone.").foregroundStyle(t.ink2).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear { r = m.recipes.first { $0.id == recipeID } }
        .onChange(of: m.recipes) { _, v in if let n = v.first(where: { $0.id == recipeID }), n.steps != r?.steps { r = n } }
    }
    func save() { if let r { m.updateRecipe(r) } }
    func addStep(_ rec: Binding<TaughtRecipe>) {
        let app = rec.wrappedValue.steps.last?.app ?? ""
        guard !newText.isEmpty else { return }
        switch newKind {
        case "Type text": rec.wrappedValue.steps.append(.init(kind: .type, app: app, target: "text field", role: "TextField", text: newText))
        case "Press a key": rec.wrappedValue.steps.append(.init(kind: .key, app: app, target: newText))
        case "Press a button": rec.wrappedValue.steps.append(.init(kind: .click, app: app, target: newText, role: "Button"))
        default: rec.wrappedValue.steps.append(.init(kind: .launch, app: newText, target: newText))
        }
        newText = ""
    }
}

/// One step: number, kind glyph, verb · app, the editable content, and hover controls.
struct StepEditRow: View {
    @Environment(\.theme) var t
    let index: Int
    @Binding var step: TaughtRecipe.Step
    let isFirst: Bool, isLast: Bool
    let up: () -> Void, down: () -> Void, rerecord: () -> Void, remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(t.ink2).frame(width: 22, height: 22).background(Circle().fill(t.ctl2)).padding(.top, 3)
            ZStack { RoundedRectangle(cornerRadius: 7).fill(t.accentSoft).frame(width: 26, height: 26); Image(systemName: glyph).font(.system(size: 12, weight: .medium)).foregroundStyle(t.accentInk) }.padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { Text(verb.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(t.ink2); Text("· \(step.app)").font(.system(size: 11)).foregroundStyle(t.ink2) }
                switch step.kind {
                case .launch: Text("Open \(step.app)").font(.system(size: 13.5))
                case .click: HStack(spacing: 6) { Text("Press").font(.system(size: 13.5)); TextField("element title", text: Binding(get: { step.target }, set: { step = .init(kind: .click, app: step.app, target: $0, role: step.role) })).textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.accentInk).padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(t.accentSoft)).frame(maxWidth: 320); if !step.role.isEmpty { Text(step.role.lowercased()).font(.system(size: 11)).foregroundStyle(t.ink2) } }
                case .type:
                    TextEditor(text: $step.text).font(.system(size: 13.5)).frame(minHeight: 40, maxHeight: 120).padding(6).scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 8).fill(t.code)).overlay(RoundedRectangle(cornerRadius: 8).stroke(t.cardBorder))
                    Text("into “\(step.target)” · checked after typing: focused, set, read back; typed key by key or pasted if it didn't land").font(.system(size: 11)).foregroundStyle(t.ink2)
                case .key: HStack(spacing: 6) { Text("Press").font(.system(size: 13.5)); TextField("cmd+n", text: Binding(get: { step.target }, set: { step = .init(kind: .key, app: step.app, target: $0) })).textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(t.chip)).frame(maxWidth: 160) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if step.kind != .launch { icon("record.circle", help: "Re-record this step", action: rerecord) }
                icon("arrow.up", help: "Move up", action: up).disabled(isFirst)
                icon("arrow.down", help: "Move down", action: down).disabled(isLast)
                icon("trash", help: "Remove", destructive: true, action: remove)
            }.opacity(hover ? 1 : 0.3)
        }.padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 10))
        .background(hover ? t.ctl : .clear)
        .onHover { hover = $0 }
    }
    var glyph: String { switch step.kind { case .launch: return "macwindow"; case .click: return "cursorarrow.click"; case .type: return "textformat"; case .key: return "keyboard" } }
    var verb: String { switch step.kind { case .launch: return "Open"; case .click: return "Press"; case .type: return "Type"; case .key: return "Key" } }
    func icon(_ name: String, help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12, weight: .medium)).foregroundStyle(destructive ? t.bad : t.ink2).frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 6).fill(.clear)) }.buttonStyle(.plain).help(help)
    }
}


// MARK: - Ask

struct AskView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var question = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Ask", subtitle: "Answers from your notes · every claim links to where it came from") {
                if !m.asks.isEmpty { BButton(title: "Clear", kind: .quiet) { m.clearAsks() } }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if m.asks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask about anyone, any promise, any plan.").font(.system(size: 17, weight: .semibold))
                                Text("“What did I promise Meera?” · “Who is Karan?” · “What's still open with the landlord?”").foregroundStyle(t.ink2)
                                Text("The answer is built from your notes on this Mac; only the matching note excerpts go to the brain.").font(.system(size: 11)).foregroundStyle(t.ink2)
                            }.padding(.top, 20)
                        }
                        ForEach(Array(m.asks.enumerated()), id: \.offset) { i, a in
                            AskExchange(a: a).id(i)
                        }
                        if m.asking { HStack(spacing: 10) { DawnMark(size: 28); ProgressView().controlSize(.small); Text("Reading your notes…").font(.system(size: 12)).foregroundStyle(t.ink2) } }
                    }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: m.asks.count) { _, n in withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.max").foregroundStyle(t.accent)
                TextField("Ask about anyone, any promise, any plan…", text: $question).textFieldStyle(.plain).font(.system(size: 14)).focused($focused).onSubmit { send() }
                BButton(title: "Ask", kind: .primary) { send() }.disabled(m.asking)
            }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(t.card)).overlay(RoundedRectangle(cornerRadius: 12).stroke(t.cardBorder)).shadow(color: .black.opacity(0.08), radius: 12, y: 6)
            .padding(EdgeInsets(top: 8, leading: 28, bottom: 20, trailing: 28))
        }.onAppear { focused = true }
    }
    func send() { let q = question; question = ""; m.ask(q) }
}

struct AskExchange: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let a: Asker.Answer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); Text(a.question).font(.system(size: 14)).padding(12).background(RoundedRectangle(cornerRadius: 12).fill(t.accentSoft)).frame(maxWidth: 560, alignment: .trailing) }
            HStack(alignment: .top, spacing: 12) {
                DawnMark(size: 28)
                VStack(alignment: .leading, spacing: 8) {
                    AnswerText(answer: a).padding(14).background(RoundedRectangle(cornerRadius: 12).fill(t.card)).overlay(RoundedRectangle(cornerRadius: 12).stroke(t.cardBorder))
                    if !a.citations.isEmpty { HStack(spacing: 6) { ForEach(a.citations) { c in CiteChip(c: c) { m.open(c) } } } }
                    if !a.actions.isEmpty { HStack(spacing: 6) { ForEach(Array(a.actions.enumerated()), id: \.offset) { _, x in BButton(title: x.label) { m.run(x) } } } }
                }.frame(maxWidth: 720, alignment: .leading)
            }
        }
    }
}

/// The answer with [n] markers shown as small numbered marks.
struct AnswerText: View {
    @Environment(\.theme) var t
    let answer: Asker.Answer
    var body: some View {
        Text(attributed).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
    }
    var attributed: AttributedString {
        var out = AttributedString()
        var rest = Substring(answer.answer)
        while let r = rest.range(of: "[", options: []), let e = rest[r.upperBound...].firstIndex(of: "]"), Int(rest[r.upperBound..<e]) != nil {
            out += AttributedString(String(rest[..<r.lowerBound]))
            var mark = AttributedString(" " + String(rest[r.upperBound..<e]) + " ")
            mark.font = Font.system(size: 9.5, weight: .semibold); mark.foregroundColor = t.accentInk; mark.backgroundColor = t.accentSoft
            out += mark
            rest = rest[rest.index(after: e)...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

struct CiteChip: View {
    @Environment(\.theme) var t
    let c: Asker.Citation; let open: () -> Void
    var icon: String { switch c.kind { case "whatsapp", "imessage": return "bubble.left"; case "mail": return "envelope"; case "loop": return "arrow.triangle.2.circlepath"; case "card": return "sun.max"; default: return "doc.text" } }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) { Text("\(c.n)").font(.system(size: 9.5, weight: .bold)); Image(systemName: icon).font(.system(size: 10)); Text(c.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1) }
                .foregroundStyle(t.accentInk).padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(t.chip)).overlay(Capsule().stroke(t.cardBorder))
        }.buttonStyle(.plain).help("Open the original")
    }
}
