import SwiftUI
import AppKit
import Domain
import Brain

struct RootView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.colorScheme) var scheme
    var theme: Theme { m.appearance == "dark" || (m.appearance == "system" && scheme == .dark) ? .dark : .light }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider().overlay(theme.sep)
            ZStack {
                content
                Walkthrough()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.content)
        .environment(\.theme, theme)
        .font(.system(size: 13))
        .foregroundStyle(theme.ink)
        .frame(minWidth: 960, minHeight: 620)
        .overlay(alignment: .top) { if let a = m.announcement { Banner(text: a) { m.announcement = nil } } }
        .overlay { if m.quickOpenShown { QuickOpenPalette() } }
        // ⌘K from any screen: the note palette. An invisible button carries the shortcut; the menu bar is untouched.
        .background(Button("Quick open") { m.quickOpenShown.toggle() }.keyboardShortcut("k", modifiers: .command).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false))
    }

    @ViewBuilder var content: some View {
        switch m.overlay {
        case .card(let id): CardDetailView(cardID: id)
        case .firing(let id): FiringView(cardID: id)
        case .processing: ProcessingView()
        case .letter: LetterView()
        case .weekly: WeeklyView()
        case .brief(let id): BriefView(briefID: id)
        case .teach: TeachView()
        case .recipeRun(let id): RecipeRunView(recipeID: id)
        case .editRecipe(let id): RecipeEditorView(recipeID: id)
        case .none:
            switch m.screen {
            case .forYou: ForYouView()
            case .ask: AskView()
            case .loops: LoopsView()
            case .recipes: RecipesView()
            case .sendLog: SendLogView()
            case .notes: KnowledgeView()
            case .graph: GraphView()
            case .excluded: ExcludedView()
            case .settings: SettingsView()
            }
        }
    }
}

struct Banner: View {
    @Environment(\.theme) var t
    let text: String; let dismiss: () -> Void
    var body: some View {
        HStack { Text(text); Spacer(); BButton(title: "OK", kind: .quiet, action: dismiss) }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(t.accentSoft)).padding(12)
    }
}

struct Sidebar: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 44)
            VStack(alignment: .leading, spacing: 2) {
                item("For You", "sun.max", .forYou, badge: m.cards.isEmpty ? nil : "\(m.cards.count)")
                item("Ask", "bubble.left", .ask)
                item("Loops", "arrow.triangle.2.circlepath", .loops, badge: m.openLoopCount == 0 ? nil : "\(m.openLoopCount)")
                header("Knowledge")
                item("Notes", "book.closed", .notes)
                item("Graph", "point.3.connected.trianglepath.dotted", .graph)
                item("Excluded", "lock", .excluded)
                header("Hands")
                item("Recipes", "hand.raised", .recipes, badge: m.recipeRun.running ? "running" : (m.recipes.isEmpty ? nil : "\(m.recipes.count)"))
                header("App")
                item("Settings", "gearshape", .settings)
            }.padding(.horizontal, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { Pulse(); Text(m.sidebarStatus.0).font(.system(size: 12, weight: .medium)) }
                Text(m.sidebarStatus.1).font(.system(size: 11)).foregroundStyle(t.ink2)
                if m.showSendLine, let s = m.lastNightSend {
                    Button { m.overlay = .none; m.screen = .sendLog } label: {
                        Text(s.requests == 0 ? "0 bytes left your Mac" : "\(s.bytes.formattedBytes) left your Mac · \(s.requests) request\(s.requests == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(t.ink2).underline()
                    }.buttonStyle(.plain)
                }
                if let h = m.household {
                    Button { m.openSettings(.household) } label: {
                        HStack(spacing: 8) { MemberAvatars(household: h, size: 18); Text("Household with \(h.othersLine)" + (m.householdLastSync.map { " · synced \($0.at.formatted(date: .omitted, time: .shortened))" } ?? "")).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1) }
                    }.buttonStyle(.plain)
                }
                Wordmark().padding(.top, 6)
                HStack(spacing: 6) { Image(systemName: "sparkle").font(.system(size: 10)); Text("Brain: \(m.brainName)") }.font(.system(size: 11)).foregroundStyle(t.ink2)
            }.padding(16).overlay(alignment: .top) { Rectangle().fill(t.sep).frame(height: 1) }
        }
        .frame(width: 220).background(t.side)
    }

    func header(_ s: String) -> some View { Text(s.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.ink3).padding(.top, 14).padding(.bottom, 4).padding(.leading, 8) }

    func item(_ title: String, _ icon: String, _ s: AppModel.Screen, badge: String? = nil) -> some View {
        let on = m.screen == s && m.overlay == .none || (s == .forYou && m.overlay != .none)
        return Button { m.overlay = .none; m.screen = s } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? t.accentInk : t.ink2).frame(width: 16)
                Text(title).fontWeight(on ? .medium : .regular)
                Spacer()
                if let badge { Text(badge).font(.system(size: 11)).foregroundStyle(t.ink2) }
            }.padding(.horizontal, 8).frame(height: 28).background(RoundedRectangle(cornerRadius: 6).fill(on ? t.ctl2 : .clear))
        }.buttonStyle(.plain)
    }
}

struct Toolbar<Trailing: View>: View {
    @Environment(\.theme) var t
    let title: String; var subtitle: String = ""; var back: (() -> Void)? = nil; var backLabel = "For You"; @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let back { BButton(title: backLabel, kind: .quiet, systemImage: "chevron.left", action: back) }
            if !title.isEmpty { Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).layoutPriority(1) }
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(t.ink2).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 8)
            trailing
        }.padding(.horizontal, 20).frame(height: 52).overlay(alignment: .bottom) { Rectangle().fill(t.sep).frame(height: 1) }
    }
}


/// The icon's Dawn B beside the lowercase wordmark: a night tile, a cream B whose lower bowl holds the rising sun.
struct Wordmark: View {
    @Environment(\.theme) var t
    var body: some View {
        HStack(spacing: 8) {
            DawnMark(size: 24)
            HStack(spacing: 0) {
                Text("brownie").font(.system(size: 17, weight: .bold)).tracking(-0.4)
                Circle().fill(t.accent).frame(width: 5, height: 5).offset(x: 1, y: -7)
            }
        }.frame(height: 24)
    }
}

/// The app icon (Direction A, "Dawn B") at any size — used in the sidebar and About. Drawn from the same icns the Dock shows.
struct DawnMark: View {
    var size: CGFloat
    private static let image: NSImage = {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources") ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()
    var body: some View {
        Image(nsImage: Self.image).resizable().interpolation(.high).frame(width: size, height: size)
    }
}
