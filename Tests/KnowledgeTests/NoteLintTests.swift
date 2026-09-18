import Testing
import Foundation
import Domain
@testable import Knowledge

/// The word rules on a People note against a fixed clock (2026-09-16): the voice, the hedges, the filler, the
/// repeats, the meta lines — each on its own, then all at once on a note as messy as the brain writes them — and that
/// a clean note passes through unchanged.
@Suite struct NoteLintTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 11:20 UTC
    static let block = "<!-- brownie:status -->\n## Between you\n_Kept by Brownie._\n- ⏳ 2 Sep — the user asked: “dinner?” — no reply yet\n<!-- /brownie:status -->"
    func clean(_ body: String, kind: NoteMeta.Kind = .person) -> (body: String, changes: [String]) { NoteLint.clean(body: body, kind: kind, now: Self.now, timeZone: Self.utc) }
    func norm(_ body: String) -> (body: String, changes: [String]) { NoteSkeleton.normalize(body: body, kind: .person, now: Self.now, timeZone: Self.utc) }
    func section(_ h: String, of body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: h) else { return [] }
        return Array(lines[(i + 1)...].prefix { !$0.hasPrefix("## ") }).filter { !$0.isEmpty }
    }

    // MARK: voice

    @Test func theUserBecomesYouAndTheVerbFollows() {
        let out = clean("# A\n\n## Now\n- The user has agreed to send the deck (2026-09-10)\n- Kanika said the user is expected to reply (2026-09-11)\n- The user does not want the user's data shared (2026-09-12)\n- the user's own plan; the user himself said so (2026-09-13)\n- She reminded the user; the user says yes. The user plans to go (2026-09-14)\n- The user was asked, and the user believes the user needs a week (2026-09-15)\n")
        #expect(section("## Now", of: out.body) == ["- You have agreed to send the deck (2026-09-10)", "- Kanika said you are expected to reply (2026-09-11)", "- You do not want your data shared (2026-09-12)", "- Your own plan; you yourself said so (2026-09-13)", "- She reminded you; you say yes. You plan to go (2026-09-14)", "- You were asked, and you believe you need a week (2026-09-15)"],
                "the possessive is 'your', a capital is kept and given at the head of a sentence, the verb agrees, 'himself' right after is 'yourself'")
        #expect(out.changes == ["6 lines put in your voice"])
        #expect(clean(out.body).changes.isEmpty, "idempotent")
    }

    @Test func anObjectYouKeepsItsVerbAndALinkOrCodeSpanIsNeverTouched() {
        let out = clean("# A\n\n## Now\n- The deck she sent the user was late (2026-09-12)\n- What matters to the user is timing (2026-09-13)\n- [[the user]] and `the user is` stay as written (2026-09-14)\n- The user will decide; the user would know (2026-09-15)\n- The user is sure [[the user]] means the user herself (2026-09-16)\n")
        #expect(section("## Now", of: out.body) == ["- The deck she sent you was late (2026-09-12)", "- What matters to you is timing (2026-09-13)", "- [[the user]] and `the user is` stay as written (2026-09-14)", "- You will decide; you would know (2026-09-15)", "- You are sure [[the user]] means you yourself (2026-09-16)"],
                "after a handing verb or a preposition 'you' is an object and the verb belongs to something else; 'will' and 'would' never change; a link stays a link however the line shifts around it")
        #expect(out.changes == ["4 lines put in your voice"])
    }

    @Test func theStatusBlockCommentsTablesAndNestedLinesKeepTheirWords() {
        let body = "# A\n\n" + Self.block + "\n\n## About\n- Colleague of the user\n  - the user's cousin, in fact\n<!-- the user asked me to keep this -->\n\n| Who | What |\n|---|---|\n| the user | owes lunch |\n\n```\nthe user is here\n```\n\n## Now\n- Asked for photos (2026-09-05)\n"
        let out = clean(body)
        #expect(out.body == "# A\n\n" + Self.block + "\n\n## About\n- Colleague of you\n  - the user's cousin, in fact\n<!-- the user asked me to keep this -->\n\n| Who | What |\n|---|---|\n| the user | owes lunch |\n\n```\nthe user is here\n```\n\n## Now\n- Asked for photos (2026-09-05)\n",
                "the block, a comment, a table, a fence and the lines nested under a bullet are not the lint's")
        #expect(NoteStatus.extract(from: out.body) == Self.block)
        #expect(out.changes == ["1 line put in your voice"])
    }

    // MARK: hedges

    @Test func aHedgeClauseGoesAndTheSentenceAroundItStays() {
        let out = clean("# A\n\n## Now\n- Kanika said an upgraded UI was expected this week; delivery is not confirmed. (2026-09-10)\n- No decision was recorded; kanika will confirm next week. (2026-09-11)\n- Kanika shared the deck (not independently confirmed). (2026-09-12)\n- This is a plan, not an established outcome — Goa in October. (2026-09-13)\n- The available summaries do not establish whether she came. Kanika sent photos. (2026-09-14)\n- Kanika will call, but the timing is not confirmed (2026-09-15)\n")
        #expect(section("## Now", of: out.body) == ["- Kanika said an upgraded UI was expected this week. (2026-09-10)", "- Kanika will confirm next week. (2026-09-11)", "- Kanika shared the deck. (2026-09-12)", "- Goa in October. (2026-09-13)", "- Kanika sent photos. (2026-09-14)", "- Kanika will call (2026-09-15)"],
                "a trailing clause, a leading clause (the next word given its capital), an aside in parentheses, a whole sentence: each goes, the full stop put back where there was one, a dangling 'but' taken off")
        #expect(out.changes == ["6 hedges removed"])
        #expect(clean(out.body).changes.isEmpty)
    }

    @Test func everyHedgeShapeIsKnownAndTheListIsData() {
        let hedges = ["no outcome is recorded here", "No figures were captured", "no contact details are confirmed", "No new pending action was established", "these are plans, not established outcomes yet", "not independently confirmed",
                      "the summary does not confirm it", "the records do not record a reply", "no later summary confirms delivery", "the outcome and any user action are not recorded", "the outcome and any your action are not recorded",
                      "Nothing was recorded about the venue", "this remains under discussion unless noted above", "delivery is not confirmed", "the timing and transition are not independently confirmed", "it does not create a new pending action", "the outcome is not yet known"]
        for h in hedges { #expect(NoteLint.hedge(h), Comment(rawValue: h)) }
        for kept in ["Kanika confirmed the venue", "no reply yet from Priya", "she recorded a podcast", "the deck is not finished", "no allergies"] { #expect(!NoteLint.hedge(kept), Comment(rawValue: kept)) }
        #expect(NoteLint.hedgePatterns.count >= 11, "one pattern per habit, in a list")
    }

    // MARK: filler

    @Test func aBulletThatSaysNothingIsDropped() {
        let out = clean("# A\n\n## About\n- Standing facts about Kanika.\n- No standing facts yet.\n- TBD\n- Nothing new.\n- Nothing beats her biryani.\n- No known allergies.\n- —\n\n## Now\n- No pending request or unresolved obligation is established by this exchange. (2026-09-10)\n- No pending request, but she mentioned a trip to Goa in October. (2026-09-11)\n- No outcome or reply was recorded. (2026-09-12)\n")
        #expect(out.body == "# A\n\n## About\n- Nothing beats her biryani.\n- No known allergies.\n\n## Now\n- No pending request, but she mentioned a trip to Goa in October. (2026-09-11)\n",
                "a placeholder, a bullet that only says nothing happened, a bullet left empty once its hedge went; a fact that starts the same way stays")
        #expect(out.changes == ["2 hedges removed", "7 empty bullets dropped"])
        #expect(clean(out.body).changes.isEmpty)
    }

    // MARK: repeats

    @Test func twoBulletsThatSayTheSameThingAreOneInTheHigherSection() {
        let out = clean("# A\n\n## About\n- Works at Loadmill as design lead\n- Kanika works at Loadmill as the design lead\n\n## Now\n- Kanika shared the Q3 deck with the team (2026-09-16)\n- Lunch (2026-09-11)\n- Priya wants the Goa photos by Friday (2026-09-01)\n\n## Context\n- Kanika shared the Q3 deck for review (2026-09-10)\n- Lunch (2026-09-01)\n- Kanika asked for the deck (2026-09-02)\n- Kanika sent the deck (2026-09-03)\n- Priya wants the Goa photos by Friday at the latest (2026-09-12)\n")
        #expect(section("## About", of: out.body) == ["- Kanika works at Loadmill as the design lead"], "undated, the longer stays")
        #expect(section("## Now", of: out.body) == ["- Kanika shared the Q3 deck with the team (2026-09-16)", "- Lunch (2026-09-11)", "- Priya wants the Goa photos by Friday at the latest (2026-09-12)"],
                "the newer stays, and takes the copy's place under Now when it sat under Context")
        #expect(section("## Context", of: out.body) == ["- Lunch (2026-09-01)", "- Kanika asked for the deck (2026-09-02)", "- Kanika sent the deck (2026-09-03)"],
                "'asked for' and 'sent' are two facts; 'Lunch' on two days is two lunches, too short to call a repeat")
        #expect(out.changes == ["3 repeated bullets merged"])
        #expect(clean(out.body).changes.isEmpty)
    }

    @Test func aboutStaysAboutAndABulletWithNestedLinesNeverGoes() {
        let out = clean("# A\n\n## About\n- Kanika is on leave until October\n\n## Now\n- Kanika is on leave until October (since 2026-09-01)\n- Wants the flat in Pune sorted (2026-09-10)\n  - two bedrooms\n\n## Context\n- Wants the flat in Pune sorted soon (2026-09-12)\n")
        #expect(out.body == "# A\n\n## Now\n- Kanika is on leave until October (since 2026-09-01)\n- Wants the flat in Pune sorted (2026-09-10)\n  - two bedrooms\n",
                "the dated one wins over the undated and stays where it was; the newer Context copy goes because the older Now one holds nested lines, which never go")
        #expect(out.changes == ["2 repeated bullets merged"])
        let aboutWins = clean("# A\n\n## About\n- Kanika is the design lead at Loadmill and runs the Pune studio\n\n## Context\n- Kanika is the design lead at Loadmill in Pune (date unclear)\n")
        #expect(aboutWins.body == "# A\n\n## About\n- Kanika is the design lead at Loadmill and runs the Pune studio\n", "both undated: the longer stays, under About")
    }

    // MARK: meta

    @Test func aMetaLineKeepsOnlyTheFactsAfterItsColon() {
        let out = clean("# A\n\n## Now\n- Earlier requests and plans remain historical unless noted above: Kanika asked for the deck in July; the user promised the recipe. (2026-09-10)\n- Individual recurring contacts now have separate notes so this note only holds the group's facts. (2026-09-11)\n- References to calls involving Priya do not establish a remaining user action. (2026-09-12)\n- Earlier plans remain historical unless noted above. (2026-09-13)\n- Carried over from the old note: none. (2026-09-14)\n")
        #expect(out.body == "# A\n\n## Now\n- Kanika asked for the deck in July; you promised the recipe. (2026-09-10)\n", "the facts after the colon are a bullet, in your voice; a meta line with none is gone")
        #expect(out.changes == ["1 line put in your voice", "5 meta lines cut"])
        #expect(clean(out.body).changes.isEmpty)
    }

    // MARK: all at once

    @Test func aMessyPeopleNoteComesOutReadable() {
        let messy = "# Kanika Pandey\n" + Self.block + "\n\n## About\n- Standing facts about Kanika.\n- Design lead at Loadmill; works with the user on the Q3 deck.\n- The user's colleague since 2024.\n\n## Now\n- **16 Sep 2026:** Kanika shared the Q3 deck with the team; delivery is not confirmed.\n- **14 Sep 2026:** The user agreed to review the deck by Friday (not independently confirmed).\n- **12 Sep 2026:** No decision was recorded; Kanika will confirm the offsite dates next week.\n- No pending request or unresolved obligation is established by this exchange.\n- Earlier requests and plans remain historical unless noted above: Kanika asked the user for the July figures; the user promised the recipe.\n\n## Context\n- Kanika shared the Q3 deck for the team (2026-09-10)\n- On leave (since 2026-06-01)\n"
        let once = norm(messy), twice = norm(once.body)
        #expect(once.body == "# Kanika Pandey\n\n" + Self.block + "\n\n## About\n- Design lead at Loadmill; works with you on the Q3 deck.\n- Your colleague since 2024.\n\n## Now\n- Kanika shared the Q3 deck with the team. (2026-09-16)\n- You agreed to review the deck by Friday. (2026-09-14)\n- Kanika will confirm the offsite dates next week. (2026-09-12)\n- Kanika asked you for the July figures; you promised the recipe. (date unclear)\n\n## Context\n- On leave (since 2026-06-01)\n")
        #expect(once.changes == ["3 bullets dated", "2 bullets marked date unclear", "4 lines put in your voice", "4 hedges removed", "2 empty bullets dropped", "1 repeated bullet merged", "1 meta line cut"])
        #expect(twice.body == once.body && twice.changes.isEmpty, "a clean note passes through unchanged")
        #expect(NoteStatus.extract(from: once.body) == Self.block, "the block keeps 'the user' — it is not the lint's")
    }

    @Test func otherKindsAndAConflictAreLeftAloneAndAnInShapeNoteReportsOnlyTheLint() {
        let topic = "# Trip\n\n## Now\n- the user is going (2026-09-01)\n"
        #expect(clean(topic, kind: .topic).body == topic && clean(topic, kind: .portrait).body == topic)
        let conflict = "# A\n\n## Now\n- the user is going (2026-09-01)\n\n## Brownie's version (16 Sep 11:20 — you edited this note on your phone at the same time; pick what you want to keep)\n\n- y\n"
        #expect(clean(conflict).body == conflict && clean(conflict).changes.isEmpty)
        let group = clean("# MPL Days\n\n## About\n- The college group; the user is the admin.\n", kind: .group)
        #expect(group.body == "# MPL Days\n\n## About\n- The college group; you are the admin.\n" && group.changes == ["1 line put in your voice"], "a group note takes the same rules")
        let tidy = "# A\n\n## Now\n- Asked for photos (2026-09-05)\n"
        #expect(clean(tidy).body == tidy && clean(tidy).changes.isEmpty)
    }
}

