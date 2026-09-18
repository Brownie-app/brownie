import SwiftUI
import Support
import Knowledge
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
    let tabs = ["Sources", "Knowledge", "Brain", "Proactive & Hands", "Privacy & Cloud", "Overnight", "Household", "About"]
    @State private var tab = "Sources"

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Settings") { Segmented(options: tabs, selection: $tab) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "Knowledge": KnowledgePane()
                    case "Brain": BrainPane()
                    case "Proactive & Hands": ProactivePane()
                    case "Privacy & Cloud": PrivacyPane()
                    case "Overnight": OvernightPane()
                    case "Household": HouseholdPane()
                    case "About": AboutPane()
                    default: SourcesPane()
                    }
                }.frame(maxWidth: 760, alignment: .leading).padding(EdgeInsets(top: 24, leading: 28, bottom: 40, trailing: 28))
            }
        }.onAppear { tab = tabs[min(m.settingsTab, tabs.count - 1)] }.onChange(of: m.settingsTab) { _, v in tab = tabs[min(v, tabs.count - 1)] }
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
                ForEach(personal, id: \.id) { s in
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
                    firstReadLine(s.id)
                    if s.id != personal.last?.id { Divider() }
                }
            }
        }.walkthroughTarget("sources")
        Text("Things you said out loud").font(.system(size: 14, weight: .semibold)).padding(.top, 10)
        Sub(text: "Transcribed on this Mac with Apple's speech engine, at night. Transcripts are kept as notes; the audio is never copied and never leaves.")
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                ForEach(spoken, id: \.id) { s in
                    SettingRow(title: s.descriptor.name, detail: detail(s)) {
                        if s.id == "recordings" { BButton(title: "Choose folder", kind: .quiet) { chooseRecordingsFolder() } }
                        if m.permissions[.speech] != true, m.enabledSources.contains(s.id) { BButton(title: "Allow speech") { Task { _ = await SpeechTranscriber.requestAccess(); await m.refreshPermissions(); await m.refreshSources() } } }
                        Toggle2(on: Binding(get: { m.enabledSources.contains(s.id) }, set: { _ in m.toggleSource(s.id) }))
                    }.padding(.horizontal, 16)
                    firstReadLine(s.id)
                    if s.id != spoken.last?.id { Divider() }
                }
            }
        }
        Text("About 1 minute per 10 minutes of audio — a 1-hour call is read in about 6 minutes. Every recording is transcribed once.").font(.system(size: 11)).foregroundStyle(t.ink2)
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
        Text("Work chat").font(.system(size: 14, weight: .semibold)).padding(.top, 10)
        Sub(text: "Signed in as you, read on this Mac, summaries only. Channels are off until you pick them. Brownie keeps only what concerns you — a request of you, a promise you made, a decision you were part of.")
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                ForEach(workChat, id: \.id) { s in
                    SettingRow(title: s.descriptor.name, detail: detail(s)) {
                        if s.id == "slack" {
                            if case .needsSignIn = m.availability[s.id] { BButton(title: "Paste a token", kind: .quiet) { showSlackToken = true }; BButton(title: "Sign in with Slack") { m.signInSlack() } }
                            else if m.availability[s.id] == .available { BButton(title: "Sign out", kind: .quiet) { m.signOutSlack() } }
                        }
                        if s.id == "teams" {
                            if case .needsSignIn = m.availability[s.id] { BButton(title: "Sign in with Microsoft") { m.signInMicrosoft() } }
                            else if m.availability[s.id] == .available { BButton(title: "Sign out", kind: .quiet) { m.signOutMicrosoft() } }
                        }
                        Toggle2(on: Binding(get: { m.enabledSources.contains(s.id) }, set: { _ in m.toggleSource(s.id) }))
                    }.padding(.horizontal, 16)
                    firstReadLine(s.id)
                    if s.id != workChat.last?.id { Divider() }
                }
            }
        }
        .sheet(isPresented: $showSlackToken) { SlackTokenSheet().environmentObject(m).environment(\.theme, t) }
        Text("Work apps").font(.system(size: 14, weight: .semibold)).padding(.top, 10)
        Sub(text: "Other work apps connect through an MCP server — your org's, or the vendor's. They're read exactly the same way: on this Mac, summaries only.")
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
    static let spokenIDs: Set<SourceID> = ["voicememos", "recordings"], workChatIDs: Set<SourceID> = ["slack", "teams"]
    var personal: [any Source] { m.allSources.filter { !Self.spokenIDs.contains($0.id) && !Self.workChatIDs.contains($0.id) } }
    var workChat: [any Source] { m.allSources.filter { Self.workChatIDs.contains($0.id) } }
    @State private var showSlackToken = false
    var spoken: [any Source] { m.allSources.filter { $0.id == "voicememos" || $0.id == "recordings" } }
    func chooseRecordingsFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.directoryURL = m.recordingsFolder
        if p.runModal() == .OK, let u = p.url { m.setRecordingsFolder(u) }
    }
    /// Under a source that is on: what its first read covers, and the quiet way to ask for more of the past.
    @ViewBuilder func firstReadLine(_ id: SourceID) -> some View {
        if m.enabledSources.contains(id), let line = FirstRead.current.describe(for: id) {
            HStack(alignment: .center) {
                Text(line).font(.system(size: 11)).foregroundStyle(t.ink2)
                Spacer()
                BButton(title: "Read further back", kind: .quiet) { m.readFurtherBack(id) }
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
    func detail(_ s: any Source) -> String {
        if s.id == "voicememos" || s.id == "recordings", m.availability[s.id] == .available {
            let c = m.audioCost[s.id] ?? (0, 0)
            let where_ = s.id == "recordings" ? m.recordingsFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") + " · " : ""
            return where_ + VoiceCost.line(count: c.count, seconds: c.seconds)
        }
        switch m.availability[s.id] {
        case .notInstalled: return "\(s.descriptor.name) isn't on this Mac"
        case .needsPermission(let p): return p == .speech ? "Needs Speech Recognition — turn it on and allow when asked" : "Needs \(p == .fullDiskAccess ? "Full Disk Access" : p.rawValue) — grant it in Settings → Privacy"
        case .unavailable(let why): return why
        case .needsSignIn:
            if s.id == "slack" { return "Sign in as you · DMs and channels you choose" }
            if s.id == "teams" { return "Sign in with your work account · chats and channels you choose · needs your admin's consent once" }
            return s.id == "telegram" ? "Sign in with your own phone number" : "Sign in with your own Google account · read-only"
        default:
            if s.id == "files" { return m.fileRoots.map(\.lastPathComponent).joined(separator: ", ") }
            if s.descriptor.supportsPerBucketOptIn { return "\(m.enabledBuckets[s.id]?.count ?? 0) \(Self.workChatIDs.contains(s.id) ? "conversations" : "chats") chosen" }
            return s.descriptor.detail
        }
    }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { m.addFileRoot(u) } }
    }
}

