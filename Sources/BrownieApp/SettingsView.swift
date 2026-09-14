import SwiftUI
import Support
import AppKit
import Domain
import Platform
import Brain
import Inference
import Scheduling
import LocalSources
import CloudSources
import TelegramSource

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let tabs = ["Sources", "Brain", "Proactive & Hands", "Privacy & Cloud", "Overnight", "About"]
    @State private var tab = "Sources"

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Settings") { Segmented(options: tabs, selection: $tab) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "Brain": BrainPane()
                    case "Proactive & Hands": ProactivePane()
                    case "Privacy & Cloud": PrivacyPane()
                    case "Overnight": OvernightPane()
                    case "About": AboutPane()
                    default: SourcesPane()
                    }
                }.frame(maxWidth: 760, alignment: .leading).padding(EdgeInsets(top: 24, leading: 28, bottom: 40, trailing: 28))
            }
        }.onAppear { tab = tabs[min(m.settingsTab, tabs.count - 1)] }
    }
}

struct H2: View { let text: String; var body: some View { Text(text).font(.system(size: 17, weight: .semibold)) } }
struct Sub: View { @Environment(\.theme) var t; let text: String; var body: some View { Text(text).foregroundStyle(t.ink2) } }

// MARK: Sources

struct SourcesPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Sources"); Sub(text: "Everything is read on this Mac. Turn a source off and its notes stay; nothing new is read.")
        Text("Personal").font(.system(size: 14, weight: .semibold)).padding(.top, 4)
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                ForEach(m.allSources, id: \.id) { s in
                    let d = s.descriptor
                    SettingRow(title: d.name, detail: detail(s)) {
                        if s.id == "files" { BButton(title: "Choose folders", kind: .quiet) { chooseFolder() } }
                        if s.id == "gmail" {
                            if case .needsSignIn = m.availability[s.id] { BButton(title: "Sign in with Google") { m.signInGoogle() } }
                            else if m.availability[s.id] == .available { BButton(title: "Sign out", kind: .quiet) { m.signOutGoogle() } }
                        }
                        if s.id == "telegram" {
                            if case .needsSignIn = m.availability[s.id] { BButton(title: "Sign in to Telegram") { showTelegram = true } }
                            else if m.availability[s.id] == .available { BButton(title: "Sign out", kind: .quiet) { m.telegramSignOut() } }
                        }
                        if s.id == "calendar", m.permissions[.calendar] != true { BButton(title: "Allow") { Task { _ = await CalendarSource.requestAccess(); await m.refreshPermissions(); await m.refreshSources() } } }
                        Toggle2(on: Binding(get: { m.enabledSources.contains(s.id) }, set: { _ in m.toggleSource(s.id) }))
                    }.padding(.horizontal, 16)
                    if s.id != m.allSources.last?.id { Divider() }
                }
            }
        }.walkthroughTarget("sources")
        ForEach(m.allSources, id: \.id) { s in
            if s.descriptor.supportsPerBucketOptIn, m.enabledSources.contains(s.id), let all = m.discovered[s.id], !all.isEmpty {
                let chosen = m.enabledBuckets[s.id] ?? []
                let buckets = all.filter { chatFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(chatFilter) }.sorted { (chosen.contains($0.id) ? 0 : 1, -$0.count) < (chosen.contains($1.id) ? 0 : 1, -$1.count) }
                HStack { Text(s.id == "files" ? "Folders" : "Chats · \(s.descriptor.name)").font(.system(size: 14, weight: .semibold)); Spacer()
                    if s.id != "files" { Text("\(chosen.count) of \(all.count) chosen").font(.system(size: 11)).foregroundStyle(t.ink2); TextField("Search chats", text: $chatFilter).textFieldStyle(.roundedBorder).frame(width: 180) } }.padding(.top, 10)
                if s.id != "files" { Sub(text: "Off by default. Only the chats you pick are ever read. Chosen chats sort to the top.") }
                CardBox(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(buckets.prefix(60)) { b in
                            SettingRow(title: b.name, detail: s.id == "files" ? b.detail : (b.isGroup ? "\(b.detail) · \(b.count) messages" : "Direct · \(b.count) messages")) {
                                if s.id == "files" { BButton(title: "Remove", kind: .quiet) { m.removeFileRoot(URL(fileURLWithPath: b.detail)) } }
                                else { Toggle2(on: Binding(get: { m.enabledBuckets[s.id]?.contains(b.id) ?? false }, set: { _ in m.toggleBucket(s.id, b.id) })) }
                            }.padding(.horizontal, 16)
                            Divider()
                        }
                        if buckets.count > 60 { Text("Showing 60 of \(buckets.count) — search to find the rest").font(.system(size: 11)).foregroundStyle(t.ink2).padding(12) }
                    }
                }
            }
        }
        Text("Work").font(.system(size: 14, weight: .semibold)).padding(.top, 10)
        Sub(text: "Work apps connect through an MCP server — your org's, or the vendor's. They're read exactly the same way: on this Mac, summaries only.")
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                ForEach(m.mcpManifests) { mf in
                    let sid = SourceID("mcp:\(mf.id)")
                    SettingRow(title: mf.name, detail: mcpDetail(sid, mf)) {
                        BButton(title: "Remove", kind: .quiet) { m.removeMCP(mf.id) }
                        Toggle2(on: Binding(get: { m.enabledSources.contains(sid) }, set: { _ in m.toggleSource(sid) }))
                    }.padding(.horizontal, 16); Divider()
                }
                SettingRow(title: "Add an app through MCP", detail: "Anything with an MCP server: pick a preset or paste an address, add a token, pick what to read") { BButton(title: "Add…") { showAdd = true } }.padding(.horizontal, 16)
            }
        }
        .sheet(isPresented: $showAdd) { AddMCPSheet().environmentObject(m).environment(\.theme, t) }
        .sheet(isPresented: $showTelegram) { TelegramSignIn().environmentObject(m).environment(\.theme, t) }
    }
    @State private var showAdd = false
    @State private var showTelegram = false
    @State private var chatFilter = ""
    func mcpDetail(_ sid: SourceID, _ mf: MCPManifest) -> String {
        switch m.availability[sid] { case .available: return "Connected · \(mf.url)"; case .needsSignIn: return "Token rejected — remove and add again with a valid token"; case .unavailable(let w): return w; default: return mf.url }
    }
    func detail(_ s: any Source) -> String {
        switch m.availability[s.id] {
        case .notInstalled: return "\(s.descriptor.name) isn't on this Mac"
        case .needsPermission(let p): return "Needs \(p == .fullDiskAccess ? "Full Disk Access" : p.rawValue) — grant it in Settings → Privacy"
        case .unavailable(let why): return why
        case .needsSignIn: return s.id == "telegram" ? "Sign in with your own phone number" : "Sign in with your own Google account · read-only"
        default:
            if s.id == "files" { return m.fileRoots.map(\.lastPathComponent).joined(separator: ", ") }
            if s.descriptor.supportsPerBucketOptIn { return "\(m.enabledBuckets[s.id]?.count ?? 0) chats chosen" }
            return s.descriptor.detail
        }
    }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { m.addFileRoot(u) } }
    }
}

