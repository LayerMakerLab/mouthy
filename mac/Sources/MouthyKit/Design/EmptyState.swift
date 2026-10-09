import SwiftUI
import MouthyNotch

/// An empty page told by the giraffe: a pose, one headline, one line and at most one action.
struct MascotEmptyState: View {
    var pose: MascotPose = .sleep
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(pose: MascotPose = .sleep, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.pose = pose; self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            MascotView(pose: pose, size: 140)
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                .multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(MouthyTheme.cream2)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.mouthyPrimary).padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
