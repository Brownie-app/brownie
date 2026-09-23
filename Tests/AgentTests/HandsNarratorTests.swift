import Testing
@testable import Agent

/// The lines a person reads while Hands works — no tool names, no JSON.
@Suite struct HandsNarratorTests {
    @Test(arguments: [
        ("screen", "{}", "Looking at the screen"),
        ("look", "{}", "Taking a screenshot to see the page"),
        ("list_apps", "{}", "Checking which apps are open"),
        ("open_app", #"{"name":"Google Chrome"}"#, "Opening Google Chrome"),
        ("key", #"{"combo":"cmd+l"}"#, "Pressing ⌘L"),
        ("key", #"{"combo":"cmd+shift+a"}"#, "Pressing ⌘⇧A"),
        ("key", #"{"combo":"return"}"#, "Pressing Return"),
        ("key", #"{"combo":"cmd+`"}"#, "Pressing ⌘`"),
        ("type", #"{"text":"https://mail.google.com"}"#, "Typing “https://mail.google.com”"),
        ("type", #"{"text":"a very long message that goes on and on and on and on and on"}"#, "Typing “a very long message that goes on and on and o…”"),
        ("wait", #"{"seconds":3}"#, "Waiting 3 s for the app to settle"),
        ("wait", "{}", "Waiting 1 s for the app to settle"),
        ("click", #"{"x":10,"y":20}"#, "Clicking on the screen"),
        ("need_user", #"{"what":"the message is ready"}"#, "Stopping — the message is ready"),
        ("done", #"{"summary":"opened the alert"}"#, "Done — opened the alert"),
        ("could_not", #"{"reason":"no such app"}"#, "Couldn't — no such app"),
        ("search_web", #"{"site":"amazon","query":"iphone 17"}"#, "Searching amazon for “iphone 17”"),
        ("press_text", #"{"text":"Add to Cart"}"#, "Pressing “Add to Cart”"),
        ("press_text", #"{"text":"iphone","nth":2,"role":"link"}"#, "Pressing the 2nd “iphone”"),
        ("press_text", #"{"text":"iphone","nth":3}"#, "Pressing the 3rd “iphone”"),
        ("type_into", #"{"field":"Search Amazon","text":"iphone"}"#, "Typing “iphone” into “Search Amazon”"),
        ("scroll", #"{"direction":"down"}"#, "Scrolling down"),
        ("scroll", #"{"direction":"up","amount":3}"#, "Scrolling up ×3"),
        ("something_new", "{}", "Something New"),
    ]) func lines(_ c: (String, String, String)) {
        #expect(HandsNarrator.line(tool: c.0, args: c.1) == c.2)
    }

    @Test func numberedElementsGetTheirTitle() {
        let names = [7: "Address and search bar", 8: ""]
        #expect(HandsNarrator.line(tool: "press", args: #"{"id":7}"#, label: { names[$0] ?? "" }) == "Pressing “Address and search bar”")
        #expect(HandsNarrator.line(tool: "press", args: #"{"id":8}"#, label: { names[$0] ?? "" }) == "Pressing element 8")
        #expect(HandsNarrator.line(tool: "set_value", args: #"{"id":7,"text":"https://vercel.com/dashboard"}"#, label: { names[$0] ?? "" }) == "Filling “Address and search bar” with “https://vercel.com/dashboard”")
    }

    @Test func keyNames() {
        #expect(HandsNarrator.keys("ctrl+alt+delete") == "⌃⌥Delete")
        #expect(HandsNarrator.keys("tab") == "Tab")
        #expect(HandsNarrator.keys("") == "a key")
        #expect(HandsNarrator.keys("cmd+down") == "⌘↓")
    }
}