// MARK: Brain

struct BrainPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var key = ""
    var body: some View {
        H2(text: "Brain")
        Sub(text: "Your Mac reads and filters everything with a small model that never goes online. The last 10% — building your notes, deciding what matters, drafting — uses a bigger model you pay for directly. Summaries only; never the raw data.")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(BrainEngine.allCases, id: \.self) { e in
                Button { m.brainConfig.engine = e; m.brainConfig.model = e.defaultModel; m.saveBrain() } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Circle().stroke(m.brainConfig.engine == e ? t.accent : t.ink3, lineWidth: 1.5).background(Circle().fill(m.brainConfig.engine == e ? t.accent : .clear)).frame(width: 16, height: 16).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) { Text(e.displayName).fontWeight(.semibold); Text(desc(e)).font(.system(size: 11)).foregroundStyle(t.ink2) }
                        Spacer()
                    }.padding(14).background(RoundedRectangle(cornerRadius: 10).fill(t.card)).overlay(RoundedRectangle(cornerRadius: 10).stroke(m.brainConfig.engine == e ? t.accent : t.cardBorder))
                }.buttonStyle(.plain)
            }
        }
        if m.brainConfig.engine != .none {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    kv("Status") { HStack(spacing: 8) { Text(m.brainStatus); BButton(title: "Check", kind: .quiet) { Task { await m.validateBrain() } } } }
                    kv("Model") { TextField("model id", text: $m.brainConfig.model).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { m.saveBrain() } }
                    if m.brainConfig.engine == .custom { kv("Endpoint") { TextField("http://127.0.0.1:1234/v1", text: $m.brainConfig.customBaseURL).textFieldStyle(.roundedBorder).frame(width: 300).onSubmit { m.saveBrain() } } }
                    if let k = m.brainConfig.engine.keyName, m.brainConfig.engine != .custom {
                        kv("API key") { HStack { SecureField(BrainFactory.hasKey(m.brainConfig.engine) ? "•••••••• (saved)" : "paste your key", text: $key).textFieldStyle(.roundedBorder).frame(width: 300); BButton(title: "Save to Keychain") { Keychain.set(k, key); key = ""; m.rebuildBrain() } } }
                    }
                    kv("What it costs you") { Text(m.lastUsage.map { u in "Last run: \(u.inputTokens / 1000)K in · \(u.outputTokens / 1000)K out on your own key" + (m.brainConfig.engine == .openai ? String(format: " ≈ $%.2f", Double(u.inputTokens) * 1.25e-6 + Double(u.outputTokens) * 10e-6) : "") } ?? "Billed per token on your own key. Shown here after the first run.") }
                }
            }
        }
        H2(text: "On this Mac").padding(.top, 10)
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                kv("Reader") { HStack(spacing: 10) { Segmented(options: ["E4B", "E2B"], selection: Binding(get: { m.readerChoice }, set: { m.chooseReader($0) })); Text(m.modelPath == nil ? "not downloaded" : (m.readerChoice == "E2B" ? "2.5 GB · for 8 GB Macs" : "3.7 GB · GPU")).font(.system(size: 11)).foregroundStyle(t.ink2) } }
                kv("Memory") { Text("\(ModelCatalog.physicalMemoryGB) GB on this Mac") }
                kv("Model files") { HStack { if m.modelPath == nil { BButton(title: "Download", kind: .primary) { Task { await m.download.start() } } }; BButton(title: "Show in Finder", kind: .quiet) { NSWorkspace.shared.open(Paths.models) } } }
                if case .downloading(let p) = m.modelState { ProgressView(value: p.fraction).tint(t.accent) }
            }
        }
    }
    func desc(_ e: BrainEngine) -> String {
        switch e { case .openai: return "Recommended · your OpenAI key · drafts, cards, Hands"; case .anthropic: return "Your Anthropic key · official computer use"; case .openrouter: return "Any model, your key"; case .custom: return "LM Studio or any local server · ₹0 · simpler cards"; case .none: return "Notes only. No cards, no drafts, no Hands." }
    }
    func kv<C: View>(_ k: String, @ViewBuilder _ c: () -> C) -> some View { HStack(alignment: .center) { Text(k).foregroundStyle(t.ink2).frame(width: 160, alignment: .leading); c(); Spacer() } }
}

