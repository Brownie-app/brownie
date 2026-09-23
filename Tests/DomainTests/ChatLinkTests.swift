import Testing
import Foundation
@testable import Domain

/// "Open the chat" on a person's note: the handle's own address opens the chat; a chat app with no per-person link opens the app.
@Suite struct ChatLinkTests {
    @Test func whatsappThenIMessageBeforeTheRest() {
        #expect(ChatLink.pick(["slack:U123", "imessage:+919000000111", "whatsapp:+919000000666"]) == ChatLink.Pick(app: "whatsapp", address: "+919000000666"), "WhatsApp opens the chat itself, so it wins")
        #expect(ChatLink.pick(["teams:abc", "imessage:meena@icloud.com"]) == ChatLink.Pick(app: "imessage", address: "meena@icloud.com"))
        #expect(ChatLink.pick(["whatsapp:+919000000727", "whatsapp:+919000000726"])?.address == "+919000000727", "the first of equals")
        #expect(ChatLink.pick(["slack:U123"]) == ChatLink.Pick(app: "slack", address: "U123"))
        #expect(ChatLink.pick([]) == nil && ChatLink.pick(["no colon here"]) == nil)
    }

    @Test func theLinkCarriesTheHandlesAddressNotTheName() {
        #expect(ChatLink.url(app: "whatsapp", address: "+91 90000 00666")?.absoluteString == "whatsapp://send?phone=919000000666", "digits only, the way WhatsApp wants them")
        #expect(ChatLink.url(app: "imessage", address: "+919000000111")?.absoluteString == "imessage://919000000111")
        #expect(ChatLink.url(app: "imessage", address: "Meena@iCloud.com")?.absoluteString == "imessage://meena@icloud.com", "an Apple ID opens as itself")
        #expect(ChatLink.url(app: "whatsapp", address: "") == nil, "no address: the caller looks the name up in Contacts instead")
        #expect(ChatLink.url(app: "slack", address: "U123") == nil, "Slack has no per-person link; the app opens")
    }
}
