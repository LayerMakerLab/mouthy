import SwiftUI

/// The giraffe's poses. Pose = state, the same everywhere: listen = recording, talk = agent question,
/// type = finishing or delivering, sleep = idle or empty, wave = hello, cheer = success.
public enum MascotPose: String, CaseIterable, Sendable, Hashable {
    case listen, talk, type, sleep, wave, cheer

    /// SF Symbol stand-in when no artwork is installed (host apps).
    public var symbolName: String {
        switch self {
        case .listen: "mic.fill"
        case .talk: "bubble.left.fill"
        case .type: "keyboard.fill"
        case .sleep: "moon.zzz.fill"
        case .wave: "hand.wave.fill"
        case .cheer: "checkmark"
        }
    }
}

/// Artwork hooks for notch surfaces. MouthyKit installs the giraffe; hosts that leave it nil get SF Symbols.
@MainActor public enum NotchArt {
    public static var mascot: (@MainActor (MascotPose) -> Image?)?
}

/// The giraffe's head for a pose, or its SF Symbol in mic-glow amber.
public struct MascotGlyph: View {
    let pose: MascotPose
    let size: CGFloat
    public init(pose: MascotPose, size: CGFloat = 20) { self.pose = pose; self.size = size }
    public var body: some View {
        Group {
            if let image = NotchArt.mascot?(pose) {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: pose.symbolName)
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(MouthyTheme.glow)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
