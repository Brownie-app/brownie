import Testing
import Foundation
@testable import CloudSources
import LocalSources
import Domain

/// What a direct chat proves about the other person — a phone or an email off their profile — rides on the bucket, so
/// the registry can join two chats on proof and never on a name alone.
let slackProfiles = #"""
{"ok":true,"members":[
 {"id":"U1","name":"vivek","profile":{"display_name":"vivek","real_name":"Vivek Upreti","email":"Vivek@Loopsy.in","phone":"+91 95407 52593"}},
 {"id":"U2","name":"meera","profile":{"display_name":"","real_name":"Meera Nair"}},
 {"id":"U3","name":"rohan","profile":{"real_name":"Rohan","phone":"ext. 42","email":""}},
 {"id":"U4","name":"nitesh","profile":{"real_name":"Nitesh","email":"nitesh@loopsy.in"}}],
 "response_metadata":{"next_cursor":""}}
"""#
let slackDMs = #"""
{"ok":true,"channels":[
 {"id":"D1","is_im":true,"user":"U1"},
 {"id":"D2","is_im":true,"user":"U2"},
 {"id":"D3","is_im":true,"user":"U3"},
 {"id":"D4","is_im":true,"user":"U4"},
 {"id":"C1","name":"design","is_channel":true,"num_members":4}],
 "response_metadata":{"next_cursor":""}}
"""#

@Suite struct SlackProofTests {
    @Test func aProfileWithEmailAndPhoneProvesBothSpelledOneWay() {
        let p = SlackParsing.proofs(json(slackProfiles))
        #expect(p["U1"] == ["phone:919540752593", "email:vivek@loopsy.in"], "digits only; lower case")
        #expect(p["U4"] == ["email:nitesh@loopsy.in"])
    }

    @Test func aProfileWithNeitherProvesNothing() {
        let p = SlackParsing.proofs(json(slackProfiles))
        #expect(p["U2"] == nil)
    }

    @Test func aMalformedPhoneProvesNothing() {
        let p = SlackParsing.proofs(json(slackProfiles))
        #expect(p["U3"] == nil, "an extension is not a phone, and an empty email is no email")
    }

    @Test func directChatsCarryTheirProofsAndChannelsNone() {
        let c = SlackParsing.channels(json(slackDMs), names: SlackParsing.users(json(slackProfiles)), proofs: SlackParsing.proofs(json(slackProfiles)))
        #expect(c.map(\.proofs) == [["phone:919540752593", "email:vivek@loopsy.in"], [], [], ["email:nitesh@loopsy.in"], []])
        #expect(c.map(\.handle) == ["slack:U1", "slack:U2", "slack:U3", "slack:U4", nil])
    }

    @Test func discoveryPutsProofsOnTheBucketFromThePagesItAlreadyFetches() async throws {
        let t = FakeTransport().on("auth.test", #"{"ok":true,"user_id":"U9"}"#).on("users.list", slackProfiles).on("conversations.list", slackDMs)
        let b = try await SlackSource(transport: t, token: { "xoxp-1" }).discoverBuckets()
        #expect(b.map(\.proofs) == [["phone:919540752593", "email:vivek@loopsy.in"], [], [], ["email:nitesh@loopsy.in"], []])
        #expect(t.count("users.list") == 1 && t.count("users.info") == 0, "the directory is read once; no call per person")
    }
}

let teamsChatsWithEmail = #"""
{"value":[
 {"id":"19:a","chatType":"oneOnOne","members":[{"userId":"ME","displayName":"Vivek Upreti","email":"vivek@loopsy.in"},{"userId":"U2","displayName":"Meera Nair","email":"Meera.Nair@Loopsy.in"}]},
 {"id":"19:b","chatType":"oneOnOne","members":[{"userId":"ME","displayName":"Vivek Upreti","email":"vivek@loopsy.in"},{"userId":"U3","displayName":"Rohan","email":null}]},
 {"id":"19:c","chatType":"group","topic":"Pricing","members":[{"userId":"ME","displayName":"Vivek Upreti","email":"vivek@loopsy.in"},{"userId":"U2","displayName":"Meera Nair","email":"meera.nair@loopsy.in"}]}]}
"""#
let teamsUserU3 = #"{"id":"U3","mail":"Rohan@Loopsy.in","mobilePhone":"+91 98100 11223","businessPhones":["011 4100 2233","x"]}"#

@Suite struct TeamsProofTests {
    @Test func aOneOnOneChatProvesTheOtherMembersEmail() {
        let c = TeamsParsing.chats(json(teamsChatsWithEmail), me: "ME")
        #expect(c.map(\.proofs) == [["email:meera.nair@loopsy.in"], [], []], "lower-cased; a null email proves nothing; a group proves nothing")
    }

    @Test func aDirectoryRecordProvesItsMailAndEveryPhone() {
        #expect(TeamsParsing.proofs(json(teamsUserU3)) == ["phone:919810011223", "phone:1141002233", "email:rohan@loopsy.in"], "a one-letter phone is dropped")
        #expect(TeamsParsing.proofs(json(#"{"id":"U3","mail":null,"mobilePhone":null,"businessPhones":[]}"#)) == [])
        #expect(TeamsParsing.proofs([:]) == [])
    }

    @Test func aMemberWithoutAnEmailIsLookedUpOnceAndCached() async throws {
        let t = FakeTransport().on("/me", teamsMe).on("/me/chats", teamsChatsWithEmail).on("/me/joinedTeams", #"{"value":[]}"#).on("/users/U3", teamsUserU3)
        let s = TeamsSource(transport: t, token: { "eyJ" })
        let b = try await s.discoverBuckets()
        #expect(b.map(\.proofs) == [["email:meera.nair@loopsy.in"], ["phone:919810011223", "phone:1141002233", "email:rohan@loopsy.in"], []])
        #expect(t.count("/users/U3") == 1 && t.count("/users/U2") == 0, "only the chat whose member record proved nothing asks the directory")
        _ = try await s.discoverBuckets()
        #expect(t.count("/users/U3") == 1, "the second discovery answers from the cache")
        let hit = t.calls.first { $0.absoluteString.contains("/users/U3") }?.absoluteString.removingPercentEncoding ?? ""
        #expect(hit.hasSuffix("/users/U3?$select=mail,mobilePhone,businessPhones"))
    }

    @Test func aDirectoryThatRefusesLeavesTheBucketUnprovenWithoutFailingDiscovery() async throws {
        let t = FakeTransport().on("/me", teamsMe).on("/me/chats", teamsChatsWithEmail).on("/me/joinedTeams", #"{"value":[]}"#).on("/users/U3", status: 403, #"{"error":{"message":"no"}}"#)
        let b = try await TeamsSource(transport: t, token: { "eyJ" }).discoverBuckets()
        #expect(b.map(\.proofs) == [["email:meera.nair@loopsy.in"], [], []])
    }
}
