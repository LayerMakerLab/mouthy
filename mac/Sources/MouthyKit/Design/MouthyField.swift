import SwiftUI
import MouthyNotch

/// A plain text field on raised cocoa with a mic-glow ring while focused (system focus rings draw blue).
struct MouthyField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ prompt: String, text: Binding<String>, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt; self._text = text; self.onSubmit = onSubmit
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous)
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(MouthyTheme.cream3))
            .textFieldStyle(.plain)
            .font(MouthyType.body)
            .foregroundStyle(MouthyTheme.cream)
            .focusEffectDisabled()
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(shape.fill(MouthyTheme.raised))
            .overlay(shape.strokeBorder(focused ? MouthyTheme.glow : MouthyTheme.hoof, lineWidth: focused ? 1.5 : 1))
            .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: focused)
            .accessibilityLabel(prompt)
    }
}