// MARK: Knowledge

struct KnowledgePane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Your notes are a vault")
        Sub(text: "Plain Markdown files with [[wikilinks]]. Open them in Obsidian, keep them on your phone, edit them anywhere — Brownie merges what it learns into what you wrote.")
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Where the vault lives", detail: "\(m.knowledge.rootURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) · \(m.folders.reduce(0) { $0 + $1.notes.count }) notes") { BButton(title: "Show in Finder", kind: .quiet) { NSWorkspace.shared.open(m.knowledge.rootURL) } }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Open in Obsidian", detail: Vault.obsidianInstalled ? "Adds the vault to Obsidian once; after that it's just there. Backlinks, graph and search work on Brownie's notes." : "Obsidian isn't installed. It's free — obsidian.md.") {
                if Vault.obsidianInstalled { BButton(title: "Open in Obsidian") { Vault.openInObsidian(m.knowledge.rootURL) } } else { BButton(title: "Get Obsidian", kind: .quiet) { NSWorkspace.shared.open(URL(string: "https://obsidian.md")!) } }
            }.padding(.horizontal, 16); Divider()
            SettingRow(title: "iCloud Drive", detail: Vault.icloudFolder == nil ? "iCloud Drive is off on this Mac." : "A copy in iCloud Drive/Brownie so Obsidian on your iPhone has it. Two-way: what you edit on the phone comes back here and Brownie merges it, and Today.md carries the morning's cards as checkboxes — tick one on the phone and it's done here. Apple's sync, Apple's encryption; nothing of Brownie's online.") {
                Segmented(options: ["Off", "To the phone", "Two-way"], selection: Binding(get: { m.icloudMode == "twoway" ? "Two-way" : (m.icloudMode == "mirror" ? "To the phone" : "Off") }, set: { m.setICloudMode($0 == "Two-way" ? "twoway" : ($0 == "To the phone" ? "mirror" : "off")) })).disabled(Vault.icloudFolder == nil)
            }.padding(.horizontal, 16); Divider()
            if m.icloudMode == "twoway" {
                SettingRow(title: m.lastSync.map { "Last sync · \(DateFormatter.localizedString(from: $0.at, dateStyle: .none, timeStyle: .short))" } ?? "Not synced yet", detail: m.lastSync?.line ?? "Runs after every read and every 15 minutes while Brownie is open.") { HStack(spacing: 8) { if m.lastSync != nil { HStack(spacing: 6) { Circle().fill(t.ok).frame(width: 7, height: 7); Text("In sync").font(.system(size: 12, weight: .medium)) } }; BButton(title: "Sync now", kind: .quiet) { m.syncNow() } } }.padding(.horizontal, 16); Divider()
                SettingRow(title: "When both sides changed the same note", detail: "Brownie keeps both: what you wrote on the phone stays as the note; its own version goes under a “Brownie's version” heading for you to pick from. Your words are never overwritten.") { EmptyView() }.padding(.horizontal, 16); Divider()
            }
            SettingRow(title: "Wikilinks between notes", detail: "[[Priya]] instead of plain text, so people, groups and trips connect — here and in Obsidian. Always on.") { Toggle2(on: .constant(true)).disabled(true) }.padding(.horizontal, 16)
        } }
        VaultHealthCard()
        MCPSection()
    }
}

