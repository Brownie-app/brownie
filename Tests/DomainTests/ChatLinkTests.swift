import Testing
import Foundation
@testable import Domain

/// "Open the chat" on a person's note: the handle's own address opens the chat; a chat app with no per-person link opens the app.
@Suite struct ChatLinkTests {
    @Test func whatsappThenIMessageBeforeTheRest() {
        #expect(ChatLink.pick(["slack:U123", "imessage:+919540752593", "whatsapp:+919876543210"]) == ChatLink.Pick(app: "whatsapp", address: "+919876543210"), "WhatsApp opens the chat itself, so it wins")
        #expect(ChatLink.pick(["teams:abc", "imessage:meera@icloud.com"]) == ChatLink.Pick(app: "imessage", address: "meera@icloud.com"))
        #expect(ChatLink.pick(["whatsapp:+911111111111", "whatsapp:+912222222222"])?.address == "+911111111111", "the first of equals")
        #expect(ChatLink.pick(["slack:U123"]) == ChatLink.Pick(app: "slack", address: "U123"))
        #expect(ChatLink.pick([]) == nil && ChatLink.pick(["no colon here"]) == nil)
    }

    @Test func theLinkCarriesTheHandlesAddressNotTheName() {
        #expect(ChatLink.url(app: "whatsapp", address: "+91 98765 43210")?.absoluteString == "whatsapp://send?phone=919876543210", "digits only, the way WhatsApp wants them")
        #expect(ChatLink.url(app: "imessage", address: "+919540752593")?.absoluteString == "imessage://919540752593")
        #expect(ChatLink.url(app: "imessage", address: "Meera@iCloud.com")?.absoluteString == "imessage://meera@icloud.com", "an Apple ID opens as itself")
        #expect(ChatLink.url(app: "whatsapp", address: "") == nil, "no address: the caller looks the name up in Contacts instead")
        #expect(ChatLink.url(app: "slack", address: "U123") == nil, "Slack has no per-person link; the app opens")
    }
}
