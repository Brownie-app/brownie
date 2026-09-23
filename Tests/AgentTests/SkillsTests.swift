import Testing
import Foundation
@testable import Agent

func el(_ id: Int, _ role: String, _ title: String, value: String = "", x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 100, h: CGFloat = 20) -> UISnapshot.Element {
    UISnapshot.Element(id: id, role: role, title: title, value: value, frame: CGRect(x: x, y: y, width: w, height: h), actions: [], depth: 1)
}

@Suite struct BrowserSkillTests {
    @Test func addresses() {
        #expect(BrowserSkill.normalise("amazon.com") == "https://amazon.com")
        #expect(BrowserSkill.normalise(" https://vercel.com/dashboard ") == "https://vercel.com/dashboard")
        #expect(BrowserSkill.normalise("iphone 16 price") == "https://www.google.com/search?q=iphone%2016%20price", "words become a search")
        #expect(BrowserSkill.normalise("localhost") == "https://www.google.com/search?q=localhost")
    }
    @Test func loadedMeansATitleThatIsNeitherBlankNorTheOldOne() {
        #expect(!BrowserSkill.loaded(title: "New Tab - Google Chrome", before: ""))
        #expect(!BrowserSkill.loaded(title: "Brownie — a house spirit", before: "Brownie — a house spirit"))
        #expect(BrowserSkill.loaded(title: "Amazon.com. Spend less.", before: "New Tab - Google Chrome"))
        #expect(BrowserSkill.isBrowser("Google Chrome") && BrowserSkill.isBrowser("safari") && !BrowserSkill.isBrowser("WhatsApp"))
    }
}

@Suite struct ChatWindowCheckTests {
    let win = el(1, "Window", "WhatsApp", x: 0, y: 0, w: 1000, h: 800)
    @Test func theHeaderNamesThePerson() {
        let snap = UISnapshot(app: "WhatsApp", window: "WhatsApp", elements: [win, el(2, "StaticText", "Kanika Pandey Loadmill", x: 400, y: 30), el(3, "StaticText", "Rohan", x: 20, y: 300), el(4, "TextArea", "", x: 400, y: 740, w: 500, h: 40)])
        #expect(ChatWindowCheck.headerNames(snap, person: "Kanika Pandey"))
        #expect(ChatWindowCheck.headerNames(snap, person: "kanika"))
        #expect(!ChatWindowCheck.headerNames(snap, person: "Rohan"), "a name in the chat list on the left is not the open chat")
        #expect(!ChatWindowCheck.headerNames(UISnapshot(app: "WhatsApp", window: "", elements: []), person: "Kanika"))
    }
    @Test func theComposerIsTheLabelledBoxOrTheWideOneAtTheBottom() {
        let labelled = UISnapshot(app: "Messages", window: "", elements: [win, el(2, "TextField", "Search", x: 20, y: 20), el(3, "TextArea", "iMessage", x: 300, y: 740, w: 600, h: 30)])
        #expect(ChatWindowCheck.composer(in: labelled)?.id == 3)
        let unlabelled = UISnapshot(app: "WhatsApp", window: "", elements: [win, el(2, "TextField", "Search", x: 20, y: 20), el(3, "TextArea", "", x: 300, y: 100, w: 200, h: 30), el(4, "TextArea", "", x: 300, y: 750, w: 600, h: 30)])
        #expect(ChatWindowCheck.composer(in: unlabelled)?.id == 4, "the wide box near the bottom, never the search field")
        #expect(ChatWindowCheck.composer(in: UISnapshot(app: "x", window: "", elements: [win, el(2, "TextField", "Search")])) == nil)
    }
}

@Suite struct TypingAndFindingTests {
    @Test func typingLanded() {
        #expect(TypingCheck.landed(expected: "https://www.amazon.com", value: "https://www.amazon.com"))
        #expect(TypingCheck.landed(expected: "Hi Kanika, quick update on the licence", value: "hi kanika, quick"))
        #expect(!TypingCheck.landed(expected: "iphone", value: "Brownie — a house spirit"))
        #expect(TypingCheck.landed(expected: "", value: "anything"))
    }
    @Test func findMatchesWordsInLabelsValuesOrRole() {
        let snap = UISnapshot(app: "Chrome", window: "Amazon.com : iphone", elements: [el(1, "Button", "Add to Cart"), el(2, "TextField", "Search Amazon", value: "iphone"), el(3, "Link", "Apple iPhone 16 Pro"), el(4, "Button", "Bookmark this tab")])
        #expect(snap.matching("add to cart").map(\.id) == [1])
        #expect(snap.matching("iphone").map(\.id) == [2, 3])
        #expect(snap.matching("button").map(\.id) == [1, 4])
        #expect(snap.contains("Amazon.com") && !snap.contains("checkout"))
        #expect(snap.matching("  ").isEmpty)
    }
    @Test func narratorSpeaksTheNewTools() {
        #expect(HandsNarrator.line(tool: "plan", args: #"{"steps":["a","b"]}"#) == "Planning the steps")
        #expect(HandsNarrator.line(tool: "open_url", args: #"{"url":"https://amazon.com"}"#) == "Going to amazon.com")
        #expect(HandsNarrator.line(tool: "open_chat", args: #"{"app":"WhatsApp","name":"Kanika"}"#) == "Opening the WhatsApp conversation with Kanika")
        #expect(HandsNarrator.line(tool: "wait_for", args: #"{"text":"Add to Cart"}"#) == "Waiting for “Add to Cart” to appear")
        #expect(HandsNarrator.line(tool: "type_message", args: #"{"text":"Hi"}"#) == "Putting the message in the box: “Hi”")
    }
}

@Suite struct StaleElementTests {
    @Test func aThrownAwayElementIsFoundAgainByRoleTitleAndPlace() {
        let want = el(7, "TextField", "Address and search bar", x: 200, y: 60, w: 800, h: 30)
        let fresh = [el(1, "Button", "Back", x: 20, y: 60), el(2, "TextField", "Address and search bar", x: 210, y: 62, w: 790, h: 30), el(3, "TextField", "Address and search bar", x: 210, y: 400, w: 790, h: 30)]
        #expect(AXSession.rematch(want, in: fresh)?.id == 2, "the one in the same place, not the one further down")
        #expect(AXSession.rematch(el(9, "Button", "Add to Cart"), in: fresh) == nil)
        let blank = el(4, "TextArea", "", x: 300, y: 750, w: 600, h: 30)
        #expect(AXSession.rematch(blank, in: [el(1, "TextArea", "", x: 305, y: 752, w: 600, h: 30)])?.id == 1)
        #expect(AXSession.rematch(blank, in: [el(1, "TextArea", "", x: 305, y: 100, w: 600, h: 30)]) == nil, "a nameless box far away is a different box")
    }
}