/// Last night's measure of the vault: the sentence, then the lists behind it, each row opening its note.
struct VaultHealthCard: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        H2(text: "Vault health")
        if let h = m.vaultHealth {
            Sub(text: "\(h.line) · measured \(DateFormatter.localizedString(from: h.at, dateStyle: .medium, timeStyle: .none))\(h.netWordsPerWeek.map { " · \($0 >= 0 ? "+" : "")\($0) words this week" } ?? "")\(h.oldestPendingDays.map { " · oldest open ask \($0) days" } ?? "")")
            CardBox(padding: 0) { VStack(alignment: .leading, spacing: 0) {
                section("Largest notes", h.largest.map { ($0.path, "\($0.words) words") })
                if !h.overBudget.isEmpty { Divider(); section("Over budget", h.overBudget.map { ($0.path, "\($0.words) words · budget \(budget($0.path))") }) }
                if !h.quietPeople.isEmpty { Divider(); section("Quiet people — nothing new in \(VaultHealth.quietAfterDays) days", h.quietPeople.map { ($0, "") }) }
                if !h.danglingLinks.isEmpty { Divider(); section("Dangling links — [[names]] with no note", h.danglingLinks.map { ($0.path, "[[\($0.name)]]") }) }
                if !h.duplicateSuspects.isEmpty { Divider(); section("May be one person", h.duplicateSuspects.flatMap { [($0.a, "with \(name($0.b))"), ($0.b, "with \(name($0.a))")] }) }
            } }
        } else {
            Sub(text: "Measured after the first overnight run: notes, words, what is over budget, links that lead nowhere, people who may be written twice.")
        }
    }
    func name(_ path: String) -> String { String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "") }
    func budget(_ path: String) -> Int { path == "README.md" ? VaultHealth.readmeBudget : (path.hasPrefix("People/") || path.hasPrefix("Groups/") ? VaultHealth.personBudget : VaultHealth.noteBudget) }
    @ViewBuilder func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: title).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Button { m.openNote(r.0) } label: {
                    HStack { Text(name(r.0)).fontWeight(.medium); if !r.1.isEmpty { Text(r.1).font(.system(size: 11)).foregroundStyle(t.ink2) }; Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(t.ink2) }
                        .padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.bottom, 8)
    }
}