@Suite struct NoteLintRealVaultShapesTests {
    let now = Date(timeIntervalSince1970: 1_789_000_000), utc = TimeZone(identifier: "UTC")!
    @Test func theUserExperienceIsANounAndAPronounAfterYouSaidIsYou() {
        let body = "# K\n\n## Now\n- They agreed to improve the user experience; the user said he would not back out of the venture. (2026-09-15)\n"
        let out = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc).body
        #expect(out.contains("improve the user experience; you said you would not back out"), "\(out)")
    }
    @Test func theGeneralHedgeShapesGo() {
        let body = "# K\n\n## Now\n- They discussed going full-time; neither a deal closure nor a full-time transition is confirmed. (2026-09-18)\n- Kanika plans to use Browserbase's design. No upgraded-UI delivery is confirmed. (2026-09-16)\n- You shared the company's tax details. The actual identifiers and email addresses are intentionally not recorded. (2026-08-27)\n- Kanika's July request for feedback and the 27 Aug SBI call. References to calls involving Arif and others do not establish a remaining user action or completed outcome. (2026-09-01)\n\n## About\n- Akash — TPM.\n- Context These materials concern recruiting and peer review. Individual recurring contacts now have separate notes so their pending requests can be tracked.\n"
        let r = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc)
        #expect(!r.body.contains("is confirmed") && !r.body.contains("not recorded") && !r.body.contains("do not establish") && !r.body.contains("These materials") && !r.body.contains("separate notes"), "\(r.body)")
        #expect(r.body.contains("- They discussed going full-time. (2026-09-18)") && r.body.contains("- Kanika plans to use Browserbase's design. (2026-09-16)") && r.body.contains("- You shared the company's tax details. (2026-08-27)"), "\(r.body)")
        #expect(!r.body.contains("- Context"), "a bullet left with one word is dropped: \(r.body)")
        let again = NoteLint.clean(body: r.body, kind: .person, now: now, timeZone: utc).body
        #expect(again == r.body, "idempotent")
    }
}

