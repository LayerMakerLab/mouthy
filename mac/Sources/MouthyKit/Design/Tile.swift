import SwiftUI
import MouthyNotch

enum TileStyle { case standard, raised, hero, dashed }

/// A floating content card: opaque warm cocoa over the backdrop, a hoof hairline, a cream top highlight
/// and a soft shadow. Glass is reserved for the control layer, so tiles stay solid.
struct Tile<Content: View>: View {
    var padding: CGFloat
    var style: TileStyle
    let content: Content

    init(padding: CGFloat = 20, style: TileStyle = .standard, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.style = style; self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { TileBackground(style: style) }
    }
}

struct TileBackground: View {
    let style: TileStyle
    var radius: CGFloat = MouthyTheme.Radius.tile
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if style == .dashed {
            shape.strokeBorder(MouthyTheme.cream2.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        } else {
            shape.fill(style == .raised ? MouthyTheme.raised.opacity(0.94) : MouthyTheme.surface.opacity(0.88))
                .overlay(shape.fill(LinearGradient(stops: [.init(color: MouthyTheme.cream.opacity(0.10), location: 0), .init(color: .clear, location: 0.4)],
                                                   startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(MouthyTheme.hoof, lineWidth: 1))
                .shadow(color: MouthyTheme.shadow, radius: MouthyTheme.shadowRadius, y: MouthyTheme.shadowY)
                .shadow(color: style == .hero ? MouthyTheme.orange.opacity(0.18) : .clear, radius: 30)
        }
    }
}

/// Lifts a tile under the pointer: a little larger with a deeper shadow.
struct TileHover: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: hovering ? 24 : 18, y: hovering ? 14 : 10)
            .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func tileHover() -> some View { modifier(TileHover()) }
}

/// A tile's title line: optional symbol in glow, the title, then trailing controls.
struct TileHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    let trailing: Trailing

    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.symbol = symbol; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    .frame(width: 18)
            }
            Text(title).font(MouthyType.section).foregroundStyle(MouthyTheme.cream2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension TileHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) { self.init(title, symbol: symbol) { EmptyView() } }
}
