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
        let m = HouseholdLedger.merge(mine, theirs, now: now)
        #expect(m.count == 1, "same person, same promise in other words — one entry")
        #expect(m[0].loopID == "a" && m[0].status == .closed && m[0].closedBy == "m-p", "the earlier line's id is kept; her closure stands even though my open line is newer")
        let other = HouseholdLedger.entries(from: [loop("z", what: "order the cake", owner: "Priya")], me: "m-p", now: now)
        #expect(HouseholdLedger.merge(m, other, now: now).count == 2)
        #expect(HouseholdLedger.merge(m, m, now: now) == m, "idempotent")
    }

    @Test func aClosureOlderThanNinetyDaysLeavesTheLedgerAndAnOpenLineNeverDoes() {
        func entry(_ id: String, _ what: String, closed: Bool, ago days: Double) -> HouseholdEntry {
            HouseholdEntry(loopID: id, memberID: "m-v", person: "Upreti Family", what: what, direction: .mine, owner: "either", status: closed ? .closed : .open, closedBy: closed ? "m-v" : nil, updatedAt: now.addingTimeInterval(-days * 86400))
        }
        let merged = HouseholdLedger.merge([entry("stale", "book the table", closed: true, ago: 91), entry("kept", "renew the passport", closed: true, ago: 89)], [entry("open", "call the plumber", closed: false, ago: 200)], now: now)
        #expect(merged.map(\.loopID).sorted() == ["kept", "open"], "a closure every Mac has long seen is dropped; an open line stays however old")
        #expect(HouseholdLedger.merge(merged, [entry("stale", "book the table", closed: true, ago: 91)], now: now).map(\.loopID).sorted() == ["kept", "open"], "the other Mac's stale copy does not bring it back")
        // "Not a loop" on a household loop writes a dismissed line; it is settled and leaves by the same rule, not kept for ever
        var dismissed = entry("gone", "order the cake", closed: false, ago: 91); dismissed.status = .dismissed
        #expect(HouseholdLedger.merge([dismissed], [], now: now).isEmpty, "a dismissed line older than ninety days leaves too")
        #expect(HouseholdLedger.merge([dismissed], [], now: now.addingTimeInterval(-2 * 86400)).map(\.loopID) == ["gone"], "until then it stays")
    }

    @Test func aClosureLeavesTheLedgerOnlyOnceEveryMembersMacHasMergedIt() {
        // Vivek closes L on 1 June; Priya's Mac is shut for the whole summer
        let hers = Household(members: [HouseholdMember(id: "m-v", name: "Vivek Upreti", isMe: false), HouseholdMember(id: "m-p", name: "Priya Upreti", isMe: true)], folderPath: "/x", since: now)
        let june = now.addingTimeInterval(-100 * 86400)
        var mineClosed = loop("L", what: "book the villa", owner: "either", closed: true); mineClosed.closedAt = june; mineClosed.closedBy = "user"
        var file = HouseholdLedger.merge([], HouseholdLedger.entries(from: [mineClosed], me: "m-v", now: june), now: june, household: h)
        #expect(file.count == 1 && file[0].seenBy == ["m-v"], "the merging Mac stamps every settled line as seen")
        // every night since, his Mac merges again — his own copy left his ledger long ago — and the line is a hundred days old
        for night in stride(from: 90.0, through: 100, by: 1) { file = HouseholdLedger.merge(file, [], now: june.addingTimeInterval(night * 86400), household: h) }
        #expect(file.map(\.loopID) == ["L"] && file[0].seenBy == ["m-v"], "older than ninety days, but her Mac has not merged it: it waits")
        // her Mac wakes: her open copy (opened in May, like his) meets the closure, her loop closes, and now everyone has seen it
        let herLoop = Loop(id: "L", direction: .mine, person: "Upreti Family", what: "book the villa", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: june.addingTimeInterval(-10 * 86400)).with(owner: "either")
        let merged = HouseholdLedger.merge(file, HouseholdLedger.entries(from: [herLoop], me: "m-p", now: now), now: now, household: hers)
        #expect(merged.count == 1 && merged[0].status == .closed && merged[0].closedBy == "m-v" && merged[0].seenBy == ["m-v", "m-p"])
        let closed = HouseholdLedger.closures(for: [herLoop], ledger: merged, household: hers, now: now)
        #expect(closed[0].status == .closed && closed[0].closedBy == "household:m-v" && closed[0].closedHow == "Vivek did it — booked")
        #expect(HouseholdLedger.merge(merged, [], now: now.addingTimeInterval(86400), household: h).isEmpty, "seen by all and past ninety days: gone")
        // a file written by a build before the stamp existed reads as seen by nobody, so it waits for everyone too
        let old = try? JSONDecoder().decode([HouseholdEntry].self, from: #"[{"loopID":"L","memberID":"m-v","person":"Upreti Family","what":"book the villa","direction":"mine","owner":"either","status":"closed","closedBy":"m-v","updatedAt":\#(june.timeIntervalSinceReferenceDate)}]"#.data(using: .utf8)!)
        #expect(old?.first?.seenBy == nil)
        #expect(HouseholdLedger.merge(old ?? [], [], now: now, household: h).first?.seenBy == ["m-v"])
    }

    @Test func aClosureFromTheHouseholdGoesBackUnderTheClosersNameNotMine() {
        let hers = Household(members: [HouseholdMember(id: "m-v", name: "Vivek Upreti", isMe: false), HouseholdMember(id: "m-p", name: "Priya Upreti", isMe: true)], folderPath: "/x", since: now)
        let mon = now.addingTimeInterval(-2 * 86400), tue = now.addingTimeInterval(-86400)
        // Monday: Priya closes L herself
        var herLoop = loop("L", what: "book the villa", owner: "either", closed: true); herLoop.closedAt = mon; herLoop.closedBy = "user"
        var file = HouseholdLedger.merge([], HouseholdLedger.entries(from: [herLoop], me: "m-p", now: mon), now: mon, household: hers)
        // Tuesday: Vivek's sync closes his copy over hers
        var mine = loop("L", what: "book the villa", owner: "either")
        file = HouseholdLedger.merge(file, HouseholdLedger.entries(from: [mine], me: "m-v", now: tue), now: tue, household: h)
        mine = HouseholdLedger.closures(for: [mine], ledger: file, household: h, now: tue)[0]
        #expect(mine.status == .closed && mine.closedBy == "household:m-p" && mine.closedHow == "Priya did it — booked")
        // Wednesday: his copy goes back to the file — under her name, with no words of his
        let back = HouseholdLedger.entries(from: [mine], me: "m-v", now: now)
        #expect(back[0].status == .closed && back[0].closedBy == "m-p" && back[0].closedHow == nil && back[0].updatedAt == tue)
        file = HouseholdLedger.merge(file, back, now: now, household: h)
        #expect(file.count == 1 && file[0].closedBy == "m-p" && file[0].closedHow == "booked", "his newer line does not take the closure from her")
        // so on her Mac her own card is not "done by Vivek", and a third Mac says Priya did it
        var c = Card(id: "c", title: "Book the villa", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: now, loopID: "L")
        c.owner = "either"
        #expect(HouseholdLedger.markHandled([c], ledger: file, household: hers)[0].handledBy == nil)
        #expect(HouseholdLedger.markHandled([c], ledger: file, household: h)[0].handledBy == "Priya")
        let ammas = Household(members: [HouseholdMember(id: "m-v", name: "Vivek Upreti", isMe: false), priya, HouseholdMember(id: "m-a", name: "Lakshmi Devi", isMe: true)], folderPath: "/x", since: now)
        #expect(HouseholdLedger.closures(for: [loop("L", what: "book the villa", owner: "either")], ledger: file, household: ammas, now: now)[0].closedHow == "Priya did it — booked")
        // a loop an older build closed with a bare "household" names nobody rather than me
        var bare = mine; bare.closedBy = "household"
        #expect(HouseholdLedger.entries(from: [bare], me: "m-v", now: now)[0].closedBy == nil)
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

    @Test func aLoopLetGoIsWrittenInWordsEveryBuildReadsAndIsNobodysDoing() throws {
        var gone = loop("g", what: "book the table for twelve"); gone.status = .lapsed; gone.lapsedAt = now; gone.closedAt = now; gone.closedBy = "lapsed"
        let e = HouseholdLedger.entries(from: [gone], me: "m-v", now: now)
        #expect(e.count == 1 && e[0].status == .closed && e[0].closedHow == "let go" && e[0].closedBy == nil && e[0].updatedAt == now)
        // the previous build's status knows only open, closed and dismissed, and one unknown word empties its whole ledger
        struct OldLine: Codable { enum Status: String, Codable { case open, closed, dismissed }; let status: Status }
        let data = try JSONEncoder().encode(e)
        #expect(!String(decoding: data, as: UTF8.self).contains("lapsed"))
        #expect(try JSONDecoder().decode([OldLine].self, from: data).map(\.status) == [.closed])
        // the other Mac: her copy is not closed as if someone did it, and no card of hers is marked handled
        let hers = [loop("g", what: "book the table for twelve", owner: "either")]
        let merged = HouseholdLedger.merge(HouseholdLedger.entries(from: hers, me: "m-p", now: now), e, now: now)
        #expect(merged.count == 1 && merged[0].status == .closed && merged[0].closedBy == nil)
        #expect(HouseholdLedger.closures(for: hers, ledger: merged, household: h, now: now)[0].status == .open)
        var c = Card(id: "c", title: "Book the table for twelve", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: now, loopID: "g")
        c.owner = "either"
        #expect(HouseholdLedger.markHandled([c], ledger: merged, household: h)[0].handledBy == nil)
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