struct MCPSection: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    var body: some View {
        H2(text: "Let your other AIs read your notes").padding(.top, 10)
        Sub(text: "Brownie can be the memory for Claude, Cursor and other MCP apps on this Mac. It runs on this Mac only: no server, no account, no address on the internet. Each app starts Brownie itself and asks it directly; only the notes it asks for go to that app, on this machine.")
        CardBox(padding: 0) {
            SettingRow(title: "Answer other apps", detail: m.mcpEnabled ? "On. Every question is logged below." : "Off — nothing can read a thing, even apps already set up.") { Toggle2(on: Binding(get: { m.mcpEnabled }, set: { m.setMCP($0) })) }.padding(.horizontal, 16)
        }
        CardBox(padding: 0) { VStack(spacing: 0) {
            app("Claude Desktop", initials: "C", color: Color(hex: 0xD97757), detail: "Claude's desktop app on this Mac.")
            Divider()
            app("Cursor", initials: "Cu", color: Color(hex: 0x1D1D1F), detail: "For code work that needs to know who people are.")
            Divider()
            SettingRow(title: "ChatGPT", detail: "Its connectors need an address on the internet — Brownie won't give it one. The ChatGPT app's “Work with apps” can read Brownie's window instead.") { Text("Not possible").font(.system(size: 12)).foregroundStyle(t.ink2) }.padding(.horizontal, 16)
            Divider()
            SettingRow(title: "Any other MCP app", detail: "Paste this into its MCP config. It starts Brownie on demand; nothing listens on a port.") { BButton(title: "Copy config", kind: .quiet) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MCPServer.configSnippet(executable: m.mcpExecutable, client: "an app"), forType: .string); m.announcement = "Config copied." } }.padding(.horizontal, 16)
        } }
        Text("Tools: search_notes · read_note · who_is · open_loops · recent_cards. Notes the reader marked sensitive were never written, so they can't answer, whatever an app asks.").font(.system(size: 11)).foregroundStyle(t.ink2)
        HStack { H2(text: "What they asked"); Spacer(); BButton(title: "Refresh", kind: .quiet) { Task { await m.reloadMCPAsks() } } }.padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            if m.mcpAsks.isEmpty { Text("Nothing yet. Questions from other apps appear here with the notes they got, kept 30 days.").font(.system(size: 12)).foregroundStyle(t.ink2).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(m.mcpAsks.prefix(30)) { a in
                HStack(spacing: 12) {
                    Text(Self.tf.string(from: a.at)).font(.system(size: 11)).foregroundStyle(t.ink2).frame(width: 90, alignment: .leading)
                    Text("\(a.client) · \(a.tool)\(a.query.isEmpty ? "" : " “\(a.query)”")").lineLimit(1)
                    Spacer(); Text(a.result).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
                }.padding(.horizontal, 16).frame(height: 34); Divider()
            }
        } }
    }
    func app(_ name: String, initials: String, color: Color, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 9).fill(color).frame(width: 36, height: 36); Text(initials).font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) { Text(name).fontWeight(.medium); Text(m.mcpInstalled(name) ? "Set up · restart \(name) if it doesn't show Brownie yet" : detail).font(.system(size: 11)).foregroundStyle(t.ink2) }
            Spacer()
            if m.mcpInstalled(name) { HStack(spacing: 6) { Circle().fill(t.ok).frame(width: 7, height: 7); Text("Set up").font(.system(size: 12, weight: .medium)) } }
            else { BButton(title: "Set up") { m.installMCP(name) } }
        }.padding(.horizontal, 16).padding(.vertical, 10)
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
        if m.brainConfig.engine == .local {
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { Image(systemName: "lock.fill").foregroundStyle(t.ok); Text("This Mac only — what changes").fontWeight(.semibold) }
                    Text("Cards: fewer and plainer; drafts are shorter; no Hands (it needs a model with tools). Notes: the same, since the reader was always local. Speed: the overnight run takes about twice as long. “What left your Mac” reads 0 bytes, every night.").font(.system(size: 12)).foregroundStyle(t.ink2)
                    kv("Status") { Text(m.modelPath == nil ? "The reader isn't downloaded yet" : "Ready · \(m.readerChoice)") }
                }
            }
        }
        if m.brainConfig.engine != .none && m.brainConfig.engine != .local {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    kv("Status") { HStack(spacing: 8) { Text(m.brainStatus); BButton(title: "Check", kind: .quiet) { Task { await m.validateBrain() } } } }
                    kv("Model") { TextField("model id", text: $m.brainConfig.model).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { m.saveBrain() } }
                    if m.brainConfig.engine == .custom { kv("Endpoint") { TextField("http://127.0.0.1:1234/v1", text: $m.brainConfig.customBaseURL).textFieldStyle(.roundedBorder).frame(width: 300).onSubmit { m.saveBrain() } } }
                    if let k = m.brainConfig.engine.keyName, m.brainConfig.engine != .custom {
                        kv("API key") { HStack { SecureField(BrainFactory.hasKey(m.brainConfig.engine) ? "•••••••• (saved)" : "paste your key", text: $key).textFieldStyle(.roundedBorder).frame(width: 300); BButton(title: "Save to Keychain") { m.saveKeyAndCheck(k, key); key = "" } } }
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
        switch e { case .openai: return "Recommended · your OpenAI key · drafts, cards, Hands"; case .anthropic: return "Your Anthropic key · official computer use"; case .openrouter: return "Any model, your key"; case .custom: return "LM Studio or any local server · ₹0 · simpler cards"; case .local: return "Nothing leaves, ever · the reader doubles as the brain · plainer cards, no Hands"; case .none: return "Notes only. No cards, no drafts, no Hands." }
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
                SettingRow(title: "Cards per morning", detail: "Fewer is better. It shows less if there's less.") { Segmented(options: ["3", "5", "8"], selection: Binding(get: { "\(m.cardsPerMorning)" }, set: { m.cardsPerMorning = Int($0) ?? 5; m.set(SettingKey.cardsPerMorning, $0) })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "A note counts as evidence for", detail: "The quiet check before cards show: a card standing only on notes older than this is dropped; one partly on them is marked. Closed loops and missing files are dropped either way.") { Segmented(options: ["3 days", "7 days", "14 days", "30 days"], selection: Binding(get: { "\(m.staleDays) days" }, set: { m.setStaleDays(Int($0.split(separator: " ").first ?? "7") ?? 7) })) }.padding(.horizontal, 16)
            }
        }
        H2(text: "Standing instructions").padding(.top, 6)
        Sub(text: "Plain words. Read every night before it decides what to show you.")
        TextEditor(text: $m.instructions).font(.system(size: 13)).frame(minHeight: 90).padding(8).scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 6).fill(t.code))
            .onChange(of: m.instructions) { _, v in m.set(SettingKey.standingInstructions, v) }
        H2(text: "What your thumbs-downs taught").padding(.top, 6)
        Sub(text: m.feedback.isEmpty ? "Nothing yet. On any card, “Not right…” with a reason — Brownie keeps the lesson and reads it every night." : "Read every night after your standing instructions. Remove one and the lesson is forgotten.")
        if !m.feedback.isEmpty {
            CardBox(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(m.feedback.reversed().prefix(30)) { fb in
                        SettingRow(title: "\(fb.verdict.label)\(fb.person.map { " · \($0)" } ?? "")", detail: "“\(fb.cardTitle)”\(fb.note.isEmpty ? "" : " — \(fb.note)") · \(fb.at.formatted(date: .abbreviated, time: .omitted))") { BButton(title: "Remove", kind: .quiet) { m.forgetFeedback(fb.id) } }.padding(.horizontal, 16)
                        Divider()
                    }
                    if !m.learnedInstructions.isEmpty { Text(m.learnedInstructions).font(.system(size: 12, design: .monospaced)).foregroundStyle(t.ink2).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(t.code) }
                }
            }
        }
        H2(text: "You").padding(.top, 10)
        CardBox(padding: 0) {
            SettingRow(title: "Your name", detail: "As people write it in chats. Brownie never makes a person of you: a loop or a note in your name is caught, and what is about you goes to the README.") {
                TextField("Vivek Upreti", text: Binding(get: { m.userName }, set: { m.userName = $0 })).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { m.set(SettingKey.userName, m.userName.trimmingCharacters(in: .whitespaces)); m.rebuildCoordinatorForSelf() }
            }.padding(.horizontal, 16)
        }
        H2(text: "Sign-off").padding(.top, 10)
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "Sign what Brownie drafts", detail: "Messages and mails Brownie prepares end with a rule and “\(Signature.shown)”. You still press Send; you can delete the line before you do.") {
                    Toggle2(on: Binding(get: { m.signMessages }, set: { m.signMessages = $0; m.set(SettingKey.signature, $0 ? "true" : "false") }))
                }.padding(.horizontal, 16)
                if m.signMessages {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hi Kanika, quick update on the licence — sending it by Thursday.").font(.system(size: 12.5))
                        Text(Signature.line).font(.system(size: 12.5)).foregroundStyle(t.ink2)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(t.code)
                }
            }
        }
        H2(text: "Hands").padding(.top, 10)
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "Hold to talk", detail: "Hold the key, say what you want done, let go") { Segmented(options: ["Right ⌘", "Right ⌥", "Off"], selection: Binding(get: { m.handsHotkey == "rightCommand" ? "Right ⌘" : (m.handsHotkey == "rightOption" ? "Right ⌥" : "Off") }, set: { v in m.handsHotkey = v == "Right ⌘" ? "rightCommand" : (v == "Right ⌥" ? "rightOption" : "off"); m.set(SettingKey.handsHotkey, m.handsHotkey) })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Speed vs. care", detail: "Care re-reads the screen before every step") { Segmented(options: ["Fast", "Balanced", "Careful"], selection: Binding(get: { m.handsSpeed.capitalized }, set: { m.handsSpeed = $0.lowercased(); m.set(SettingKey.handsSpeed, m.handsSpeed); m.rebuildBrain() })) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Always ask before sending, paying, or deleting", detail: "Always on. Hands pauses and leaves the button to you.") { Toggle2(on: .constant(true)).disabled(true) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Accessibility", detail: m.permissions[.accessibility] == true ? "Granted" : "Needed so Hands can click and type in your apps") { if m.permissions[.accessibility] != true { BButton(title: "Open System Settings") { PermissionProbe.openSettings(for: .accessibility) } } }.padding(.horizontal, 16)
            }
        }
        H2(text: "Before meetings").padding(.top, 10)
        CardBox(padding: 0) {
            SettingRow(title: "A brief ten minutes before each meeting", detail: "Who's in the room, what they expect, open loops with them — from your People notes. Needs Calendar and a brain.") { Toggle2(on: Binding(get: { m.briefsEnabled }, set: { m.setBriefs($0) })) }.padding(.horizontal, 16)
        }
        H2(text: "Hands, from anywhere").padding(.top, 10)
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "⌘⇧Space command bar", detail: "Type a recipe's name or a new goal. Hold right ⌘ to talk.") { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok) }.padding(.horizontal, 16); Divider()
                SettingRow(title: "Apple Shortcuts and Siri", detail: "Any recipe is a link: brownie://run?recipe=<name>. In Shortcuts, “Open URLs” with that link, name the shortcut, and “Hey Siri, <name>” runs it. brownie://ask?text=… asks Brownie.") { BButton(title: "Open Shortcuts", kind: .quiet) { NSWorkspace.shared.open(URL(string: "shortcuts://")!) } }.padding(.horizontal, 16)
            }
        }
        H2(text: "How Hands gets into each app").padding(.top, 10)
        Sub(text: "Most reliable way first; the screen is the last resort, and you can forbid it per app.")
        CardBox(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(ladderApps.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 12) {
                        Text(a.0).fontWeight(.medium).frame(width: 110, alignment: .leading)
                        HStack(spacing: 6) { Rung(a.1, on: true); if a.2 { Rung("Screen", on: !m.screenForbidden.contains(a.0)) } else { Rung("Never needs the screen", on: false) } }
                        Spacer()
                        if a.2 { Toggle2(on: Binding(get: { !m.screenForbidden.contains(a.0) }, set: { m.setScreen(a.0, allowed: $0) })); Text("screen").font(.system(size: 11)).foregroundStyle(t.ink2) }
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                    if i < ladderApps.count - 1 { Divider() }
                }
            }
        }
    }
    var ladderApps: [(String, String, Bool)] { [("WhatsApp", "App link", true), ("Messages", "AppleScript", false), ("Mail", "AppleScript", false), ("Calendar", "EventKit", false), ("Notes", "Files", false), ("Slack", "API (MCP)", true), ("Linear", "API (MCP)", false), ("Safari", "AppleScript", true), ("Everything else", "Accessibility tree", true)] }
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
        H2(text: "What leaves this Mac").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Show me what left, every morning", detail: "A line under the cards with last night's bytes, and the full log one click away.") { Toggle2(on: Binding(get: { m.showSendLine }, set: { m.setShowSendLine($0) })) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "The full log", detail: "Every request to the brain, byte for byte, kept 30 days.") { BButton(title: "What left your Mac", kind: .quiet) { m.screen = .sendLog } }.padding(.horizontal, 16)
        } }
        H2(text: "Panic wipe").padding(.top, 6)
        CardBox {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) { Text("Erase everything Brownie knows, right now").fontWeight(.medium); Text("Notes, cards, loops, the send log, recipes, sign-ins, keys, the 3 AM wake. Also in the menu bar, always one click away. No undo, because there is no copy anywhere.").font(.system(size: 11)).foregroundStyle(t.ink2) }
                Spacer(); BButton(title: "Erase everything…", kind: .destructive) { m.panicAsked = true }
            }
        }.overlay(RoundedRectangle(cornerRadius: 10).stroke(t.bad.opacity(0.35)))
        .sheet(isPresented: $m.panicAsked) { Themed { PanicSheet() }.environmentObject(m) }
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

