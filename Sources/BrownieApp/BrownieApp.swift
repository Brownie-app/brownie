import SwiftUI
import AppKit
import Sparkle
import Support

struct BrownieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var hands: HandsController

    init() {
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        _hands = StateObject(wrappedValue: HandsController(model: m))
    }

    var body: some Scene {
        WindowGroup("Brownie") {
            Themed {
                if model.onboardingDone { RootView() } else { OnboardingView() }
            }
            .environmentObject(model)
            .sheet(isPresented: $hands.showCommandBar) { Themed { CommandBar(controller: hands) }.environmentObject(model) }
            .onAppear {
                hands.start(); Notifier.requestPermission(); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                Notifier.install(model: model)
                if let i = CommandLine.arguments.firstIndex(of: "--hands"), i + 1 < CommandLine.arguments.count { let g = CommandLine.arguments[i + 1]; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { hands.run(g) } }
                // dev: drive the Telegram sign-in from the command line (--tg-phone +91…, --tg-code 12345, --tg-password …)
                for (flag, f) in [("--tg-phone", model.telegramPhone), ("--tg-code", model.telegramCode), ("--tg-password", model.telegramPassword)] as [(String, (String) async -> String?)] {
                    if let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count { let v = CommandLine.arguments[i + 1]; Task { try? await Task.sleep(nanoseconds: 4_000_000_000); let e = await f(v); Log("telegram.dev").info("\(flag): \(e ?? "ok")") } }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Brownie") {
                Button("Analyze now") { model.analyzeNow() }.keyboardShortcut("r", modifiers: [.command])
                Button("Command bar") { hands.showCommandBar = true }.keyboardShortcut(.space, modifiers: [.command, .shift])
                Button("Settings…") { model.overlay = .none; model.screen = .settings }.keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button("Check for Updates…") { updater.checkForUpdates(nil) }.disabled(!updater.updater.canCheckForUpdates)
            }
        }
        MenuBarExtra { MenuBarMenu().environmentObject(model).environmentObject(hands) } label: { Image(nsImage: menuBarGlyph) }
    }
}

/// Sparkle: silent background updates once SUFeedURL + SUPublicEDKey are in Info.plist
/// (Scripts/sparkle-keys.sh). Without them it stays quiet.
let updater = SPUStandardUpdaterController(startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, updaterDelegate: nil, userDriverDelegate: nil)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }   // the menu bar process lives on for 3 AM
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular) }
}

struct MenuBarMenu: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var hands: HandsController
    var body: some View {
        Text(m.sidebarStatus.0 + " · " + m.sidebarStatus.1)
        Divider()
        ForEach(m.cards.prefix(3)) { c in Button(c.title) { open(); m.overlay = .card(c.id) } }
        if m.cards.count > 3 { Text("+ \(m.cards.count - 3) more in For You") }
        Divider()
        Button("Open Brownie") { open() }
        Button("Command bar") { open(); hands.showCommandBar = true }
        Button(m.isRunning ? "Reading…" : "Analyze now") { m.analyzeNow() }.disabled(m.isRunning)
        Divider()
        Button("Settings…") { open(); m.overlay = .none; m.screen = .settings }
        Button("Quit Brownie (no run tonight)") { NSApp.terminate(nil) }
    }
    func open() { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.title == "Brownie" || $0.contentView != nil }?.makeKeyAndOrderFront(nil) }
}


/// Resolves the theme from the appearance setting + the system scheme, and paints ink/background so
/// text is never invisible in dark mode.
struct Themed<Content: View>: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.colorScheme) var scheme
    @ViewBuilder var content: Content
    var theme: Theme { m.appearance == "dark" || (m.appearance == "system" && scheme == .dark) ? .dark : .light }
    var body: some View {
        content.environment(\.theme, theme).foregroundStyle(theme.ink).background(theme.content)
            .preferredColorScheme(m.appearance == "system" ? nil : (m.appearance == "dark" ? .dark : .light))
    }
}

/// The B from the icon as a template image, so it follows the menu bar's light/dark rendering.
let menuBarGlyph: NSImage = {
    let url = Bundle.module.url(forResource: "MenuBar", withExtension: "png", subdirectory: "Resources") ?? Bundle.module.url(forResource: "MenuBar", withExtension: "png")
    let img = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brownie")!
    if let url2 = Bundle.module.url(forResource: "MenuBar@2x", withExtension: "png", subdirectory: "Resources") ?? Bundle.module.url(forResource: "MenuBar@2x", withExtension: "png"), let rep = NSImageRep(contentsOf: url2) { img.addRepresentation(rep) }
    img.size = NSSize(width: 18, height: 18); img.isTemplate = true
    return img
}()