@Suite struct NoteLintSentencesAndEarlierTests {
    let now = Date(timeIntervalSince1970: 1_789_000_000), utc = TimeZone(identifier: "UTC")!
    @Test func aHedgeSentenceGoesWholeNotHalf() {
        let body = "# K\n\n## About\n- Akash — TPM.\n- Context These materials concern recruiting, peer review, and career development. Individual recurring contacts now have separate notes so their pending requests can be tracked.\n\n## Context\n- Kanika's July request for feedback, the August coordination, and the 27 Aug SBI call. References to calls involving Arif, Madhul, Mr. Taragi, and others do not establish a remaining user action or completed outcome. (2026-09-01)\n"
        let out = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc).body
        #expect(!out.contains("Career development") && !out.contains("References to") && !out.contains("Context These"), "\(out)")
        #expect(out.contains("- Kanika's July request for feedback, the August coordination, and the 27 Aug SBI call. (2026-09-01)"), "\(out)")
    }
    @Test func earlierMonthLinesGetTheVoiceAndLoseTheirHedges() {
        let body = "# N\n\n## Earlier\n- 2026-08 — The user's planned QA account creation was discussed; no later summary confirms completion; they asked for the deck — you replied 3 Aug\n"
        let r = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc)
        #expect(r.body.contains("- 2026-08 — Your planned QA account creation was discussed; they asked for the deck — you replied 3 Aug"), "\(r.body)")
        #expect(NoteLint.clean(body: r.body, kind: .person, now: now, timeZone: utc).body == r.body, "idempotent")
    }
}

