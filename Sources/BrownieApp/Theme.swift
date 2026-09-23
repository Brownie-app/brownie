import SwiftUI
import Domain

/// Design tokens from design/DesignSystem.dc.html. Dark swaps the set; never individual values.
struct Theme {
    let accent: Color, accentInk: Color, accentSoft: Color
    let ink: Color, ink2: Color, ink3: Color
    let side: Color, content: Color, card: Color, cardBorder: Color, sep: Color, ctl: Color, ctl2: Color, chip: Color, code: Color
    let ok: Color, warn: Color, bad: Color

    static let light = Theme(accent: Color(hex: 0xD8983A), accentInk: Color(hex: 0x8F5C1F), accentSoft: Color(hex: 0xD8983A).opacity(0.14),
                             ink: Color(hex: 0x1D1D1F), ink2: Color(hex: 0x6E6E73), ink3: Color(hex: 0xAEAEB2),
                             side: Color(hex: 0xECECEE), content: .white, card: .white, cardBorder: Color.black.opacity(0.08), sep: Color.black.opacity(0.10),
                             ctl: Color.black.opacity(0.05), ctl2: Color.black.opacity(0.09), chip: Color(hex: 0xF4F4F6), code: Color(hex: 0xF6F6F7),
                             ok: Color(hex: 0x2F9E5A), warn: Color(hex: 0xC9853A), bad: Color(hex: 0xD94F45))
    static let dark = Theme(accent: Color(hex: 0xE2A54A), accentInk: Color(hex: 0xF0C47C), accentSoft: Color(hex: 0xE2A54A).opacity(0.16),
                            ink: Color(hex: 0xF2F2F4), ink2: Color(hex: 0xA1A1A8), ink3: Color(hex: 0x6A6A70),
                            side: Color(hex: 0x2A2A2D), content: Color(hex: 0x1E1E21), card: Color(hex: 0x27272B), cardBorder: Color.white.opacity(0.08), sep: Color.white.opacity(0.10),
                            ctl: Color.white.opacity(0.07), ctl2: Color.white.opacity(0.12), chip: Color(hex: 0x303034), code: Color(hex: 0x232326),
                            ok: Color(hex: 0x2F9E5A), warn: Color(hex: 0xC9853A), bad: Color(hex: 0xD94F45))
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.light }
extension EnvironmentValues { var theme: Theme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
}

// MARK: - Paper components

struct CardBox<Content: View>: View {
    @Environment(\.theme) var t
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

struct Chip: View {
    @Environment(\.theme) var t
    let text: String
    var accent = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(accent ? t.accentInk : t.ink2)
            .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(accent ? t.accentSoft : t.chip))
    }
}

struct Eyebrow: View {
    @Environment(\.theme) var t
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(t.ink2) }
}

enum ButtonKind { case primary, normal, quiet, destructive }
struct BButton: View {
    @Environment(\.theme) var t
    let title: String; var kind: ButtonKind = .normal; var systemImage: String? = nil; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let s = systemImage { Image(systemName: s).font(.system(size: 12, weight: .semibold)) }; Text(title) }
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                .foregroundStyle(fg).background(RoundedRectangle(cornerRadius: 6).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(kind == .normal || kind == .destructive ? t.cardBorder : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    var fg: Color { switch kind { case .primary: return Color(hex: 0x1A1205); case .quiet: return t.ink2; case .destructive: return t.bad; case .normal: return t.ink } }
    var bg: Color { switch kind { case .primary: return t.accent; case .quiet: return .clear; default: return t.card } }
}

struct UrgencyDot: View {
    @Environment(\.theme) var t
    let urgency: Urgency
    var body: some View { Circle().fill(urgency == .high ? t.bad : (urgency == .medium ? t.warn : Color(hex: 0x8E8E93))).frame(width: 8, height: 8) }
}

struct Pulse: View {
    @Environment(\.theme) var t
    var body: some View { Circle().fill(t.accent).frame(width: 10, height: 10).overlay(Circle().stroke(t.accentSoft, lineWidth: 4)) }
}

struct StepRow: View {
    @Environment(\.theme) var t
    let text: String; let done: Bool; var current = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack { Circle().fill(done ? t.ok : (current ? t.accent : t.ctl2)).frame(width: 18, height: 18); if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
            Text(text).foregroundStyle(done || current ? t.ink : t.ink2)
        }
    }
}

struct Toggle2: View {
    @Environment(\.theme) var t
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? t.accent : t.ctl2).frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).shadow(color: .black.opacity(0.25), radius: 1, y: 1).padding(2)
            }
        }.buttonStyle(.plain).animation(.easeInOut(duration: 0.15), value: on)
    }
}

struct Segmented: View {
    @Environment(\.theme) var t
    let options: [String]; @Binding var selection: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    Text(o).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 24)
                        .foregroundStyle(selection == o ? t.ink : t.ink2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == o ? t.card : .clear).shadow(color: .black.opacity(selection == o ? 0.12 : 0), radius: 1, y: 1))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 8).fill(t.ctl))
    }
}

struct SettingRow<Trailing: View>: View {
    @Environment(\.theme) var t
    let title: String; var detail: String = ""; @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) { Text(title).fontWeight(.medium); if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(t.ink2) } }
            Spacer(); trailing
        }.padding(.vertical, 10)
    }
}