/// Hold to confirm: the button fills over 1.5 s; letting go early cancels.
struct PanicSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var timer: Timer?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { ZStack { Circle().fill(t.bad).frame(width: 28, height: 28); Image(systemName: "trash").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }; Text("Erase everything Brownie knows").font(.system(size: 17, weight: .semibold)) }
            Text("This deletes, right now, on this Mac:").foregroundStyle(t.ink2)
            VStack(alignment: .leading, spacing: 6) {
                row("The knowledge base — every note, every person, every loop")
                row("All cards, the send log and the recipes you taught Hands")
                row("Sign-ins to Gmail and Telegram, and your brain key from the Keychain")
                row("The 3 AM wake and the helper that holds the Mac awake")
            }
            Text("The reader model stays unless you also uninstall. Nothing needs deleting anywhere else — there is nowhere else.").font(.system(size: 11)).foregroundStyle(t.ink2)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(t.bad).frame(height: 36)
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)).frame(width: max(0, 412 * progress), height: 36)
                Text(progress >= 1 ? "Erasing…" : "Hold to erase").foregroundStyle(.white).fontWeight(.semibold).frame(width: 412)
            }.frame(width: 412)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !holding { holding = true; start() } }.onEnded { _ in holding = false; if progress < 1 { timer?.invalidate(); withAnimation { progress = 0 } } })
            HStack { Spacer(); BButton(title: "Keep everything", kind: .quiet) { m.panicAsked = false }; Spacer() }
        }.padding(24).frame(width: 460)
    }
    func row(_ s: String) -> some View { HStack(alignment: .top, spacing: 8) { Circle().fill(t.ctl2).frame(width: 14, height: 14).padding(.top, 2); Text(s).font(.system(size: 13)) } }
    func start() {
        timer?.invalidate(); progress = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { tm in
            Task { @MainActor in
                progress = min(1, progress + 0.05 / 1.5)
                if progress >= 1 { tm.invalidate(); m.panicAsked = false; m.eraseEverything() }
            }
        }
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
            SettingRow(title: "Also during the day", detail: daytimeDetail) { Segmented(options: ["Every hour", "Every 3 hours", "Only at night"], selection: Binding(get: { m.overnight.daytime == "h1" ? "Every hour" : (m.overnight.daytime == "h3" ? "Every 3 hours" : "Only at night") }, set: { m.overnight.daytime = $0 == "Every hour" ? "h1" : ($0 == "Every 3 hours" ? "h3" : "off"); m.saveOvernight() })) }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Only when idle, only on power", detail: "Daytime reads wait until you haven't touched the Mac for \(OvernightScheduler.Config.idleMinutesForDaytime) minutes and it's plugged in, so the reader never competes with you. Always on.") { Toggle2(on: .constant(true)).disabled(true) }.padding(.horizontal, 16); Divider()
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
    var daytimeDetail: String {
        let today = m.runs.filter { $0.trigger == .daytime && Calendar.current.isDateInToday($0.startedAt) }
        let read = today.reduce(0) { $0 + $1.stats.read }
        let base = "Reads what's new while you're away. Cards refresh; nothing is sent."
        return today.isEmpty ? base : base + " Today: \(today.count) check\(today.count == 1 ? "" : "s") · \(read) items read."
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
            VStack(alignment: .leading) { Text("Brownie").font(.system(size: 22, weight: .bold)); Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · Apple silicon · macOS 14 or later").font(.system(size: 11)).foregroundStyle(t.ink2) }
        }
        CardBox { VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Website").frame(width: 130, alignment: .leading).foregroundStyle(t.ink2); Button("usebrownie.com") { NSWorkspace.shared.open(URL(string: "https://usebrownie.com")!) }.buttonStyle(.link) }
            HStack { Text("Source code").frame(width: 130, alignment: .leading).foregroundStyle(t.ink2); Button("github.com/Brownie-app/brownie") { NSWorkspace.shared.open(URL(string: "https://github.com/Brownie-app/brownie")!) }.buttonStyle(.link) }
            kv("Licence", "AGPL-3.0"); kv("Inspired by", "all personal assistant apps and the architecture of Sentient OS"); kv("Made", "with ❤️ in India"); kv("Acknowledgements", "Gemma 4 · LiteRT-LM")
        } }
        H2(text: "Appearance").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Theme", detail: "System follows macOS.") { Segmented(options: ["System", "Light", "Dark"], selection: Binding(get: { m.appearance.capitalized }, set: { m.appearance = $0.lowercased(); m.set(SettingKey.appearance, m.appearance) })) }.padding(.horizontal, 16)
        } }
        H2(text: "Walkthroughs").padding(.top, 6)
        CardBox(padding: 0) { SettingRow(title: "First-time tips", detail: "Each screen's tip plays once and is gone. Bring them back here.") { BButton(title: "Replay") { m.replayWalkthroughs() } }.padding(.horizontal, 16) }
        H2(text: "Help").padding(.top, 6)
        CardBox(padding: 0) { VStack(spacing: 0) {
            SettingRow(title: "Export diagnostics", detail: "A zip on your Desktop with Brownie's logs and a summary of this Mac — no messages, notes or keys, ever. Attach it to a bug report.") { BButton(title: "Export") { m.exportDiagnostics() } }.padding(.horizontal, 16); Divider()
            SettingRow(title: "Report a bug", detail: "Issues live on GitHub. Security problems go through a private advisory instead.") { BButton(title: "Open GitHub", kind: .quiet) { NSWorkspace.shared.open(URL(string: "https://github.com/Brownie-app/brownie/issues/new/choose")!) } }.padding(.horizontal, 16)
        } }
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


