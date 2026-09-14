import SwiftUI
import Domain
import Platform
import Brain
import Inference

struct OnboardingView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var step = 1
    @State private var key = ""
    let labels = ["Welcome", "Download the reader", "Choose a brain", "Choose sources", "Permissions", "Overnight", "First read"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { ForEach(1...7, id: \.self) { i in Capsule().fill(i == step ? t.accent : (i < step ? t.ink3 : t.ctl2)).frame(width: i == step ? 18 : 6, height: 6) } }.frame(height: 48)
            ScrollView { VStack(spacing: 14) { content }.padding(.horizontal, 64).padding(.top, 20).frame(maxWidth: .infinity) }
            HStack {
                Text("Step \(step) of 7 · \(labels[step - 1])").font(.system(size: 11)).foregroundStyle(t.ink2); Spacer()
                BButton(title: step == 1 ? "Quit" : "Back", kind: .quiet) { if step == 1 { NSApp.terminate(nil) } else { step -= 1 } }
                BButton(title: step == 7 ? "Open Brownie" : (step == 1 ? "Get started" : "Continue"), kind: .primary) { next() }
            }.padding(.horizontal, 28).frame(height: 72).overlay(alignment: .top) { Rectangle().fill(t.sep).frame(height: 1) }
        }
        .frame(width: 900, height: 640).background(t.content)
    }

    func next() {
        if step == 7 { m.onboardingDone = true; m.set(SettingKey.onboardingDone, "true"); return }
        if step == 2, m.modelPath == nil, case .idle = m.modelState { Task { await m.download.start() } }
        if step == 6 { Task { await m.refreshPermissions(); await m.refreshSources() } }
        step += 1
        if step == 7, !m.isRunning { m.analyzeNow(trigger: .firstRun) }
    }

    @ViewBuilder var content: some View {
        switch step {
        case 1:
            Circle().fill(RadialGradient(colors: [Color(hex: 0xFBE7C2), t.accent, Color(hex: 0xA8681C)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 60)).frame(width: 96, height: 96).shadow(color: t.accent.opacity(0.35), radius: 15, y: 12).padding(.top, 20)
            h1("Your Mac, while you sleep.")
            lead("Every night, Brownie wakes your Mac, reads what's new in your life — messages, files, mail — and gets a few things ready for the morning. It reads everything here, on this machine. It forgets what it shouldn't know the moment it sees it.")
            HStack(spacing: 12) {
                pillar("desktopcomputer", "Reads on this Mac", "A small model, offline, does the reading. Raw data never leaves.")
                pillar("sun.max", "Morning cards", "A handful of things worth your attention, each ready to do in one tap.")
                pillar("lock", "No account", "Nothing to sign up for. Nothing of yours on anyone's server.")
            }
        case 2:
            h1("First, the reader.")
            lead("A 3.7 GB model downloads once and lives in Application Support. It runs on your Mac's GPU and never connects to anything.")
            CardBox(padding: 18) { VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Gemma 4 E4B").fontWeight(.semibold); Spacer(); Text(modelLine).font(.system(size: 11)).foregroundStyle(t.ink2) }
                ProgressView(value: modelFraction).tint(t.accent)
                Text("Resumes if you close the window. Verified by size before use.").font(.system(size: 11)).foregroundStyle(t.ink2)
                if m.modelPath == nil, case .idle = m.modelState { BButton(title: "Start download", kind: .primary) { Task { await m.download.start() } } }
            } }.frame(width: 560)
            CardBox(padding: 14) { VStack(alignment: .leading, spacing: 8) {
                StepRow(text: "Apple silicon", done: true); StepRow(text: "\(ModelCatalog.physicalMemoryGB) GB memory · \(ModelCatalog.physicalMemoryGB >= 16 ? "plenty" : "enough for E4B")", done: true)
                StepRow(text: "\(ModelDownload.freeDiskBytes() / 1_000_000_000) GB free · needs 10 GB", done: ModelDownload.freeDiskBytes() > 10_000_000_000)
            } }.frame(width: 560)
        case 3:
            h1("Then, the brain.")
            lead("Reading and filtering happen on your Mac. Deciding what matters and drafting takes a bigger model. Use your own key — only short, scrubbed summaries ever reach it.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(BrainEngine.allCases, id: \.self) { e in
                    Button { m.brainConfig.engine = e; m.brainConfig.model = e.defaultModel; m.saveBrain() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Circle().stroke(m.brainConfig.engine == e ? t.accent : t.ink3, lineWidth: 1.5).background(Circle().fill(m.brainConfig.engine == e ? t.accent : .clear)).frame(width: 16, height: 16).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) { Text(e.displayName).fontWeight(.semibold); Text(e == .none ? "Notes only for now." : (e == .custom ? "Fully offline · simpler cards" : "Your own API key")).font(.system(size: 11)).foregroundStyle(t.ink2) }; Spacer()
                        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(t.card)).overlay(RoundedRectangle(cornerRadius: 10).stroke(m.brainConfig.engine == e ? t.accent : t.cardBorder))
                    }.buttonStyle(.plain)
                }
            }
            if let k = m.brainConfig.engine.keyName, m.brainConfig.engine != .custom {
                HStack { SecureField(BrainFactory.hasKey(m.brainConfig.engine) ? "•••••••• (saved)" : "Paste your \(m.brainConfig.engine.displayName) key", text: $key).textFieldStyle(.roundedBorder).frame(width: 360)
                    BButton(title: "Save", kind: .primary) { Keychain.set(k, key); key = ""; m.rebuildBrain(); Task { await m.validateBrain() } }
                    Text(m.brainStatus).font(.system(size: 11)).foregroundStyle(t.ink2) }
            }
        case 4:
            h1("What should it read?")
            lead("Start small. You can add more later. Chats stay off until you pick them one by one in Settings.")
            CardBox(padding: 0) { VStack(spacing: 0) {
                ForEach(m.allSources, id: \.id) { s in
                    SettingRow(title: s.descriptor.name, detail: s.descriptor.detail) { Toggle2(on: Binding(get: { m.enabledSources.contains(s.id) }, set: { _ in m.toggleSource(s.id) })) }.padding(.horizontal, 16); Divider()
                }
                SettingRow(title: "Work apps", detail: "Slack, Linear, Notion, Granola, Drive, GitHub — next build, through MCP") { Chip(text: "coming soon") }.padding(.horizontal, 16)
            } }.frame(width: 600)
        case 5:
            h1("macOS will ask you a few things.")
            lead("Each one is a switch in System Settings. Brownie opens the right pane; you flip it. Nothing is granted without you.")
            VStack(spacing: 10) {
                permRow(.fullDiskAccess, "Full Disk Access", "To read Messages, WhatsApp and Notes databases.")
                permRow(.accessibility, "Accessibility", "So Hands can click and type in your apps when you ask it to.")
                permRow(.screenRecording, "Screen Recording · optional", "Lets Hands see the window it's working in. Skip it and it works from text alone.")
            }.frame(width: 600)
            CardBox(padding: 12) { HStack(spacing: 12) { Image(systemName: "info.circle").foregroundStyle(t.accentInk); Text("In System Settings, add Brownie to the list and flip the switch, then come back and press Re-check.").font(.system(size: 11)) } }.frame(width: 600)
        case 6:
            h1("Pick a time you're asleep.")
            lead("Brownie wakes your Mac, reads, and puts it back to sleep. It only runs while plugged in and while Brownie is open.")
            CardBox(padding: 0) { VStack(spacing: 0) {
                SettingRow(title: "Every night at", detail: "Takes 20–80 minutes depending on how much came in") { HStack(spacing: 4) { Stepper(String(format: "%02d", m.overnight.hour), value: Binding(get: { m.overnight.hour }, set: { m.overnight.hour = $0; m.saveOvernight() }), in: 0...23); Text(":00") } }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Open Brownie at login", detail: "So it's there at night") { Toggle2(on: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Allow it to wake this Mac", detail: "macOS asks for your password once. A tiny helper holds the Mac awake and lets go the moment the run ends — or if Brownie crashes.") { if m.helperInstalled { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok) } else { BButton(title: "Allow") { m.installHelper() } } }.padding(.horizontal, 16)
            } }.frame(width: 560)
        default:
            HStack(spacing: 12) { Pulse(); h1("Reading, for the first time.") }
            lead("This one runs while you watch. It's catching up on everything, not just last night, so it takes a while. You can open Brownie now; it keeps going.")
            let p = m.progress
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(p.sourceName.isEmpty ? "Starting…" : "\(p.sourceName) · \(p.bucketName)").fontWeight(.semibold); Spacer(); Text(p.itemCount > 0 ? "\(p.itemIndex) of \(p.itemCount)" : "").font(.system(size: 11)).foregroundStyle(t.ink2) }
                ProgressView(value: p.itemCount > 0 ? Double(p.itemIndex) / Double(p.itemCount) : 0).tint(t.accent)
                HStack(spacing: 10) { stat("Kept", p.stats.kept, t.ok); stat("Not worth keeping", p.stats.dropped, t.ink); stat("Sensitive · erased", p.stats.sensitive, t.bad) }
                if let s = p.lastSummary { CardBox(padding: 12) { Text(s).font(.system(size: 12.5)).foregroundStyle(t.ink2).frame(maxWidth: .infinity, alignment: .leading) } }
                if m.modelPath == nil { CautionBanner(text: "The reader hasn't finished downloading. The first read starts once it's here.") }
            }.frame(width: 600)
        }
    }

    var modelLine: String { switch m.modelState { case .downloading(let p): return "\(p.received / 1_000_000) of \(p.total / 1_000_000) MB"; case .done: return "Ready"; case .verifying: return "Verifying…"; case .failed(let e): return "Failed: \(e)"; case .idle: return m.modelPath == nil ? "Not started" : "Ready" } }
    var modelFraction: Double { switch m.modelState { case .downloading(let p): return p.fraction; case .done: return 1; default: return m.modelPath == nil ? 0 : 1 } }
    func h1(_ s: String) -> some View { Text(s).font(.system(size: 26, weight: .bold)).padding(.top, 10) }
    func lead(_ s: String) -> some View { Text(s).font(.system(size: 14)).foregroundStyle(t.ink2).multilineTextAlignment(.center).frame(maxWidth: 560) }
    func pillar(_ icon: String, _ title: String, _ body: String) -> some View { CardBox(padding: 14) { VStack(alignment: .leading, spacing: 6) { Image(systemName: icon).foregroundStyle(t.accentInk); Text(title).fontWeight(.semibold); Text(body).font(.system(size: 11)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity, alignment: .leading) } }
    func stat(_ l: String, _ n: Int, _ c: Color) -> some View { CardBox(padding: 10) { VStack(alignment: .leading, spacing: 2) { Text(l).font(.system(size: 11)).foregroundStyle(t.ink2); Text("\(n)").font(.system(size: 18, weight: .semibold)).foregroundStyle(c) }.frame(maxWidth: .infinity, alignment: .leading) } }
    func permRow(_ p: Permission, _ name: String, _ why: String) -> some View {
        let granted = m.permissions[p] == true
        return CardBox(padding: 14) { HStack(spacing: 14) {
            ZStack { Circle().fill(granted ? t.ok : t.ctl2).frame(width: 22, height: 22); if granted { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
            VStack(alignment: .leading, spacing: 2) { Text(name).fontWeight(.semibold); Text(why).font(.system(size: 11)).foregroundStyle(t.ink2) }; Spacer()
            if !granted { BButton(title: "Open System Settings") { PermissionGuide.shared.show(for: p) { Task { await m.refreshPermissions(); await m.refreshSources() } } } }
            BButton(title: "Re-check", kind: .quiet) { Task { await m.refreshPermissions() } }
        } }
    }
}
