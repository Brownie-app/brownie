import Testing
import Foundation
@testable import Proactive
import Domain

let me = HouseholdMember(id: "m-v", name: "Vivek Upreti", isMe: true, phone: "+91 98450 12345")
let priya = HouseholdMember(id: "m-p", name: "Priya Upreti", isMe: false, phone: "919845067890")
let amma = HouseholdMember(id: "m-a", name: "Lakshmi Devi", isMe: false)
let now = Date(timeIntervalSince1970: 1_758_000_000)

@Suite struct HouseholdEligibilityTests {
    @Test func aPhoneMatchesOnItsLastTenDigits() {
        #expect(HouseholdEligibility.matches(priya, chatMembers: ["+91 98450 67890", "Rohan"]))
        #expect(HouseholdEligibility.matches(priya, chatMembers: ["009845067890"]))
        #expect(!HouseholdEligibility.matches(priya, chatMembers: ["+91 98450 67891"]))
    }
    @Test func aNameMatchesWhenItIsUnambiguous() {
        #expect(HouseholdEligibility.matches(amma, chatMembers: ["Lakshmi Devi", "Rohan"]), "full name")
        #expect(HouseholdEligibility.matches(amma, chatMembers: ["lakshmi", "Rohan"]), "first name alone, once")
        #expect(!HouseholdEligibility.matches(amma, chatMembers: ["Lakshmi Rao", "Lakshmi N"]), "two Lakshmis — can't tell")
        #expect(!HouseholdEligibility.matches(amma, chatMembers: ["Rohan", "Karan"]))
    }
    @Test func aChatIsEligibleOnlyWhenEveryOtherMemberIsInIt() {
        let h = Household(members: [me, priya, amma], folderPath: "/x", since: now)
        #expect(HouseholdEligibility.isEligible(chatMembers: ["+919845067890", "Lakshmi Devi", "Rohan", "+919845012345"], others: h.others))
        #expect(!HouseholdEligibility.isEligible(chatMembers: ["+919845067890", "Rohan"], others: h.others), "Amma isn't in it")
        #expect(!HouseholdEligibility.isEligible(chatMembers: ["everyone"], others: []), "no household, nothing shared")
    }
    @Test func householdLinesAndSharing() throws {
        let two = Household(members: [me, priya], folderPath: "/x", sharedBuckets: ["whatsapp:7"], since: now)
        #expect(two.othersLine == "Priya" && two.me?.id == "m-v" && two.others.map(\.id) == ["m-p"])
        #expect(Household(members: [me, priya, amma], folderPath: "/x", since: now).othersLine == "Priya and Lakshmi")
        #expect(two.isShared(BucketID("whatsapp:7")) && !two.isShared(BucketID("whatsapp:8")))
        #expect(try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(two)) == two)
    }
}

@Suite struct HouseholdLedgerTests {
    let h = Household(members: [me, priya], folderPath: "/x", since: now)
    func loop(_ id: String, what: String, owner: String? = "me", closed: Bool = false) -> Loop {
        Loop(id: id, direction: .mine, person: "Upreti Family", what: what, quote: "", sourceLabel: "WhatsApp", due: nil, status: closed ? .closed : .open, openedAt: now.addingTimeInterval(-86400), closedAt: closed ? now : nil, closedHow: closed ? "booked" : nil, cameBackCount: 0).with(owner: owner)
    }

    @Test func onlyHouseholdLoopsGoToTheLedger() {
        let e = HouseholdLedger.entries(from: [loop("a", what: "book the table"), loop("b", what: "reply to Kanika", owner: nil)], me: "m-v", now: now)
        #expect(e.map(\.loopID) == ["a"] && e[0].memberID == "m-v" && e[0].status == .open && e[0].closedBy == nil)
    }

    @Test func mergeIsAUnionWhereClosedWinsAndTwinsFold() {
        let mine = HouseholdLedger.entries(from: [loop("a", what: "book the table for twelve at Karavalli")], me: "m-v", now: now)
        var theirs = HouseholdLedger.entries(from: [loop("p-1", what: "Book a table for 12 at Karavalli", owner: "Priya", closed: true)], me: "m-p", now: now)
        theirs[0].updatedAt = now.addingTimeInterval(-3600)   // her closure is older than my open line
        let m = HouseholdLedger.merge(mine, theirs)
        #expect(m.count == 1, "same person, same promise in other words — one entry")
        #expect(m[0].loopID == "a" && m[0].status == .closed && m[0].closedBy == "m-p", "the earlier line's id is kept; her closure stands even though my open line is newer")
        let other = HouseholdLedger.entries(from: [loop("z", what: "order the cake", owner: "Priya")], me: "m-p", now: now)
        #expect(HouseholdLedger.merge(m, other).count == 2)
        #expect(HouseholdLedger.merge(m, m) == m, "idempotent")
    }

