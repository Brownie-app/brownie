import SwiftUI
import Knowledge

/// The registry's first suspect pair, at the top of the note pane. A pending pair — the same name on a second chat, with
/// nothing but the name to join them — is Brownie's own question: "Is Nitesh Kumar on Slack the same Nitesh Kumar as on
/// WhatsApp?", answered Same person or Different people. A pair that merely looks alike keeps the older copy: "These two
/// look like one person", Merge or Keep separate. Either way the first is the one kept (the one with a note, the fuller
/// name), and a No is remembered, so the pair never asks again. The words live in `PeopleQuestion`.
struct PeopleMergeBanner: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t

    var body: some View {
        if let pair = m.duplicatePeople.first {
            CardBox(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: PeopleQuestion.isPending(pair) ? "person.fill.questionmark" : "person.2").foregroundStyle(t.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PeopleQuestion.title(pair)).fontWeight(.medium).font(.system(size: 12.5))
                        Text(subtitle(pair)).font(.system(size: 11)).foregroundStyle(t.ink2)
                    }
                    Spacer()
                    BButton(title: PeopleQuestion.yes(pair), kind: .primary) { m.mergePeople(keep: pair.0.id, drop: pair.1.id) }
                    BButton(title: PeopleQuestion.no(pair), kind: .quiet) { m.keepPeopleSeparate(pair.0.id, pair.1.id) }
                }
            }
        }
    }

    func subtitle(_ pair: (Person, Person)) -> String {
        var s = PeopleQuestion.consequence(pair)
        if m.duplicatePeople.count > 1 { s += " · \(m.duplicatePeople.count - 1) more pair\(m.duplicatePeople.count == 2 ? "" : "s") after this" }
        return s
    }
}
