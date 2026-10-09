import SwiftUI
import MouthyNotch

/// The notch peek for an on-device answer (`NotchHub.peek`): the question in secondary text, the answer in
/// cream beside the talking giraffe. A nil answer is the "Thinking…" state with the listening giraffe. Static:
/// no repeating animation, so it costs nothing while it sits on screen.
struct NotchAnswerCard: View {
    let question: String
    /// Nil while the model is still thinking.
    let answer: String?

    /// What VoiceOver reads and the band's word.
    var accessibilityTitle: String { answer == nil ? "Thinking" : "Answer" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MascotGlyph(pose: answer == nil ? .listen : .talk, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(question)
                    .font(.system(size: 12))
                    .foregroundStyle(MouthyTheme.cream2)
                    .lineLimit(2)
                Text(answer ?? "Thinking…")
                    .font(.system(size: 14, weight: answer == nil ? .regular : .medium, design: .rounded))
                    .foregroundStyle(answer == nil ? MouthyTheme.cream2 : MouthyTheme.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
