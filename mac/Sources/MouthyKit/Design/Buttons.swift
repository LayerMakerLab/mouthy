import SwiftUI
import MouthyNotch

/// The one orange call to action, drawn by hand so it stays orange in windows that are not key.
struct MouthyPrimaryButtonStyle: ButtonStyle {
    enum Size { case regular, large }
    var size: Size = .regular
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, height: size == .large ? 52 : 44)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: height > 44 ? 16 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(enabled ? MouthyTheme.night : MouthyTheme.cream)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 22)
                .frame(minHeight: height)
                .background {
                    // Disabled: the fill fades, the label turns cream, so a dimmed parent never fades the text twice.
                    Capsule(style: .circular).fill(MouthyTheme.primaryFill).opacity(enabled ? 1 : 0.45)
                        .overlay(Capsule(style: .circular).strokeBorder(LinearGradient(colors: [MouthyTheme.cream.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                        .shadow(color: MouthyTheme.orange.opacity(enabled ? 0.35 : 0), radius: 12, y: 4)
                }
                .brightness(hovering && enabled ? 0.05 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(Capsule(style: .circular))
                .onHover { hovering = $0 }
                .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        }
    }
}

extension ButtonStyle where Self == MouthyPrimaryButtonStyle {
    static var mouthyPrimary: MouthyPrimaryButtonStyle { MouthyPrimaryButtonStyle() }
    static var mouthyPrimaryLarge: MouthyPrimaryButtonStyle { MouthyPrimaryButtonStyle(size: .large) }
}

/// The secondary action beside a primary one: a warm glass capsule at the same height.
/// Use it instead of `.buttonStyle(.glass)` so offscreen renders and Reduce Transparency still draw it.
struct MouthySecondaryButtonStyle: ButtonStyle {
    var size: MouthyPrimaryButtonStyle.Size = .regular
    func makeBody(configuration: Configuration) -> some View { SecondaryBody(configuration: configuration, height: size == .large ? 52 : 44) }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: height > 44 ? 16 : 15, weight: .medium, design: .rounded))
                .foregroundStyle(MouthyTheme.cream)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 20)
                .frame(minHeight: height)
                .contentShape(Capsule(style: .circular))
                .mouthyGlass(Capsule(style: .circular), interactive: true)
                .overlay(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(hovering && enabled ? 0.05 : 0)).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        }
    }
}

extension ButtonStyle where Self == MouthySecondaryButtonStyle {
    static var mouthySecondary: MouthySecondaryButtonStyle { MouthySecondaryButtonStyle() }
    static var mouthySecondaryLarge: MouthySecondaryButtonStyle { MouthySecondaryButtonStyle(size: .large) }
}

/// Rows and tiles that act as buttons: a gentle press, a faint hover fill and a link pointer.
struct MouthyPressableStyle: ButtonStyle {
    var radius: CGFloat = MouthyTheme.Radius.row
    func makeBody(configuration: Configuration) -> some View { PressableBody(configuration: configuration, radius: radius) }

    private struct PressableBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? MouthyTheme.hoverFill : .clear))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        }
    }
}

/// A 28 pt glass circle with one symbol and a tooltip.
struct MouthyIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    init(symbol: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.role = role; self.action = action
    }
    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .destructive ? MouthyTheme.ember : MouthyTheme.cream)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mouthyGlass(Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small capsule label: trigger words, shortcuts, modes, states.
struct MouthyChip: View {
    enum Tone { case neutral, glow, ember }
    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    init(_ text: String, symbol: String? = nil, tone: Tone = .neutral) { self.text = text; self.symbol = symbol; self.tone = tone }
    var body: some View {
        let ink: Color = switch tone { case .neutral: MouthyTheme.cream2; case .glow: MouthyTheme.glow; case .ember: MouthyTheme.ember }
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(ink)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule(style: .circular).fill(tone == .neutral ? MouthyTheme.raised : ink.opacity(0.14)))
        .overlay(Capsule(style: .circular).strokeBorder(tone == .neutral ? MouthyTheme.hoof : ink.opacity(0.28), lineWidth: 1))
    }
}

/// A shortcut drawn as keycaps: one per modifier glyph, then the key.
struct KeycapRow: View {
    let shortcut: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.keys(for: shortcut).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(MouthyTheme.cream)
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(MouthyTheme.raised)
                        .shadow(color: .black.opacity(0.4), radius: 0, y: 1))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut)
    }

    /// "⌃⌥Space" → ["⌃", "⌥", "Space"]; "Hold Fn" → ["Fn"]; "Double-tap Right ⌘" → ["Right ⌘"].
    static func keys(for shortcut: String) -> [String] {
        var rest = Substring(shortcut.trimmingCharacters(in: .whitespaces))
        for prefix in ["Hold ", "Double-tap ", "Press "] where rest.hasPrefix(prefix) { rest = rest.dropFirst(prefix.count) }
        var keys: [String] = []
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            keys.append(String(first)); rest = rest.dropFirst()
            rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        }
        let key = rest.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { keys.append(key) }
        return keys
    }
}
