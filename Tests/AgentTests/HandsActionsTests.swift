import Testing
import Foundation
@testable import Agent

/// A click the model gives in screenshot pixels has to land on the screen: the window's origin and the capture scale
/// (2× on Retina, then downsized) both move it.
@Suite struct ScreenMapTests {
    @Test func aRetinaWindowAwayFromTheOrigin() {
        // a 1000×625 pt window at (100, 50) captured at 2× is 2000×1250 px, downsized to 1400×875 for the model
        let map = ScreenMap(windowBounds: CGRect(x: 100, y: 50, width: 1000, height: 625), imageSize: CGSize(width: 1400, height: 875))
        #expect(map.toScreen(CGPoint(x: 0, y: 0)) == CGPoint(x: 100, y: 50), "the image's corner is the window's corner")
        #expect(map.toScreen(CGPoint(x: 700, y: 437.5)) == CGPoint(x: 600, y: 362.5), "the middle of the image is the middle of the window")
        #expect(map.toScreen(CGPoint(x: 1400, y: 875)) == CGPoint(x: 1100, y: 675))
        #expect(map.covers(CGPoint(x: 1120, y: 413)) && !map.covers(CGPoint(x: 1500, y: 10)) && !map.covers(CGPoint(x: -1, y: 10)))
        #expect(map.note == "Screenshot of the window, 1400×875. Give click coordinates in this image.")
    }
    @Test func aSecondDisplayWithANegativeOrigin() {
        let map = ScreenMap(windowBounds: CGRect(x: -1440, y: 200, width: 1440, height: 900), imageSize: CGSize(width: 1400, height: 875))
        #expect(map.toScreen(CGPoint(x: 0, y: 0)) == CGPoint(x: -1440, y: 200))
        let far = map.toScreen(CGPoint(x: 1400, y: 875))
        #expect(abs(far.x - 0) < 0.001 && abs(far.y - 1100) < 0.001)
        let mid = map.toScreen(CGPoint(x: 700, y: 437.5))
        #expect(abs(mid.x - -720) < 0.001 && abs(mid.y - 650) < 0.001)
    }
    @Test func aOneToOneCaptureIsAPureOffset() {
        let map = ScreenMap(windowBounds: CGRect(x: 20, y: 30, width: 800, height: 600), imageSize: CGSize(width: 800, height: 600))
        #expect(map.toScreen(CGPoint(x: 400, y: 300)) == CGPoint(x: 420, y: 330))
        #expect(ScreenMap(windowBounds: .zero, imageSize: .zero).toScreen(CGPoint(x: 5, y: 6)) == CGPoint(x: 5, y: 6), "an empty map leaves the point alone")
    }
}

/// Before and after an action, the cheap fingerprint says what moved.
@Suite struct ScreenSignatureTests {
    @Test func whatChangedReadsInPlainWords() {
        let before = ScreenSignature(window: "Amazon.com : iphone", focus: "TextField “Search Amazon”", atPoint: "Link “Apple iPhone 17 Pro”")
        #expect(before.changes(since: before).isEmpty)
        let title = ScreenSignature(window: "Amazon.com: Apple iPhone 17 Pro", focus: "TextField “Search Amazon”", atPoint: "Link “Apple iPhone 17 Pro”")
        #expect(title.changes(since: before) == ["the window is now “Amazon.com: Apple iPhone 17 Pro”"])
        let focus = ScreenSignature(window: before.window, focus: "", atPoint: "Link “Apple iPhone 17 Pro”")
        #expect(focus.changes(since: before) == ["nothing has focus now"])
        let gone = ScreenSignature(window: before.window, focus: before.focus, atPoint: "")
        #expect(gone.changes(since: before) == ["what was there is gone"])
        let other = ScreenSignature(window: before.window, focus: "Button “Add to Cart”", atPoint: "Image “”")
        #expect(other.changes(since: before) == ["focus is now Button “Add to Cart”", "what sits there is now Image “”"])
        #expect(ScreenSignature(window: before.window, focus: before.focus, atPoint: nil).changes(since: before).isEmpty, "no probe, no verdict on the point")
        #expect(before.line == "window “Amazon.com : iphone” · focus TextField “Search Amazon”")
    }
}