// MARK: Proactive & Hands

struct ProactivePane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Proactive")
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "Notify me when cards are ready", detail: "One notification, no sound") { Toggle2(on: Binding(get: { m.notify }, set: { m.notify = $0; m.set(SettingKey.notifyOnReady, $0 ? "true" : "false") })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Cards per morning", detail: "Fewer is better. It shows less if there's less.") { Segmented(options: ["3", "5", "8"], selection: Binding(get: { "\(m.cardsPerMorning)" }, set: { m.cardsPerMorning = Int($0) ?? 5; m.set(SettingKey.cardsPerMorning, $0) })) }.padding(.horizontal, 16)
            }
        }
        H2(text: "Standing instructions").padding(.top, 6)
        Sub(text: "Plain words. Read every night before it decides what to show you.")
        TextEditor(text: $m.instructions).font(.system(size: 13)).frame(minHeight: 90).padding(8).scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
            .onChange(of: m.instructions) { _, v in m.set(SettingKey.standingInstructions, v) }
        H2(text: "Hands").padding(.top, 10)
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "Hold to talk", detail: "Hold the key, say what you want done, let go") { Segmented(options: ["Right ⌘", "Right ⌥", "Off"], selection: Binding(get: { m.handsHotkey == "rightCommand" ? "Right ⌘" : (m.handsHotkey == "rightOption" ? "Right ⌥" : "Off") }, set: { v in m.handsHotkey = v == "Right ⌘" ? "rightCommand" : (v == "Right ⌥" ? "rightOption" : "off"); m.set(SettingKey.handsHotkey, m.handsHotkey) })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Speed vs. care", detail: "Care re-reads the screen before every step") { Segmented(options: ["Fast", "Balanced", "Careful"], selection: Binding(get: { m.handsSpeed.capitalized }, set: { m.handsSpeed = $0.lowercased(); m.set(SettingKey.handsSpeed, m.handsSpeed); m.rebuildBrain() })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Always ask before sending, paying, or deleting", detail: "Always on. Hands pauses and leaves the button to you.") { Toggle2(on: .constant(true)).disabled(true) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Accessibility", detail: m.permissions[.accessibility] == true ? "Granted" : "Needed so Hands can click and type in your apps") { if m.permissions[.accessibility] != true { BButton(title: "Open System Settings") { PermissionProbe.openSettings(for: .accessibility) } } }.padding(.horizontal, 16)
            }
        }
    }
}

