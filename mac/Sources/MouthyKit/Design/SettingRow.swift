import SwiftUI
import MouthyNotch

/// One setting: title and optional detail on the left, its control in a fixed trailing column.
/// Pass `controlWidth: nil` for small controls (switches) so the text gets the row's width.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var controlWidth: CGFloat?
    let control: Control

    init(_ title: String, detail: String? = nil, controlWidth: CGFloat? = 220, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.controlWidth = controlWidth; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
                if let detail {
                    Text(detail).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            sizedControl
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var sizedControl: some View {
        let styled = control.toggleStyle(.switch).controlSize(.small).tint(MouthyTheme.orange)
        if let controlWidth {
            styled.frame(width: controlWidth, alignment: .trailing)
        } else {
            styled.fixedSize()
        }
    }
}

/// The hairline between setting rows.
struct SettingDivider: View {
    var body: some View { Rectangle().fill(MouthyTheme.hoof).frame(height: 1) }
}