/// For workspaces where the Brownie Slack app isn't approved: a user token from the user's own Slack app.
struct SlackTokenSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @State private var token = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a Slack user token").font(.system(size: 17, weight: .semibold))
            Text("Create a Slack app at api.slack.com/apps, add the user scopes channels:history, channels:read, groups:history, groups:read, im:history, im:read, mpim:history, mpim:read, users:read, install it to your workspace, and paste the token that starts with xoxp-. It goes to your Keychain; nothing else sees it.").font(.system(size: 12)).foregroundStyle(t.ink2)
            SecureField("xoxp-…", text: $token).textFieldStyle(.roundedBorder)
            HStack { Spacer(); BButton(title: "Cancel", kind: .quiet) { dismiss() }; BButton(title: "Use token", kind: .primary) { m.useSlackToken(token); dismiss() }.disabled(!token.hasPrefix("xoxp-")) }
        }.padding(20).frame(width: 460)
    }
}


// MARK: Household

/// Two people, two Macs, one shared memory of what they do together. Built for one other person now; the model holds a list.
struct HouseholdPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @State private var name = ""
    @State private var phone = ""
    @State private var folder: URL? = nil
    var body: some View {
        H2(text: "A household"); Sub(text: "Two people, two Macs, one shared memory of the things you do together. Each of you keeps your own Brownie; only the chats you are both in are shared.")
        if let h = m.household {
            CardBox(padding: 18) {
                HStack(spacing: 14) {
                    MemberAvatars(household: h, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sharing with \(h.othersLine)").font(.system(size: 15, weight: .semibold))
                        Text("Since \(h.since.formatted(date: .abbreviated, time: .omitted)) · \(m.householdLastSync.map { "synced \($0.at.formatted(date: .omitted, time: .shortened)) · \($0.line)" } ?? "not synced yet") · folder \(h.folderPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))").font(.system(size: 11)).foregroundStyle(t.ink2)
                    }
                    Spacer()
                    BButton(title: "Sync now", kind: .quiet) { m.householdSyncNow() }
                    BButton(title: "Leave the household", kind: .destructive) { m.leaveHousehold() }
                }
            }
            ForEach(h.others) { o in
                SettingRow(title: o.name, detail: "Their number, so Brownie can tell which group chats they're in") {
                    TextField("+91 …", text: Binding(get: { o.phone.map { "+" + $0 } ?? "" }, set: { m.setHouseholdMemberPhone(o.id, $0) })).textFieldStyle(.roundedBorder).frame(width: 170)
                }
            }
            H2(text: "Shared chats").padding(.top, 6)
            Sub(text: "Only group chats \(h.othersLine) is also in can be shared — Brownie checks the members. Turn one on and both Macs write to the same note; nothing from a chat they aren't in ever crosses over.")
            CardBox(padding: 0) {
                VStack(spacing: 0) {
                    if m.checkingEligible { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking who is in which chat…").font(.system(size: 12)).foregroundStyle(t.ink2) }.padding(14) }
                    else if m.eligibleChats.isEmpty { Text(h.others.allSatisfy { $0.phone == nil } ? "Add \(h.othersLine)'s number above — group chats are matched by it." : "No group chat has \(h.othersLine) in it yet, or WhatsApp / Messages aren't on and read. Settings → Sources.").font(.system(size: 12)).foregroundStyle(t.ink2).padding(14) }
                    ForEach(m.eligibleChats) { b in
                        SettingRow(title: b.name, detail: "\(b.id.rawValue.hasPrefix("whatsapp") ? "WhatsApp" : "Messages") · \(b.detail) · \(h.othersLine) is in it" + (h.isShared(b.id) ? " · shared as Groups/\(b.name).md" : "")) { Toggle2(on: Binding(get: { h.isShared(b.id) }, set: { _ in m.toggleSharedChat(b) })) }.padding(.horizontal, 16)
                        Divider()
                    }
                    SettingRow(title: "Shared calendar", detail: "Events on a calendar you both subscribe to: briefs and due nudges for both of you") { Toggle2(on: Binding(get: { h.calendarShared }, set: { v in var hh = h; hh.calendarShared = v; m.household = hh; m.set(SettingKey.household, m.json(hh)) })) }.padding(.horizontal, 16)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                CardBox(padding: 16) { VStack(alignment: .leading, spacing: 6) { HStack(spacing: 8) { Image(systemName: "lock").foregroundStyle(t.ok); Text("Never shared").fontWeight(.semibold) }; Text("Your direct messages, your mail, your files, your Voice Memos, your People/ notes, your loops with anyone outside the household, and every card about them. \(h.othersLine)'s Brownie never sees them, and yours never sees theirs.").font(.system(size: 12.5)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity, alignment: .leading) }
                CardBox(padding: 16) { VStack(alignment: .leading, spacing: 6) { HStack(spacing: 8) { Image(systemName: "person.2").foregroundStyle(t.accentInk); Text("What crosses over").fontWeight(.semibold) }; Text("Notes about the shared chats, plans you both are part of (Household/), who is handling what, and one line when the other of you already dealt with something — so you don't both reply to the school.").font(.system(size: 12.5)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity, alignment: .leading) }
            }
        } else {
            CardBox(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Start a household").font(.system(size: 15, weight: .semibold))
                    Text("Give the person's name and, so Brownie can tell which group chats they're in, their number. The shared folder lives in iCloud Drive — share it with them through Files › Share so their Mac syncs it too.").font(.system(size: 12.5)).foregroundStyle(t.ink2)
                    HStack(spacing: 10) {
                        TextField("Their name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                        TextField("+91 98450 67890", text: $phone).textFieldStyle(.roundedBorder).frame(width: 170)
                        BButton(title: folder.map { $0.lastPathComponent } ?? "Folder: iCloud Drive/Brownie Household", kind: .quiet) { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK { folder = p.url } }
                    }
                    HStack { Spacer(); BButton(title: "Start sharing", kind: .primary) { m.startHousehold(with: name, phone: phone, folder: folder) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
        }
    }
}

struct MemberAvatars: View {
    @Environment(\.theme) var t
    let household: Household
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(household.members) { mm in
                Text(String(mm.firstName.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
                    .frame(width: size, height: size).background(Circle().fill(mm.isMe ? t.accentSoft : Color(hex: 0x5878C8).opacity(0.16))).foregroundStyle(mm.isMe ? t.accentInk : Color(hex: 0x3B5BB5))
                    .overlay(Circle().stroke(t.side, lineWidth: 2))
            }
        }
    }
}