// MARK: Privacy

struct PrivacyPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Privacy")
        CardBox { VStack(alignment: .leading, spacing: 10) {
            StepRow(text: "Raw messages and files never leave this Mac — only short, scrubbed summaries reach the brain you chose", done: true)
            StepRow(text: "Sensitive things are erased on sight — ID numbers, cards, passwords, medical records: nothing stored, nothing logged", done: true)
            StepRow(text: "No account — there is nothing to sign up for and nothing of yours on any Brownie server", done: true)
        } }
        HStack { H2(text: "Permissions"); Spacer(); BButton(title: "Ask for everything", kind: .primary) { Task { await m.requestAllPermissions() } } }.padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            perm(.fullDiskAccess, "Full Disk Access", "To read Messages, WhatsApp and Notes databases"); Divider()
            perm(.accessibility, "Accessibility", "So Hands can click and type in your apps"); Divider()
            perm(.screenRecording, "Screen Recording", "Optional. Lets Hands see the window it's working in")
        } }
        H2(text: "Share your knowledge base with your other AIs").padding(.top, 6)
        Sub(text: "Coming in v1.1: a sealed copy online so ChatGPT and Claude can read your notes. Sealed on this Mac; the server would hold scrambled bytes and no key. Off until then — there is no Brownie server at all today.")
        H2(text: "Diagnostics").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Send crash reports", detail: "Off. Nothing leaves this Mac.") { Toggle2(on: .constant(false)).disabled(true) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Anonymous usage counts", detail: "Off. Nothing leaves this Mac.") { Toggle2(on: .constant(false)).disabled(true) }.padding(.horizontal, 16)
        } }
        BButton(title: "Open the logs folder", kind: .quiet) { NSWorkspace.shared.open(Paths.logs) }
    }
    func perm(_ p: Permission, _ name: String, _ why: String) -> some View {
        SettingRow(title: name, detail: (m.permissions[p] == true ? "Granted · " : "") + why) {
            if m.permissions[p] == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok) }
            else { BButton(title: "Open System Settings") { PermissionGuide.shared.show(for: p) { Task { await m.refreshPermissions(); await m.refreshSources() } } } }
            BButton(title: "Re-check", kind: .quiet) { Task { await m.refreshPermissions(); await m.refreshSources() } }
        }.padding(.horizontal, 16)
    }
}

// MARK: Overnight

