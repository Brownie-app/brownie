import SwiftUI
import Domain
import Brain

struct ForYouView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "For You", subtitle: m.lastRun.map { ($0.trigger == .daytime ? "Refreshed " : "Prepared ") + relative($0.startedAt) + ($0.trigger == .daytime ? " while you were away" : "") } ?? "Nothing read yet") {
                BButton(title: m.isRunning ? "Reading…" : "Analyze now", systemImage: "arrow.clockwise") { if m.isRunning { m.overlay = .processing } else { m.analyzeNow() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let banner = bannerText { CautionBanner(text: banner) }
                    if !m.isRunning, let sk = m.lastSkipped, !sk.isEmpty {
                        HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle").foregroundStyle(t.ink3); Text("Not read last time: \(sk)").font(.system(size: 12)).foregroundStyle(t.ink2) }
                    }
                    if m.modelPath == nil { ReaderMissing() }
                    if let letter = m.letter, !m.letterOpened, !letter.isEmpty { LetterTeaser() }
                    if let w = m.weekly, !w.isEmpty, !m.weeklySeen { WeeklyTeaser() }
                    HStack { Text(headline).font(.system(size: 17, weight: .semibold)); Spacer(); Text("Ranked by urgency · nothing is sent until you tap").font(.system(size: 11)).foregroundStyle(t.ink2) }
                    if m.cards.isEmpty { EmptyCards() }
                    else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                            ForEach(Array(m.cards.enumerated()), id: \.element.id) { i, c in
                                CardTile(card: c).walkthroughTarget(i == 0 ? "foryou" : nil)
                                    .onTapGesture { m.markWalkthrough("foryou"); m.overlay = .card(c.id) }
                            }
                        }
                    }
                    if !m.snoozedCards.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "Snoozed")
                            ForEach(m.snoozedCards) { c in
                                HStack(spacing: 10) { UrgencyDot(urgency: c.urgency); Text(c.title).lineLimit(1); Spacer()
                                    Text(c.snoozedUntil.map { "back \(relative($0))" } ?? "").font(.system(size: 11)).foregroundStyle(t.ink2)
                                    BButton(title: "Bring back", kind: .quiet) { m.unsnooze(c.id) } }.padding(.vertical, 2)
                                Divider()
                            }
                        }
                    }
                    if let r = m.lastRun { NumbersRow(run: r) }
                    if !m.pastCards.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "Earlier")
                            ForEach(m.pastCards.prefix(8)) { c in
                                HStack(spacing: 10) { UrgencyDot(urgency: c.urgency); Text(c.title).lineLimit(1); Spacer(); Text(pastLabel(c)).font(.system(size: 11)).foregroundStyle(t.ink2) }.padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }.padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            }
        }
    }

    var headline: String { m.cards.isEmpty ? "Nothing needs you this morning" : "\(m.cards.count) thing\(m.cards.count == 1 ? "" : "s") worth your attention" }

    var bannerText: String? {
        guard !m.isRunning, let o = m.lastRun?.outcome else { return nil }
        switch o {
        case .skippedOnBattery: return "Last night didn't run — your Mac was on battery at the scheduled time. Plug in tonight, or run now."
        case .failedReader(let why): return "The reader stopped: \(why). Try again, or check Settings → Brain → On this Mac."
        case .failedBrain(.usageLimit): return "The brain hit its usage limit part-way. Notes were kept; it will finish next run."
        case .failedBrain(.unauthorized): return "The brain rejected your key. Fix it in Settings → Brain."
        case .failedBrain(.notConfigured): return "No brain is set up, so nothing was synthesised. Add one in Settings → Brain."
        case .failedBrain(.other): return "The brain call failed" + (m.lastError.map { ": \($0)" } ?? "") + ". Your notes are safe; the summaries were kept and it will try again next run."
        case .partial(let stage): return "The run stopped part-way: \(stage)."
        case .cancelled: return "The last run was stopped before it finished."
        default: return nil
        }
    }

    func relative(_ d: Date) -> String { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f.localizedString(for: d, relativeTo: Date()) }
    func pastLabel(_ c: Card) -> String {
        let when = relative(c.resolvedAt ?? c.createdAt)
        switch c.state { case .fired: return "done · \(when)"; case .dismissed: return "not now · \(when)"; case .expired: return "expired · \(when)"; default: return when }
    }
}

