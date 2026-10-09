import SwiftUI
import MouthyNotch

/// The old palette names, mapped onto the giraffe theme so existing views keep compiling.
/// New code uses `MouthyTheme` directly.
enum Palette {
    static let background = MouthyTheme.night
    static let surface = MouthyTheme.surface
    static let accent = MouthyTheme.orange
    static let ink = MouthyTheme.cream
}