struct OvernightPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Overnight")
        Sub(text: "Brownie wakes your Mac, reads what's new, and puts it back to sleep. Only while plugged in, only while Brownie is open.")
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Run every night", detail: "Lid closed is fine once the wake helper is allowed") { Toggle2(on: Binding(get: { m.overnight.enabled }, set: { m.overnight.enabled = $0; m.saveOvernight() })) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Time", detail: "Pick an hour you're asleep and it's charging") {
                HStack(spacing: 4) {
                    Stepper(String(format: "%02d", m.overnight.hour), value: Binding(get: { m.overnight.hour }, set: { m.overnight.hour = $0; m.saveOvernight() }), in: 0...23)
                    Text(":"); Stepper(String(format: "%02d", m.overnight.minute), value: Binding(get: { m.overnight.minute }, set: { m.overnight.minute = $0; m.saveOvernight() }), in: 0...59, step: 15)
                }
            }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Open Brownie at login", detail: "So it's around at \(String(format: "%d:%02d", m.overnight.hour, m.overnight.minute))") { Toggle2(on: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) })) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "If a night is missed", detail: "Run as soon as you're plugged in") { Toggle2(on: Binding(get: { m.overnight.catchUp }, set: { m.overnight.catchUp = $0; m.saveOvernight() })) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Allow Brownie to wake this Mac", detail: m.helperInstalled ? "Allowed. A tiny helper holds the Mac awake during the run and lets go the moment it ends — or if Brownie crashes." : "macOS asks for your password once. Without it the Mac must already be awake at the scheduled time.") {
                if m.helperInstalled { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok) } else { BButton(title: "Allow") { m.installHelper() } }
            }.padding(.horizontal, 16)
        } }
        H2(text: "Health · last 7 runs").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            HStack { th("When", 150); th("Trigger", 90); th("Read", 60); th("Kept", 60); th("Took", 70); th("Result", 0) }.padding(.horizontal, 12).frame(height: 32); Divider()
            if m.runs.isEmpty { Text("No runs yet.").foregroundStyle(t.ink2).padding(16) }
            ForEach(m.runs) { r in
                HStack { td(r.startedAt.formatted(date: .abbreviated, time: .shortened), 150); td(r.trigger.rawValue, 90); td("\(r.stats.read)", 60); td("\(r.stats.kept)", 60); td(took(r), 70); Text(outcome(r)).foregroundStyle(color(r)).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(size: 12.5)).padding(.horizontal, 12).frame(height: 34); Divider()
            }
        } }
        HStack { BButton(title: "Open scheduler log", kind: .quiet) { NSWorkspace.shared.open(Paths.logs.appendingPathComponent("scheduler.log")) }; BButton(title: "Run now", kind: .quiet) { m.analyzeNow(trigger: .test) }; BButton(title: "Test wake in 2 minutes") { Task { m.announcement = await m.scheduler?.testWake() } } }
    }
    func th(_ s: String, _ w: CGFloat) -> some View { Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink2).frame(width: w == 0 ? nil : w, alignment: .leading).frame(maxWidth: w == 0 ? .infinity : nil, alignment: .leading) }
    func td(_ s: String, _ w: CGFloat) -> some View { Text(s).lineLimit(1).frame(width: w, alignment: .leading) }
    func took(_ r: RunRecord) -> String { guard let e = r.endedAt else { return "…" }; return "\(Int(e.timeIntervalSince(r.startedAt) / 60)) min" }
    func outcome(_ r: RunRecord) -> String {
        switch r.outcome { case .ran(let n): return "Ran · \(n) cards"; case .skippedOnBattery: return "Skipped · on battery"; case .cancelled: return "Stopped"; case .failedReader: return "Reader failed"; case .failedBrain(let f): return "Brain: \(f.rawValue)"; case .partial(let s): return "Partial · \(s)"; case nil: return "Running…"; default: return "Skipped" }
    }
    func color(_ r: RunRecord) -> Color { switch r.outcome { case .ran: return t.ok; case nil: return t.ink2; case .skippedOnBattery, .partial: return t.warn; default: return t.bad } }
}

// MARK: About

struct AboutPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var confirmUninstall = false
    var body: some View {
        HStack(spacing: 16) {
            DawnMark(size: 64)
            VStack(alignment: .leading) { Text("Brownie").font(.system(size: 22, weight: .bold)); Text("Version 0.1 · Apple silicon · macOS 14 or later").font(.system(size: 11)).foregroundStyle(t.ink2) }
        }
        CardBox { VStack(alignment: .leading, spacing: 10) {
            kv("Source code", "[your-repo-url]"); kv("Licence", "[LICENCE] · inspired by the architecture of Sentient OS"); kv("Acknowledgements", "Gemma 4 · LiteRT-LM")
        } }
        H2(text: "Appearance").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Theme", detail: "System follows macOS.") { Segmented(options: ["System", "Light", "Dark"], selection: Binding(get: { m.appearance.capitalized }, set: { m.appearance = $0.lowercased(); m.set(SettingKey.appearance, m.appearance) })) }.padding(.horizontal, 16)
        } }
        H2(text: "Walkthroughs").padding(.top, 6)
        CardBox(padding: 0) { SettingRow(title: "First-time tips", detail: "Each screen's tip plays once and is gone. Bring them back here.") { BButton(title: "Replay") { m.replayWalkthroughs() } }.padding(.horizontal, 16) }
        H2(text: "Leave").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Reset and start over", detail: "Keeps your settings and keys, forgets everything it learned") { BButton(title: "Reset") { m.factoryReset() } }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Uninstall completely", detail: "Removes the model, the knowledge base, the wake helper, the login item and the keys, then quits. There was never an account to close.") { BButton(title: "Uninstall", kind: .destructive) { confirmUninstall = true } }.padding(.horizontal, 16)
        } }
        .alert("Remove everything Brownie made?", isPresented: $confirmUninstall) { Button("Uninstall", role: .destructive) { m.uninstall() }; Button("Cancel", role: .cancel) {} }
    }
    func kv(_ k: String, _ v: String) -> some View { HStack { Text(k).foregroundStyle(t.ink2).frame(width: 160, alignment: .leading); Text(v) } }
}