struct CautionBanner: View {
    @Environment(\.theme) var t
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(t.warn)
            VStack(alignment: .leading, spacing: 2) { Text("Something to know").fontWeight(.semibold); Text(text).foregroundStyle(t.ink2) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 10).fill(t.accentSoft)).overlay(RoundedRectangle(cornerRadius: 10).stroke(t.warn.opacity(0.45)))
    }
}

struct ReaderMissing: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        CardBox {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 22)).foregroundStyle(t.accentInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The reader isn't on this Mac yet").fontWeight(.semibold)
                    Text(status).font(.system(size: 12)).foregroundStyle(t.ink2)
                }
                Spacer()
                switch m.modelState {
                case .downloading: BButton(title: "Cancel", kind: .quiet) { Task { await m.download.cancel() } }
                default: BButton(title: "Download Gemma 4 E4B (3.7 GB)", kind: .primary) { Task { await m.download.start() } }
                }
            }
        }
    }
    var status: String {
        switch m.modelState {
        case .downloading(let p): return "\(Int(p.fraction * 100))% · \(p.received / 1_000_000) of \(p.total / 1_000_000) MB"
        case .verifying: return "Verifying…"
        case .failed(let e): return "Download failed: \(e)"
        default: return "It reads everything here, on this machine. 3.7 GB, once."
        }
    }
}

struct LetterTeaser: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        Button { m.overlay = .letter } label: {
            CardBox {
                HStack(spacing: 16) {
                    ZStack { Circle().fill(t.accent).frame(width: 40, height: 40); Image(systemName: "envelope").foregroundStyle(Color(hex: 0x1A1205)) }
                    VStack(alignment: .leading, spacing: 2) { Text("A letter from Brownie").fontWeight(.semibold); Text("Written once, after your first night. What it learned about you, in its own words.").foregroundStyle(t.ink2) }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(t.ink3)
                }
            }
        }.buttonStyle(.plain)
    }
}

struct EmptyCards: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        CardBox(padding: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(m.brain == nil ? "Notes only, for now" : (m.lastRun == nil ? "Run the first read" : "Nothing needs you this morning")).font(.system(size: 14, weight: .semibold))
                Text(m.brain == nil ? "Without a brain, Brownie reads and keeps notes but can't decide what needs you or draft anything. Add one in Settings → Brain." : (m.lastRun == nil ? "Press Analyze now. The first read looks at everything you've enabled, so it takes a while." : "Cards appear here when something is waiting on you — a reply, a promise, a renewal, a meeting to prep.")).foregroundStyle(t.ink2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CardTile: View {
    @Environment(\.theme) var t
    let card: Card
    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { UrgencyDot(urgency: card.urgency); Text(card.title).font(.system(size: 14, weight: .semibold)).lineLimit(1); Spacer(); if card.isComeBack { CameBackChip() }; Chip(text: card.sourceLabel) }
                Text(card.why).font(.system(size: 12.5)).foregroundStyle(t.ink2).lineLimit(3)
                HStack(spacing: 8) { Chip(text: card.actionLabel, accent: true); Text(card.dueLine).font(.system(size: 11)).foregroundStyle(t.ink2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
    }
}

struct NumbersRow: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let run: RunRecord
    var body: some View {
        CardBox(padding: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last run, in numbers").fontWeight(.semibold)
                    Text("\(run.stats.read) read · \(run.stats.kept) kept · \(run.stats.dropped) not worth keeping · \(run.stats.sensitive) sensitive erased" + (run.stats.deferred > 0 ? " · \(run.stats.deferred) deferred to the next run" : "") + (m.bulkUnread > 0 ? " · \(m.bulkUnread) files in bulk folders never read" : "")).font(.system(size: 11)).foregroundStyle(t.ink2)
                }
                Spacer()
                if m.showSendLine, let s = m.lastNightSend { BButton(title: s.requests == 0 ? "0 bytes left your Mac" : "See exactly what left (\(s.bytes.formattedBytes))", kind: .quiet) { m.screen = .sendLog } }
                BButton(title: "What was excluded", kind: .quiet) { m.screen = .excluded }
            }
        }
    }
}

