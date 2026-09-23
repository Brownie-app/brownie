import Testing
import Foundation
@testable import CloudSources
import Domain

/// Direct chats carry the other person's stable id as a `PersonHandle`; groups and channels carry none.
@Suite struct HandleTests {
    @Test func slackDirectMessagesCarryTheUserID() {
        let r: [String: Any] = ["channels": [
            ["id": "D1", "is_im": true, "user": "U42"],
            ["id": "C1", "name": "general", "num_members": 9],
            ["id": "G1", "is_mpim": true, "name": "mpdm-alice--bob-1"],
        ]]
        let ch = SlackParsing.channels(r, names: ["U42": "Kanika Pandey"])
        #expect(ch.map(\.handle) == ["slack:U42", nil, nil])
        #expect(ch[0].name == "Kanika Pandey" && !ch[0].isGroup)
    }

    @Test func teamsOneOnOneChatsCarryTheOtherMembersUserID() {
        let r: [String: Any] = ["value": [
            ["id": "19:a", "chatType": "oneOnOne", "members": [["userId": "me", "displayName": "Vivek"], ["userId": "u-77", "displayName": "Arjun Mehta"]]],
            ["id": "19:b", "chatType": "group", "topic": "Launch", "members": [["userId": "me", "displayName": "Vivek"], ["userId": "u-77", "displayName": "Arjun Mehta"], ["userId": "u-78", "displayName": "Priya"]]],
        ]]
        let chats = TeamsParsing.chats(r, me: "me")
        #expect(chats.map(\.handle) == ["teams:u-77", nil])
        #expect(chats[0].name == "Arjun Mehta" && chats[1].name == "Launch" && chats[1].isGroup)
    }
}