    @Test func cardsSheHandledAreMarkedAndMyLoopsClose() {
        let ledger = [HouseholdEntry(loopID: "L1", memberID: "m-p", person: "Upreti Family", what: "book the table for 12", direction: .mine, owner: "either", status: .closed, closedBy: "m-p", closedHow: "booked Karavalli", updatedAt: now)]
        func card(_ id: String, loop: String?, owner: String?, title: String = "Book Amma's table for 12") -> Card {
            var c = Card(id: id, title: title, sourceLabel: "s", why: "in Upreti Family", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: now, loopID: loop)
            c.owner = owner; return c
        }
        let marked = HouseholdLedger.markHandled([card("a", loop: "L1", owner: "either"), card("b", loop: nil, owner: "me"), card("c", loop: "L1", owner: nil), card("d", loop: nil, owner: "me", title: "Reply to Kanika about licensing")], ledger: ledger, household: h)
        #expect(marked.map(\.handledBy) == ["Priya", "Priya", nil, nil], "by loop id, or by the same words; never a card that isn't the household's")
        let closed = HouseholdLedger.closures(for: [loop("L1", what: "book the table for 12", owner: "either"), loop("x", what: "reply to Kanika", owner: nil)], ledger: ledger, household: h, now: now)
        #expect(closed[0].status == .closed && closed[0].closedHow == "Priya did it — booked Karavalli")
        #expect(closed[1].status == .open, "my own loops are not the household's business")
        let mineClosed = [HouseholdEntry(loopID: "L2", memberID: "m-v", person: "p", what: "w", direction: .mine, owner: "me", status: .closed, closedBy: "m-v", updatedAt: now)]
        #expect(HouseholdLedger.markHandled([card("e", loop: "L2", owner: "me")], ledger: mineClosed, household: h)[0].handledBy == nil, "what I closed myself isn't “handled by” anyone")
    }

    @Test func ledgerFileRoundTrip() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("hh-\(UUID().uuidString)/ledger.json")
        let e = HouseholdLedger.entries(from: [loop("a", what: "x")], me: "m-v", now: now)
        try HouseholdLedger.write(e, to: u)
        #expect(HouseholdLedger.read(u) == e)
        #expect(HouseholdLedger.read(u.appendingPathComponent("nope")).isEmpty)
    }
}

extension Loop { func with(owner: String?) -> Loop { var l = self; l.owner = owner; return l } }

@Suite struct HouseholdOwnerTests {
    @Test func ownersAreNormalised() {
        #expect(Judge.cleanOwner("me") == "me" && Judge.cleanOwner("The user") == "me" && Judge.cleanOwner("you") == "me")
        #expect(Judge.cleanOwner("either") == "either" && Judge.cleanOwner("both") == "either")
        #expect(Judge.cleanOwner("Priya Upreti") == "Priya" && Judge.cleanOwner(" Priya ") == "Priya")
        #expect(Judge.cleanOwner(nil) == nil && Judge.cleanOwner("") == nil && Judge.cleanOwner("null") == nil)
    }
    @Test func theCandidatesOwnerRidesOntoTheCardWhenThePreparerForgets() {
        var cand = ActionItem(title: "Book the table", action: "", importance: "", dueDate: nil, sources: [], urgency: .medium, loopID: "L1"); cand.owner = "either"
        let c = Card(id: "1", title: "Book the table", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: Date(), loopID: "L1")
        #expect(Preparer.withOwners([c], from: [[:]], candidates: [cand])[0].owner == "either")
        #expect(Preparer.withOwners([c], from: [["owner": "Priya Upreti"]], candidates: [cand])[0].owner == "Priya", "what the preparer wrote wins")
        #expect(Preparer.withOwners([c], from: [[:]], candidates: [])[0].owner == nil)
    }
    @Test func theHouseholdBlockNamesEveryoneAndIsEmptyAlone() {
        #expect(Judge.householdBlock(nil) == "")
        #expect(Judge.householdBlock(Household(members: [me], folderPath: "/x", since: now)) == "", "no one to share with")
        let b = Judge.householdBlock(Household(members: [me, priya, amma], folderPath: "/x", since: now))
        #expect(b.contains("shares a household with Priya and Lakshmi") && b.contains("\"Priya\" or \"Lakshmi\""))
    }
}