struct CameBackChip: View {
    @Environment(\.theme) var t
    var body: some View {
        HStack(spacing: 4) { Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold)); Text("Came back") }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(t.bad).padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(t.bad.opacity(0.12)))
    }
}

// MARK: - Card detail

struct CardDetailView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let cardID: String
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        if let c = m.card(cardID) {
            VStack(spacing: 0) {
                Toolbar(title: c.title, back: { m.overlay = .none }) {
                    Menu { Button("Tomorrow morning") { m.snooze(c.id, days: 1) }; Button("In 3 days") { m.snooze(c.id, days: 3) }; Button("Next week") { m.snooze(c.id, days: 7) } } label: { Text("Snooze") }.menuStyle(.borderlessButton).fixedSize()
                    BButton(title: "Not now", kind: .quiet) { m.dismiss(c.id) }
                    BButton(title: c.fireLabel, kind: .primary, systemImage: "arrow.right") { if editing { m.updateDraft(c.id, draft); editing = false }; m.fire(c.id) }.walkthroughTarget("card")
                }
                TwoColumn(sideWidth: 340) {
                        VStack(alignment: .leading, spacing: 18) {
                            if c.isComeBack {
                                CardBox(padding: 14) {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "arrow.counterclockwise").foregroundStyle(t.bad).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 2) { Text("This card came back").fontWeight(.semibold); Text("You sent a message about this before. The next read saw no reply, so Brownie brought it back with a gentler nudge instead of letting it drop.").font(.system(size: 12.5)).foregroundStyle(t.ink2) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.overlay(RoundedRectangle(cornerRadius: 10).stroke(t.bad.opacity(0.35)))
                            }
                            section("Why this is here") { Text(c.why).font(.system(size: 14)) }
                            section(c.draftLabel) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if editing {
                                        TextEditor(text: $draft).font(.system(size: 13.5)).frame(minHeight: 120).padding(8).scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
                                        HStack { BButton(title: "Save draft", kind: .primary) { m.updateDraft(c.id, draft); editing = false }; BButton(title: "Cancel", kind: .quiet) { editing = false } }
                                    } else {
                                        Text(c.draft).font(.system(size: 13.5)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
                                        HStack { Text("You can edit this before it goes. Brownie never sends on its own.").font(.system(size: 11)).foregroundStyle(t.ink2); Spacer(); BButton(title: "Edit draft", kind: .quiet) { draft = c.draft; editing = true } }
                                    }
                                }
                            }
                            section("What will happen when you tap") {
                                HStack(spacing: 6) { Rung(methodName(c.recipe), on: true); if case .computerUse = c.recipe {} else { Rung("Screen, only if that fails", on: false) } }.padding(.bottom, 2)
                                VStack(alignment: .leading, spacing: 8) { ForEach(Array(c.recipe.stepsInWords.enumerated()), id: \.offset) { i, s in HStack(alignment: .top, spacing: 10) { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(t.ink2).frame(width: 18, height: 18).background(Circle().fill(t.ctl2)); Text(s) } } }
                            }
                        }
                } side: {
                        VStack(alignment: .leading, spacing: 14) {
                            section("Evidence") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(c.evidence.enumerated()), id: \.offset) { _, e in
                                        VStack(alignment: .leading, spacing: 2) { HStack { Chip(text: e.source); Text(e.when).font(.system(size: 11)).foregroundStyle(t.ink2) }; Text(e.text).font(.system(size: 12.5)) }
                                        Divider()
                                    }
                                    Text("Summaries were written on your Mac. Raw messages never left it.").font(.system(size: 11)).foregroundStyle(t.ink2)
                                }
                            }
                            section(c.verification == .verified ? "Verified this morning" : "Couldn't fully verify") {
                                HStack(spacing: 8) { ZStack { Circle().fill(c.verification == .verified ? t.ok : t.warn).frame(width: 18, height: 18); Image(systemName: c.verification == .verified ? "checkmark" : "questionmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }; Text(c.verifiedLine.isEmpty ? (c.verification == .verified ? "Checked against your notes." : "Shown with lower confidence.") : c.verifiedLine).font(.system(size: 12.5)) }
                            }
                            BButton(title: "Never show cards like this", kind: .destructive) { m.instructions += "\nDon't show cards like: \(c.title)"; m.set(SettingKey.standingInstructions, m.instructions); m.dismiss(c.id) }
                        }
                }
            }
        } else { ForYouView() }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        CardBox(padding: 18) { VStack(alignment: .leading, spacing: 8) { Eyebrow(text: title); c() }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    func methodName(_ r: Recipe) -> String {
        switch r { case .whatsapp: return "WhatsApp link"; case .imessage, .mail: return "AppleScript"; case .calendar: return "Calendar (EventKit)"; case .note: return "A file in your notes"; case .browser: return "Your browser"; case .computerUse: return "Screen — Hands reads the accessibility tree" }
    }
}

