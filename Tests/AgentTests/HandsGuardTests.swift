import Testing
import Foundation
@testable import Agent

/// The rails: no app-switching keys, no wandering into risky apps, no looping on one step.
@Suite struct HandsGuardTests {
    @Test(arguments: ["cmd+space", "Cmd+Tab", "command+q", "cmd+`", "ctrl+left", "cmd+w", "cmd + tab"]) func contextSwitchesAreBlocked(_ combo: String) {
        #expect(HandsGuard.isContextSwitch(combo))
    }
    @Test(arguments: ["cmd+l", "return", "cmd+shift+a", "tab", "escape", "cmd+n", "cmd+f"]) func ordinaryKeysPass(_ combo: String) {
        #expect(!HandsGuard.isContextSwitch(combo))
    }

    @Test func riskyAppsNeedTheGoalToNameThem() {
        #expect(HandsGuard.isOffLimits(app: "Terminal", goal: "Open Kanika's WhatsApp chat and Calendar"))
        #expect(HandsGuard.isOffLimits(app: "System Settings", goal: "book a table"))
        #expect(HandsGuard.isOffLimits(app: "Terminal.app", goal: "reply to Rohan"))
        #expect(!HandsGuard.isOffLimits(app: "Terminal", goal: "open Terminal and run the tests"))
        #expect(!HandsGuard.isOffLimits(app: "Google Chrome", goal: "reply to Rohan"))
        #expect(!HandsGuard.isOffLimits(app: "Calendar", goal: "reply to Rohan"))
    }

    @Test func theThirdIdenticalStepIsCaught() {
        var g = HandsGuard.RepeatGuard()
        let r1 = g.record(tool: "open_app", args: #"{"name":"Google Chrome"}"#); #expect(!r1)
        let r2 = g.record(tool: "screen", args: "{}"); #expect(!r2, "looking is never a repeat")
        let r3 = g.record(tool: "open_app", args: #"{"name":"Google Chrome"}"#); #expect(!r3)
        let r4 = g.record(tool: "wait", args: #"{"seconds":3}"#); #expect(!r4)
        let r5 = g.record(tool: "open_app", args: #"{"name":"Google Chrome"}"#); #expect(r5, "third time in a row")
        let r6 = g.record(tool: "press", args: #"{"id":7}"#); #expect(!r6, "a different step resets the count")
        let r7 = g.record(tool: "press", args: #"{"id":8}"#); #expect(!r7)
        let r8 = g.record(tool: "press", args: #"{"id":7}"#); #expect(!r8, "alternating steps are not a loop")
    }
}

@Suite struct AppLauncherTests {
    @Test func namesResolveToRealApps() {
        #expect(AppLauncher.canonical("Chrome") == "Google Chrome")
        #expect(AppLauncher.canonical("Calendar.app") == "Calendar")
        #expect(AppLauncher.canonical("iMessage") == "Messages")
        #expect(AppLauncher.locate("Calendar")?.path == "/System/Applications/Calendar.app", "system apps live outside /Applications")
        #expect(AppLauncher.locate("calendar") != nil, "case doesn't matter")
        #expect(AppLauncher.locate("Messages") != nil)
        #expect(AppLauncher.locate("com.apple.Safari") != nil, "bundle ids work too")
        #expect(AppLauncher.locate("Definitely Not An App 9000") == nil)
    }
}
