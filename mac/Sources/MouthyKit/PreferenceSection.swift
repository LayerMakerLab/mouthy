import SwiftUI
import MouthyNotch

/// A titled settings tile. Explicit sections avoid GroupBox's title-element indirection in the macOS
/// accessibility tree while keeping individually accessible child controls.
struct PreferenceSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Tile(padding: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TileHeader(title)
                    .padding(.horizontal, 20).padding(.top, 16)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
    }
}