// MARK: - Firing

struct FiringView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let cardID: String
    var body: some View {
        let c = m.card(cardID)
        VStack(spacing: 0) {
            Toolbar(title: c?.title ?? "Doing it") { BButton(title: "Back", kind: .quiet) { m.overlay = .none } }
            Spacer()
            CardBox(padding: 26) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) { Pulse(); Text(finished ? "Done with my part" : "Doing it now").font(.system(size: 17, weight: .semibold)); Spacer(); Text(c?.recipe.channelName ?? "").font(.system(size: 11)).foregroundStyle(t.ink2) }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(m.fireEvents.enumerated()), id: \.offset) { _, e in
                            switch e {
                            case .step(let s, let done): StepRow(text: s, done: done, current: !done)
                            case .pausedForUser(let s): StepRow(text: s, done: false, current: true).fontWeight(.medium)
                            case .finished(let o): Text(label(o)).font(.system(size: 11)).foregroundStyle(t.ink2)
                            }
                        }
                    }
                    Divider()
                    Text("Nothing irreversible happens without a step you can see here. Sending, paying and deleting are always yours.").font(.system(size: 11)).foregroundStyle(t.ink2)
                }
            }.frame(width: 560)
            Spacer()
        }
    }
    var finished: Bool { m.fireEvents.contains { if case .finished = $0 { return true }; return false } }
    func label(_ o: FireOutcome) -> String {
        switch o { case .done: return "Done."; case .pausedAtUserStep: return "Paused at the step that's yours."; case .stopped: return "Stopped."; case .couldNot: return "Couldn't do it this time — see above." }
    }
}

// MARK: - Processing

