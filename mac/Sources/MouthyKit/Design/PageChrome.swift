import SwiftUI
import MouthyNotch

/// The window background: night cocoa with one warm pool of light behind the top of the content.
/// The glow rises while listening and animates only when that changes.
struct MouthyBackdrop: View {
    var glow: Double = 0.10
    var listening: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            MouthyTheme.backdrop
            RadialGradient(colors: [MouthyTheme.orange.opacity(listening ? 0.18 : glow), .clear],
                           center: UnitPoint(x: 0.58, y: 0.0), startRadius: 0, endRadius: 600)
                .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: listening)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Liquid Glass for the floating control layer, tinted warm, over a faint base fill so the structure
/// still reads where glass draws flat (offscreen renders). Solid cocoa with Reduce Transparency.
struct MouthyGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    var tint: Color = MouthyTheme.surface.opacity(0.55)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.mouthyFlatGlass) private var flatGlass
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(shape.fill(MouthyTheme.solidGlass))
                .overlay(shape.stroke(MouthyTheme.hoof, lineWidth: 1))
        } else if flatGlass {
            // Offscreen renders cannot capture Liquid Glass (its sampled layers draw blank), so they get
            // the base fill plus a lit rim that stands in for the glass edge.
            content.background(shape.fill(MouthyTheme.surface.opacity(0.55)))
                .overlay(shape.stroke(LinearGradient(colors: [MouthyTheme.cream.opacity(0.16), MouthyTheme.cream.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        } else {
            content
                .background(shape.fill(MouthyTheme.surface.opacity(0.35)))
                .glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
        }
    }
}

extension View {
    func mouthyGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color = MouthyTheme.surface.opacity(0.55)) -> some View {
        modifier(MouthyGlass(shape: shape, interactive: interactive, tint: tint))
    }
}

extension EnvironmentValues {
    /// Draws the glass layer flat (offscreen renders and tests).
    @Entry var mouthyFlatGlass = false
}

/// Page title, optional one-line subtitle and trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MouthyType.title).tracking(MouthyType.titleTracking).foregroundStyle(MouthyTheme.cream)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.bottom, 4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.init(title, subtitle: subtitle) { EmptyView() } }
}

/// A page's scrolling column: centred, at most 860 pt wide, with the standard margins and a soft top edge.
struct PageScroll<Content: View>: View {
    var spacing: CGFloat = MouthyTheme.Layout.tileGap
    let content: Content
    @State private var pageWidth: CGFloat = 0
    init(spacing: CGFloat = MouthyTheme.Layout.tileGap, @ViewBuilder content: () -> Content) {
        self.spacing = spacing; self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .pageColumn(pageWidth: pageWidth)
                .padding(.top, MouthyTheme.Layout.pageTop)
                // Room for the floating status toast, so the last tile can scroll clear of it.
                .padding(.bottom, 88)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    /// The page column, at most 860 pt wide and centred on the page itself (`pageWidth`, the scroll view's own
    /// width) rather than on its content. With a mouse attached a long page grows a scroll bar that takes room
    /// from the content; measuring the page keeps every page's column at the same place and width whether it
    /// scrolls or not.
    @ViewBuilder func pageColumn(pageWidth: CGFloat) -> some View {
        let layout = MouthyTheme.Layout.self
        if pageWidth > 0 {
            let column = max(0, min(layout.contentMaxWidth, pageWidth - 2 * layout.pageHorizontal))
            frame(width: column, alignment: .leading)
                .padding(.leading, (pageWidth - column) / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, layout.pageHorizontal)
                .frame(maxWidth: .infinity)
        }
    }
}