struct AddMCPSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @State private var preset: MCPManifest = MCPPresets.all[0]
    @State private var url = MCPPresets.all[0].url
    @State private var token = ""
    @State private var listTool = MCPPresets.all[0].listTool
    @State private var getTool = MCPPresets.all[0].getTool ?? ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            H2(text: "Add an app through MCP")
            Sub(text: "Pick a preset or describe the server. Brownie reads with the list tool, opens items with the get tool, and judges them on this Mac.")
            HStack { ForEach(MCPPresets.all) { p in Button(p.name) { preset = p; url = p.url; listTool = p.listTool; getTool = p.getTool ?? "" }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(preset.id == p.id ? t.accentSoft : t.chip)).foregroundStyle(preset.id == p.id ? t.accentInk : t.ink2) } }
            field("Server URL", $url); field("Token (optional)", $token, secure: true); field("List tool", $listTool); field("Get tool (blank if the list has the content)", $getTool)
            HStack { Spacer(); BButton(title: "Cancel", kind: .quiet) { dismiss() }; BButton(title: "Add", kind: .primary) {
                var mf = preset; mf.url = url; mf.listTool = listTool; mf.getTool = getTool.isEmpty ? nil : getTool
                m.addMCP(mf, token: token); dismiss()
            } }
        }.padding(24).frame(width: 560).foregroundStyle(t.ink).background(t.content)
    }
    func field(_ label: String, _ b: Binding<String>, secure: Bool = false) -> some View {
        HStack { Text(label).foregroundStyle(t.ink2).frame(width: 220, alignment: .leading); if secure { SecureField("", text: b).textFieldStyle(.roundedBorder) } else { TextField("", text: b).textFieldStyle(.roundedBorder) } }
    }
}