struct ProcessingView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        let p = m.progress
        VStack(spacing: 0) {
            Toolbar(title: title(p.stage)) {
                if m.isRunning { BButton(title: "Stop", kind: .destructive, systemImage: "stop.fill") { m.stopRun() } }
                else { BButton(title: "Back to For You", kind: .quiet) { m.overlay = .none } }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(p.stage == .reading ? "On your Mac · \(p.sourceName.isEmpty ? "starting" : p.sourceName)" : stageLine(p)).font(.system(size: 17, weight: .semibold)); Spacer()
                    if p.stage == .reading, p.itemCount > 0 { Text("\(p.bucketName) · item \(p.itemIndex) of \(p.itemCount)").font(.system(size: 11)).foregroundStyle(t.ink2) } }
                ProgressView(value: p.itemCount > 0 ? Double(p.itemIndex) / Double(p.itemCount) : 0).tint(t.accent)
                HStack(spacing: 10) {
                    stat("Read", p.stats.read, t.ink); stat("Kept", p.stats.kept, t.ok); stat("Not worth keeping", p.stats.dropped, t.ink); stat("Sensitive · erased", p.stats.sensitive, t.bad)
                }
                CardBox(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Thinking")
                        if let title = p.lastTitle { Text(title).foregroundStyle(t.ink3).font(.system(size: 12.5)) }
                        if let s = p.lastSummary { Text(s).font(.system(size: 12.5)).foregroundStyle(t.ink2) }
                        ForEach(Array(m.thoughts.enumerated()), id: \.offset) { _, th in Text(th).font(.system(size: 12.5)).lineLimit(3) }
                        if p.lastTitle == nil && m.thoughts.isEmpty { Text(p.stage == .reading ? "Loading the reader…" : "Waiting for the brain — a long turn can take a minute or two").font(.system(size: 12.5)).foregroundStyle(t.ink3) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(stageFooter(p)).font(.system(size: 11)).foregroundStyle(t.ink2).frame(maxWidth: .infinity)
            }.frame(width: 620)
            Spacer()
        }
    }
    func stat(_ l: String, _ n: Int, _ c: Color) -> some View { CardBox(padding: 12) { VStack(alignment: .leading, spacing: 2) { Text(l).font(.system(size: 11)).foregroundStyle(t.ink2); Text("\(n)").font(.system(size: 20, weight: .semibold)).foregroundStyle(c) }.frame(maxWidth: .infinity, alignment: .leading) } }
    func title(_ s: RunProgress.Stage) -> String { switch s { case .reading: return "Reading what's new"; case .synthesising: return "Updating your notes"; case .judging: return "Looking for what needs you"; case .preparing: return "Getting cards ready"; case .finishing, .done: return "Finishing" } }
    func stageLine(_ p: RunProgress) -> String { if let i = p.partIndex, let n = p.partCount { return "With the brain · part \(i) of \(n)" }; return "With the brain" }
    func stageFooter(_ p: RunProgress) -> String { switch p.stage { case .reading: return "Stage 1 of 3 · next: update your knowledge base, then look for what needs you"; case .synthesising: return "Stage 2 of 3 · only summaries leave your Mac, never the originals"; case .judging, .preparing: return "Stage 3 of 3 · nothing is sent; cards wait for your tap"; default: return "Done" } }
}

// MARK: - Letter

struct LetterView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "A letter from Brownie", back: { m.overlay = .none }) { Text("Written once · never uploaded").font(.system(size: 11)).foregroundStyle(t.ink2) }
            ScrollView {
                if m.letterOpened, let l = m.letter {
                    CardBox(padding: 40) { Text(l).font(.system(size: 14.5)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading) }.frame(width: 640).padding(.top, 40)
                } else {
                    VStack(spacing: 18) {
                        Button { m.openLetter() } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: 0xF4E7CF), Color(hex: 0xE7C894)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 420, height: 260).shadow(color: Color(hex: 0x785014).opacity(0.25), radius: 15, y: 10)
                                ZStack { Circle().fill(t.accent).frame(width: 56, height: 56).shadow(radius: 3, y: 2); Image(systemName: "sun.max").foregroundStyle(Color(hex: 0x1A1205)).font(.system(size: 22)) }
                            }
                        }.buttonStyle(.plain)
                        Text("Tap the seal to open").foregroundStyle(t.ink2)
                    }.padding(.top, 60)
                }
            }
        }
    }
}