@Suite struct NoteLintMoreHedgesTests {
    let now = Date(timeIntervalSince1970: 1_789_000_000), utc = TimeZone(identifier: "UTC")!
    @Test func theQuieterHedgesGoToo() {
        let body = "# A\n\n## Now\n- They discussed dinners in December. The dates and plans were not consistently confirmed, so there is no reliable upcoming itinerary or dinner commitment. (2026-09-04)\n- Nayan asked you to transfer money for a GST payment. Amounts and account details are omitted. (2026-09-17)\n- Nayan said he had accepted a job, so earlier job-search uncertainty is resolved only at that level. (2026-09-02)\n\n## Context\n- Abhishek mentioned a Google colleague. These were conversational context, not confirmed referrals or outcomes. (2026-02-14)\n- Earlier exchanges included an AI-QA course plan. The course and content ideas were proposals. (2025-10-12)\n- Nayan's messages also included contacts such as Ankit and Sher; those references are not treated as commitments by you. (2026-01-01)\n"
        let r = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc)
        for gone in ["not consistently confirmed", "no reliable", "are omitted", "only at that level", "conversational context", "were proposals", "not treated as commitments"] { #expect(!r.body.contains(gone), "\(gone) stayed: \(r.body)") }
        for kept in ["- They discussed dinners in December. (2026-09-04)", "- Nayan asked you to transfer money for a GST payment. (2026-09-17)", "- Nayan said he had accepted a job. (2026-09-02)", "- Abhishek mentioned a Google colleague. (2026-02-14)", "- Earlier exchanges included an AI-QA course plan. (2025-10-12)", "- Nayan's messages also included contacts such as Ankit and Sher. (2026-01-01)"] { #expect(r.body.contains(kept), "\(kept) missing: \(r.body)") }
    }
}

@Suite struct NoteLintThreadTests {
    let now = Date(timeIntervalSince1970: 1_789_000_000), utc = TimeZone(identifier: "UTC")!
    @Test func oneThreadToldThreeTimesKeepsTheNewestTelling() {
        let body = "# Arif\n\n## Now\n- Arif's request for a perpetual licence option remains under discussion. You spoke with Arif about paperwork for Mr. Taragi's approval and plan to ping Arif again. (2026-09-18)\n- Arif's request for a perpetual licence option was discussed. [[Kanika Pandey]] will update Arif after speaking with you. (2026-09-16)\n- You had a conversation with Arif about a process involving Madhul, Mr. Taragi, and a further call. (2026-09-16)\n"
        let r = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc)
        let now = r.body.components(separatedBy: "## Now\n")[1]
        #expect(now.components(separatedBy: "\n- ").count == 2, "the two tellings of the licence thread are one; the Madhul call is its own: \(r.body)")
        #expect(now.contains("remains under discussion") && !now.contains("was discussed"), "the newest telling stays: \(r.body)")
        #expect(r.changes.contains("1 repeated bullet merged"))
    }
    @Test func aboutBulletsAndShortBulletsAreNotThreads() {
        let body = "# K\n\n## About\n- Kanika Pandey is a Loadmill contact in Delhi who runs product.\n- Kanika Pandey is a Loadmill contact whose sister works at Loopsy in Pune.\n\n## Now\n- Lunch with Kanika. (2026-09-10)\n- Lunch with Kanika. (2026-09-12)\n"
        let r = NoteLint.clean(body: body, kind: .person, now: now, timeZone: utc)
        #expect(r.body.components(separatedBy: "\n- ").count == 5, "About is never threaded and three-word bullets are too short to be: \(r.body)")
    }
}