/// AXPress when it answers; a real click on the numbered frame when it does not; a plain no when the frame is gone or
/// off the window.
@Suite struct PressPlanTests {
    let win = CGRect(x: 0, y: 0, width: 1400, height: 900)
    let frame = CGRect(x: 100, y: 300, width: 200, height: 40)
    @Test func decisions() {
        #expect(PressPlan.decide(axPress: true, frame: frame, window: win) == .pressed)
        #expect(PressPlan.decide(axPress: false, frame: frame, window: win) == .click(CGPoint(x: 200, y: 320)), "AXPress refused → the frame's middle")
        #expect(PressPlan.decide(axPress: nil, frame: frame, window: win) == .click(CGPoint(x: 200, y: 320)), "no element or no Press action → the frame's middle")
        #expect(PressPlan.decide(axPress: nil, frame: frame, window: nil) == .click(CGPoint(x: 200, y: 320)), "no window bounds known → still click")
        #expect(PressPlan.decide(axPress: nil, frame: .zero, window: win) == .cannot("it isn't on screen any more; find it again"))
        #expect(PressPlan.decide(axPress: false, frame: .zero, window: win) == .cannot("the press was refused and where it sits is unknown; find it again"))
        let below = CGRect(x: 100, y: 2000, width: 200, height: 40)
        if case .cannot(let why) = PressPlan.decide(axPress: nil, frame: below, window: win) { #expect(why.contains("outside the window") && why.contains("scroll")) } else { Issue.record("a frame below the window must not be clicked") }
        #expect(PressPlan.decide(axPress: true, frame: .zero, window: win) == .pressed, "a successful press needs no frame")
    }

    @Test func theReportSaysWhatHappened() {
        let before = ScreenSignature(window: "Amazon.com : iphone", focus: "TextField “Search Amazon”", atPoint: "Link “Apple iPhone 17 Pro Max”")
        let moved = ScreenSignature(window: "Amazon.com: Apple iPhone 17 Pro Max", focus: "", atPoint: "Image “”")
        let pressed = PressOutcome.report(label: "[11]", role: "Link", title: "Apple iPhone 17 Pro Max", how: .pressed, before: before, after: moved)
        #expect(pressed == "pressed [11] Link “Apple iPhone 17 Pro Max” → the window is now “Amazon.com: Apple iPhone 17 Pro Max”; nothing has focus now; what sits there is now Image “”")
        let clicked = PressOutcome.report(label: "[11]", role: "Link", title: "Apple iPhone 17 Pro Max", how: .clicked, before: before, after: ScreenSignature(window: "Amazon.com: Apple iPhone 17 Pro Max", focus: before.focus, atPoint: before.atPoint))
        #expect(clicked == "clicked the middle of [11] Link “Apple iPhone 17 Pro Max” — the page changed (the window is now “Amazon.com: Apple iPhone 17 Pro Max”)")
        let same = PressOutcome.report(label: "[11]", role: "Link", title: "Apple iPhone 17 Pro Max", how: .clicked, before: before, after: before)
        #expect(same == "clicked the middle of [11] Link “Apple iPhone 17 Pro Max” but nothing changed — it may need scrolling into view, or it is not the thing to press; try press_text with different words or look")
        #expect(same.contains(HandsGuard.stallMarker), "the stall guard counts this exact phrase")
        #expect(PressOutcome.report(label: "[3]", role: "Button", title: "Add to Cart", how: .pressed, before: before, after: before).hasPrefix("pressed [3] Button “Add to Cart” but nothing changed"))
    }
}

/// Which of several matches gets pressed.
@Suite struct PressPickTests {
    @Test func theLinkThatCarriesTheWholePhraseBeatsShorterLinksAndPlainText() {
        let hits = [el(1, "StaticText", "iphone", y: 100), el(2, "Link", "iphone 13", y: 200), el(3, "Link", "Apple iPhone 17 Pro Max, 256GB, Deep Blue", y: 300)]
        #expect(PressPick.choose(hits: hits, text: "Apple iPhone 17")?.id == 3)
        #expect(PressPick.choose(hits: hits, text: "iphone")?.id == 1, "an exact title wins even as plain text")
        #expect(PressPick.choose(hits: hits, text: "iphone", role: .link)?.id == 3, "role link: the chip steps aside for the link with substance")
        #expect(PressPick.choose(hits: hits, text: "iphone", nth: 2, role: .link) == nil, "the chip is not in the ranking at all")
        #expect(PressPick.choose(hits: hits, text: "iphone", role: .button) == nil, "no button says it")
    }
    @Test func aFieldQueryTakesTheFieldOverTheLinkWithTheLongerName() {
        let hits = [el(1, "Link", "Search, option, forward slash", y: 40), el(2, "TextField", "Search Amazon", y: 60)]
        #expect(PressPick.choose(hits: hits, text: "Search", role: .field)?.id == 2)
        #expect(PressPick.choose(hits: hits, text: "Search")?.id == 1, "both carry the phrase and both are pressable: the one higher on the page wins")
        #expect(PressPick.choose(hits: hits, text: "Search", role: .link)?.id == 1)
    }
    /// The Amazon results page as the log showed it: chips above, products below. "iPhone" means a product.
    @Test func onAResultsPageTheFirstResultIsAProductNotAChip() {
        let hits = [el(1, "Link", "iphone 13", y: 120), el(2, "Link", "iphone unlocked", x: 200, y: 120), el(3, "Link", "iphone 16", x: 400, y: 120),
                    el(4, "Link", "Apple iPhone 17 Pro Max, US Version, 256GB, eSIM, Deep Blue- Unlocked", y: 400), el(5, "Link", "Apple iPhone 16, 128GB, Black - Unlocked", y: 700)]
        #expect(PressPick.rank(hits: hits, text: "iPhone", role: .link).map(\.id) == [4, 5], "chips step aside; products in reading order")
        #expect(PressPick.choose(hits: hits, text: "iphone 13", role: .link)?.id == 1, "a chip asked for by its own words is still found")
        #expect(PressPick.rank(hits: hits, text: "Apple iPhone 16").first?.id == 5)
        let noProducts = [el(1, "Link", "iphone 13", y: 120), el(2, "Link", "iphone unlocked", x: 200, y: 120)]
        #expect(PressPick.choose(hits: noProducts, text: "iphone", role: .link)?.id == 1, "with nothing substantive on the page the chips stay in play")
    }
    @Test func tiesGoTopToBottomThenLeftToRight() {
        let hits = [el(1, "Link", "Buy now", x: 500, y: 300), el(2, "Link", "Buy now", x: 100, y: 300), el(3, "Link", "Buy now", x: 100, y: 100)]
        #expect(PressPick.rank(hits: hits, text: "Buy now").map(\.id) == [3, 2, 1])
        #expect(PressPick.choose(hits: hits, text: "buy NOW", nth: 2)?.id == 2, "case and nth")
    }
    @Test func everyWordSomewhereBeatsNoMatchAndRowsSitBetweenLinksAndText() {
        let hits = [el(1, "StaticText", "Deep Blue iPhone 17 Pro", y: 10), el(2, "Row", "iPhone 17 — Deep Blue", y: 20), el(3, "Group", "iphone", y: 30)]
        #expect(PressPick.rank(hits: hits, text: "iPhone 17 Deep Blue").map(\.id) == [2, 1, 3], "the row and the text carry every word; the row is pressable")
        #expect(PressPick.list(hits.prefix(2)) == "[1] StaticText “Deep Blue iPhone 17 Pro”\n[2] Row “iPhone 17 — Deep Blue”")
        #expect(PressPick.list([el(4, "TextField", "Search Amazon", value: "iphone")]) == "[4] TextField “Search Amazon” = iphone")
    }
}

/// Which text box a label means.
@Suite struct FieldPickTests {
    @Test func byLabelPlaceholderOrValue() {
        let hits = [el(1, "Link", "Search, option, forward slash", y: 40), el(2, "TextField", "Search Amazon", y: 60), el(3, "StaticText", "Search Amazon", y: 61), el(4, "TextField", "Address and search bar", y: 20, w: 800)]
        #expect(FieldPick.choose(hits: hits, label: "Search Amazon")?.id == 2, "never the link or the text, even when they say the same")
        #expect(FieldPick.choose(hits: hits, label: "search")?.id == 2, "the shortest title that carries the word")
        #expect(FieldPick.choose(hits: hits, label: "address")?.id == 4)
        #expect(FieldPick.choose(hits: hits, label: "message") == nil)
        #expect(FieldPick.choose(hits: [el(5, "TextArea", "", value: "hi there", y: 700)], label: "hi there")?.id == 5, "a box with no label is known by what is in it")
    }
    @Test func relaxedTakesASharedWordOrTheOnlyField() {
        let one = [el(1, "Button", "Go"), el(2, "TextField", "Where to?", y: 60)]
        #expect(FieldPick.choose(hits: one, label: "destination") == nil)
        #expect(FieldPick.choose(hits: one, label: "destination", relaxed: true)?.id == 2, "the only field there is")
        let two = [el(1, "TextField", "Search the docs", y: 20), el(2, "TextField", "Your email", y: 60)]
        #expect(FieldPick.choose(hits: two, label: "email address", relaxed: true)?.id == 2, "a shared word")
        #expect(FieldPick.choose(hits: two, label: "phone", relaxed: true) == nil, "two fields, no shared word: no guess")
    }
}

/// A site's own search page from a site name and a query.
@Suite struct SearchURLTests {
    @Test func knownSites() {
        #expect(BrowserSkill.searchURL(site: "amazon", query: "iphone 17") == "https://www.amazon.com/s?k=iphone%2017")
        #expect(BrowserSkill.searchURL(site: "Amazon.com", query: "iphone") == "https://www.amazon.com/s?k=iphone")
        #expect(BrowserSkill.searchURL(site: "amazon.in", query: "iphone") == "https://www.amazon.in/s?k=iphone")
        #expect(BrowserSkill.searchURL(site: "https://www.google.com/", query: "brownie app") == "https://www.google.com/search?q=brownie%20app")
        #expect(BrowserSkill.searchURL(site: "youtube", query: "swift testing") == "https://www.youtube.com/results?search_query=swift%20testing")
        #expect(BrowserSkill.searchURL(site: "flipkart", query: "iphone") == "https://www.flipkart.com/search?q=iphone")
        #expect(BrowserSkill.searchURL(site: "wikipedia", query: "house spirit") == "https://en.wikipedia.org/w/index.php?search=house%20spirit")
        #expect(BrowserSkill.searchURL(site: "github", query: "swift-testing") == "https://github.com/search?q=swift-testing")
        #expect(BrowserSkill.searchURL(site: "linkedin", query: "Vivek") == "https://www.linkedin.com/search/results/all/?keywords=Vivek")
        #expect(BrowserSkill.searchURL(site: "x", query: "#swiftlang") == "https://x.com/search?q=%23swiftlang")
        #expect(BrowserSkill.searchURL(site: "twitter.com", query: "a") == "https://x.com/search?q=a")
        #expect(BrowserSkill.searchURL(site: "reddit", query: "macOS") == "https://www.reddit.com/search/?q=macOS")
        #expect(BrowserSkill.searchURL(site: "maps", query: "coffee near me") == "https://www.google.com/maps/search/?api=1&query=coffee%20near%20me")
    }
    @Test func unknownSitesBecomeAScopedGoogleSearch() {
        #expect(BrowserSkill.searchURL(site: "myntra.com", query: "running shoes") == "https://www.google.com/search?q=site%3Amyntra.com%20running%20shoes")
        #expect(BrowserSkill.searchURL(site: "https://www.zomato.com/", query: "pizza") == "https://www.google.com/search?q=site%3Azomato.com%20pizza")
    }
    @Test func theQueryIsEncodedStrictly() {
        #expect(BrowserSkill.searchURL(site: "google", query: "a&b=c+d") == "https://www.google.com/search?q=a%26b%3Dc%2Bd", "& = and + would change the meaning of the URL")
        #expect(BrowserSkill.searchURL(site: "google", query: "  tidy  ") == "https://www.google.com/search?q=tidy")
        #expect(BrowserSkill.searchURL(site: "amazon", query: "café") == "https://www.amazon.com/s?k=caf%C3%A9")
    }
}

/// Five actions the screen ignored end the run; looks and finds in between do not count either way.
@Suite struct StallGuardTests {
    let stalled = "clicked the middle of [11] Link “x” but nothing changed — try something else"
    let moved = "pressed [11] Link “x” → the window is now “y”"
    @Test func fiveIgnoredActionsTripIt() {
        var g = HandsGuard.StallGuard()
        for i in 1...4 { #expect(g.record(tool: "press_text", action: "Pressing “iphone \(i)”", result: stalled) == nil) }
        #expect(g.record(tool: "find", action: "Looking for “iphone”", result: "[12] Link “iphone”") == nil, "a look in between is neither progress nor a stall")
        let why = g.record(tool: "click", action: "Clicking on the screen", result: stalled)
        #expect(why == "the screen stopped responding to what I tried: Pressing “iphone 3”; Pressing “iphone 4”; Clicking on the screen")
        #expect(g.record(tool: "press_text", action: "Pressing “a”", result: stalled) == nil, "the count starts over after it trips")
    }
    @Test func anActionThatChangedSomethingResetsTheStreak() {
        var g = HandsGuard.StallGuard()
        for _ in 1...4 { _ = g.record(tool: "press_text", action: "Pressing “x”", result: stalled) }
        #expect(g.record(tool: "press", action: "Pressing “y”", result: moved) == nil)
        for _ in 1...4 { #expect(g.record(tool: "scroll", action: "Scrolling down", result: "scrolled down but nothing changed at the middle of the window") == nil) }
        #expect(g.record(tool: "type_into", action: "Typing “a” into “b”", result: "typed “a” into the b field but it reads “”; nothing changed") != nil, "the fifth in a row")
    }
    @Test func lookersNeverCount() {
        var g = HandsGuard.StallGuard()
        for _ in 1...10 { #expect(g.record(tool: "wait_for", action: "Waiting", result: "“x” did not appear — nothing changed") == nil) }
        for _ in 1...10 { #expect(g.record(tool: "screen", action: "Looking", result: "nothing changed") == nil) }
    }
}

/// The one line at the end of a run.
@Suite struct HandsRunSummaryTests {
    @Test func toolsAreCountedAndOrderedByUse() {
        var s = HandsRunSummary()
        for t in ["plan", "open_url", "press_text", "press_text", "type_into", "press_text", "done"] { s.record(t) }
        #expect(s.line(turns: 9, outcome: "done(\"the cart shows one iPhone\")") == "run over: 9 turns, 7 tool calls (press_text ×3, done ×1, open_url ×1, plan ×1, type_into ×1) · outcome done(\"the cart shows one iPhone\")")
        #expect(HandsRunSummary().line(turns: nil, outcome: "stopped") == "run over: turns unknown, 0 tool calls · outcome stopped")
    }
}

/// Keys the tool can press, and the ones it must refuse instead of reporting a press that never happened.
@Suite struct KeyParseTests {
    @Test func combos() {
        let l = VirtualInput.parse("cmd+l")
        #expect(l?.code == 37 && l?.flags == .maskCommand)
        let sa = VirtualInput.parse("Cmd+Shift+A")
        #expect(sa?.code == 0 && sa?.flags == [.maskCommand, .maskShift])
        #expect(VirtualInput.parse("pagedown")?.code == 121 && VirtualInput.parse("pageup")?.code == 116, "paging keys exist now — they were silently dropped before")
        #expect(VirtualInput.parse("return")?.flags == [] && VirtualInput.parse("option+left")?.flags == .maskAlternate)
        #expect(VirtualInput.parse("cmd+banana") == nil && VirtualInput.parse("") == nil && VirtualInput.parse("cmd") == nil)
    }
}

/// A stale reference is re-found among deep search hits by role and place.
@Suite struct NearestTests {
    @Test func sameRoleNearestPlaceThenAnything() {
        let want = el(7, "Link", "Apple iPhone 17", x: 300, y: 500)
        let hits = [el(1, "StaticText", "Apple iPhone 17", x: 300, y: 500), el(2, "Link", "Apple iPhone 17", x: 300, y: 900), el(3, "Link", "Apple iPhone 17", x: 310, y: 520)]
        #expect(AXSession.nearest(want, in: hits)?.id == 3)
        #expect(AXSession.nearest(want, in: [hits[0]])?.id == 1, "no link: the first hit rather than nothing")
        #expect(AXSession.nearest(want, in: []) == nil)
    }
}
