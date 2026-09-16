import SwiftUI
import Knowledge

/// "These two look like one person" — the registry's first suspect pair, at the top of the note pane.
/// Merge keeps the first (the one with a note, the fuller name); Keep separate is remembered, so the pair never asks again.
struct PeopleMergeBanner: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t

    var body: some View {
        if let pair = m.duplicatePeople.first {
            CardBox(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2").foregroundStyle(t.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        (Text("These two look like one person: ") + Text("\(pair.0.name) · \(pair.1.name)").fontWeight(.medium)).font(.system(size: 12.5))
                        Text(subtitle(pair)).font(.system(size: 11)).foregroundStyle(t.ink2)
                    }
                    Spacer()
                    BButton(title: "Merge", kind: .primary) { m.mergePeople(keep: pair.0.id, drop: pair.1.id) }
                    BButton(title: "Keep separate", kind: .quiet) { m.keepPeopleSeparate(pair.0.id, pair.1.id) }
                }
            }
        }
    }

    func subtitle(_ pair: (Person, Person)) -> String {
        var s = "Merge keeps \(pair.0.name)"
        if let p = pair.0.notePath { s += " and folds the other note into \(p)" }
        if m.duplicatePeople.count > 1 { s += " · \(m.duplicatePeople.count - 1) more pair\(m.duplicatePeople.count == 2 ? "" : "s") after this" }
        return s
    }
}
