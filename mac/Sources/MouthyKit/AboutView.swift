import SwiftUI
import AppKit
import MouthyNotch

/// Settings → About: the live giraffe, the wordmark, the real version and build, the shortcut and the licences.
struct AboutView: View {
    @ObservedObject var model: AppModel
    var versionLine: String = AppVersion.current
    var licensesFolder: URL? = AppVersion.licensesFolder
    let close: () -> Void

    var body: some View {
        ZStack {
            MouthyBackdrop(glow: 0.16)
            VStack(spacing: 0) {
                Spacer(minLength: 18)
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [MouthyTheme.glow.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 150))
                        .frame(width: 300, height: 300)
                    Giraffe3DView(fallbackPose: .wave, size: 210)
                }
                .frame(height: 220)

                Text("mouthy")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(MouthyTheme.cream)
                Text("Two microphones. No cloud.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(MouthyTheme.glow)
                    .padding(.top, 2)
                Text(versionLine)
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .textSelection(.enabled)
                    .padding(.top, 10)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        KeycapRow(shortcut: model.shortcutLabel)
                        Text(model.preferences.shortcut == 5 ? "hold to talk"
                             : model.preferences.shortcut == 4 ? "double-tap to start and finish dictation" : "starts and finishes dictation")
                            .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                        Text("Speech, cleanup and history run on this Mac.")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).fill(MouthyTheme.surface.opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
                .padding(.top, 18)

                Text("Free software under the GNU GPL v3.0 · © 2026 LayerMaker LLC")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream3)
                    .padding(.top, 16)

                Spacer(minLength: 14)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("mouthy.dev") { if let url = URL(string: "https://mouthy.dev") { NSWorkspace.shared.open(url) } }
                            .buttonStyle(.compact)
                        Button("Licences") { if let licensesFolder { NSWorkspace.shared.open(licensesFolder) } }
                            .buttonStyle(.compact)
                            .disabled(licensesFolder == nil)
                            .help(licensesFolder == nil ? "Licences ship inside the packaged app." : "Open the third-party licences")
                        Spacer()
                        Button("Done", action: close)
                            .buttonStyle(.compactProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
        .frame(width: 440, height: 600)
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
        .foregroundStyle(MouthyTheme.cream)
    }
}
