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
        let ch = SlackParsing.channels(r, names: ["U42": "Lalita Pathak"])
        #expect(ch.map(\.handle) == ["slack:U42", nil, nil])
        #expect(ch[0].name == "Lalita Pathak" && !ch[0].isGroup)
    }

    @Test func teamsOneOnOneChatsCarryTheOtherMembersUserID() {
        let r: [String: Any] = ["value": [
            ["id": "19:a", "chatType": "oneOnOne", "members": [["userId": "me", "displayName": "Ishan"], ["userId": "u-77", "displayName": "Kiran Bose"]]],
            ["id": "19:b", "chatType": "group", "topic": "Launch", "members": [["userId": "me", "displayName": "Ishan"], ["userId": "u-77", "displayName": "Kiran Bose"], ["userId": "u-78", "displayName": "Tanvi"]]],
        ]]
        let chats = TeamsParsing.chats(r, me: "me")
        #expect(chats.map(\.handle) == ["teams:u-77", nil])
        #expect(chats[0].name == "Kiran Bose" && chats[1].name == "Launch" && chats[1].isGroup)
    }
}
