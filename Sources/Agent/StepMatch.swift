import Foundation
import Domain

/// How a recorded step finds its element again. Pure, so the ranking is tested against snapshots.
public enum StepMatch {
    public static func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces) }

    /// Fractions of the window for an element's centre.
    public static func fraction(_ f: CGRect, in win: CGRect) -> (Double, Double)? {
        guard win.width > 0, win.height > 0 else { return nil }
        return (Double((f.midX - win.minX) / win.width), Double((f.midY - win.minY) / win.height))
    }

    /// The best candidate for a step, or nil. Order of trust: same role and exact label → exact label → label inside the
    /// element's words → (for unlabelled steps or ties) the same role at the same place, then anything at the same place.
    /// `tried` are ids already clicked without effect.
    public static func candidate(for s: TaughtRecipe.Step, in snap: UISnapshot, tried: Set<Int> = []) -> UISnapshot.Element? {
        let want = norm(s.target)
        let ctx = s.context.map(norm) ?? ""
        let win = snap.elements.first { $0.role == "Window" }?.frame ?? .zero
        let pool = snap.elements.filter { !tried.contains($0.id) && $0.role != "Window" }
        func place(_ e: UISnapshot.Element) -> Double {
            guard let fx = s.fx, let fy = s.fy, let (ex, ey) = fraction(e.frame, in: win) else { return 9 }
            return abs(ex - fx) + abs(ey - fy)
        }
        let byPlace = { (es: [UISnapshot.Element]) -> UISnapshot.Element? in es.filter { $0.frame.width > 0 }.min(by: { place($0) < place($1) }).flatMap { place($0) < 0.12 ? $0 : nil } }
        if s.isUnlabelled {
            // nothing to match by name: the words around it, then the place
            if !ctx.isEmpty, let hit = pool.filter({ norm($0.title).contains(ctx) || norm($0.value).contains(ctx) || ctx.contains(norm($0.title)) && !$0.title.isEmpty }).min(by: { place($0) < place($1) }) { return hit }
            return byPlace(pool.filter { $0.role == s.role }) ?? byPlace(pool)
        }
        let exactRole = pool.filter { $0.role == s.role && norm($0.title) == want }
        if exactRole.count == 1 { return exactRole[0] }
        if exactRole.count > 1 { return byPlace(exactRole) ?? exactRole[0] }
        let exact = pool.filter { norm($0.title) == want }
        if !exact.isEmpty { return byPlace(exact) ?? exact[0] }
        let contains = pool.filter { norm($0.title).contains(want) || norm($0.value).contains(want) }
        if !contains.isEmpty { return byPlace(contains) ?? contains[0] }
        if !ctx.isEmpty, let hit = pool.first(where: { norm($0.title).contains(ctx) || norm($0.value).contains(ctx) }) { return hit }
        return byPlace(pool.filter { $0.role == s.role })
    }
}