struct TelegramSignIn: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @State private var phone = "+91 "
    @State private var code = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var sentTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack { Circle().fill(Color(hex: 0x2AABEE)).frame(width: 34, height: 34); Image(systemName: "paperplane.fill").foregroundStyle(.white).font(.system(size: 15)) }
                VStack(alignment: .leading, spacing: 2) { H2(text: "Sign in to Telegram"); Text("Your own account, on this Mac. Nothing goes through a Brownie server — there isn't one.").font(.system(size: 12)).foregroundStyle(t.ink2) }
            }
            steps
            Divider()
            stepBody
            if let error { HStack(spacing: 6) { Image(systemName: "exclamationmark.circle").foregroundStyle(t.bad); Text(error).font(.system(size: 12)).foregroundStyle(t.bad) } }
            HStack { Spacer(); BButton(title: m.telegramAuth == .ready ? "Done" : "Cancel", kind: .quiet) { dismiss(); Task { await m.refreshSources() } } }
        }.padding(24).frame(width: 520).foregroundStyle(t.ink).background(t.content)
        .onChange(of: m.telegramAuth) { _, _ in error = nil; busy = false }
    }

    var stepIndex: Int { switch m.telegramAuth { case .waitingForCode: return 1; case .waitingForPassword: return 2; case .ready: return 3; default: return 0 } }
    var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Phone", "Code", "Password", "Done"].enumerated()), id: \.offset) { i, s in
                HStack(spacing: 6) {
                    ZStack { Circle().fill(i < stepIndex ? t.ok : (i == stepIndex ? t.accent : t.ctl2)).frame(width: 18, height: 18); if i < stepIndex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } else { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(i == stepIndex ? Color(hex: 0x1A1205) : t.ink2) } }
                    Text(s).font(.system(size: 12, weight: i == stepIndex ? .semibold : .regular)).foregroundStyle(i == stepIndex ? t.ink : t.ink2)
                }
                if i < 3 { Rectangle().fill(t.sep).frame(width: 24, height: 1) }
            }
        }
    }

    @ViewBuilder var stepBody: some View {
        switch m.telegramAuth {
        case .waitingForPhone, .waitingForParameters:
            VStack(alignment: .leading, spacing: 8) {
                Text("Phone number, with country code").font(.system(size: 12, weight: .medium))
                HStack { TextField("+91 98450 12345", text: $phone).textFieldStyle(.roundedBorder).frame(width: 240).disabled(busy).onSubmit { sendPhone() }; action("Send code", sendPhone) }
                Text("Telegram sends a code to your other Telegram apps (or by SMS if you have none).").font(.system(size: 11)).foregroundStyle(t.ink2)
            }
        case .waitingForCode:
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the code Telegram sent to \(sentTo.isEmpty ? "your phone" : sentTo)").font(.system(size: 12, weight: .medium))
                HStack { TextField("12345", text: $code).textFieldStyle(.roundedBorder).frame(width: 140).font(.system(size: 18, design: .monospaced)).disabled(busy).onSubmit { sendCode() }; action("Continue", sendCode) }
                Text("Check the Telegram app on your phone — the code arrives as a message from Telegram.").font(.system(size: 11)).foregroundStyle(t.ink2)
            }
        case .waitingForPassword(let hint):
            VStack(alignment: .leading, spacing: 8) {
                Text("Your two-step verification password" + (hint.isEmpty ? "" : "  ·  hint: \(hint)")).font(.system(size: 12, weight: .medium))
                HStack { SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 240).disabled(busy).onSubmit { sendPassword() }; action("Sign in", sendPassword) }
            }
        case .ready:
            HStack(spacing: 10) { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok).font(.system(size: 18)); VStack(alignment: .leading) { Text("Signed in").fontWeight(.semibold); Text("Pick the chats to read in Settings → Sources → Telegram. Nothing is read until you do.").font(.system(size: 12)).foregroundStyle(t.ink2) } }
        case .loggedOut: Text("Signed out.")
        case .other(let s): HStack { ProgressView().controlSize(.small); Text("Telegram: \(s)").foregroundStyle(t.ink2) }
        }
    }

    func action(_ title: String, _ f: @escaping () -> Void) -> some View {
        HStack(spacing: 8) { if busy { ProgressView().controlSize(.small) }; BButton(title: busy ? "Waiting…" : title, kind: .primary, action: f).disabled(busy) }
    }
    func sendPhone() { let p = phone.filter { $0.isNumber || $0 == "+" }; guard p.count > 6 else { error = "That doesn't look like a phone number."; return }; busy = true; error = nil; sentTo = p; Task { if let e = await m.telegramPhone(p) { error = Self.plain(e); busy = false } } }
    func sendCode() { let c = code.filter(\.isNumber); guard !c.isEmpty else { error = "Enter the code first."; return }; busy = true; error = nil; Task { if let e = await m.telegramCode(c) { error = Self.plain(e); busy = false } } }
    func sendPassword() { guard !password.isEmpty else { return }; busy = true; error = nil; Task { if let e = await m.telegramPassword(password) { error = Self.plain(e); busy = false } } }

    static func plain(_ e: String) -> String {
        if e.contains("PHONE_CODE_INVALID") { return "That code isn't right. Check the Telegram message on your phone and try again." }
        if e.contains("PHONE_CODE_EXPIRED") { return "That code expired. Go back and request a new one." }
        if e.contains("PHONE_NUMBER_INVALID") { return "Telegram doesn't recognise that number. Include the country code, e.g. +91." }
        if e.contains("PASSWORD_HASH_INVALID") { return "Wrong password." }
        if e.contains("FLOOD") { return "Too many attempts — Telegram asks you to wait a while." }
        if e.contains("UPDATE_APP_TO_LOGIN") { return "Telegram needs a newer client library. Rebuild Brownie." }
        if e.contains("timeout") { return "No answer from Telegram. Check your connection and try again." }
        return e.replacingOccurrences(of: "tdlib(\"", with: "").replacingOccurrences(of: "\")", with: "")
    }
}
