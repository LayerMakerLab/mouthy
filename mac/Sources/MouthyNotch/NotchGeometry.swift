import AppKit

/// Frames for the hub on one screen: the closed hover target over the hardware notch (or the middle of
/// the menu bar on a display without one) and the open panel that grows down from it.
public struct NotchGeometry: Equatable, Sendable {
    public let closed: NSRect
    /// The closed notch with a wing on each side: the one band every closed state shares (a tab's compact
    /// content, the dictation level, a result, a peek), so moving between them never covers more menu bar.
    public let closedWide: NSRect
    public let open: NSRect
    /// Physical notch width, 0 without a notch.
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat

    public static let openSize = CGSize(width: 520, height: 184)
    /// Transparent room around the open panel for its shadow and glow.
    public static let shadowMargin: CGFloat = 30
    /// Width of each wing beside the notch while closed: room for a 20 pt cover, the 18 pt giraffe, five level
    /// bars or a whole "12:34" at 11 pt (33.5 pt), so crowded menu bars keep their items. Every closed state
    /// uses it, so the band never jumps wider.
    public static let compactSide: CGFloat = 46
    /// The narrowest the camera gap gets in the band: room for the pills' middle on a display without a notch.
    public static let minimumCameraWidth: CGFloat = 180

    /// The camera gap the band and its hover target are built around. One value for both, so the tracker's
    /// frame and the drawn band agree on every notch width.
    public static func cameraWidth(notchWidth: CGFloat) -> CGFloat { max(notchWidth, minimumCameraWidth) }
    public var cameraWidth: CGFloat { Self.cameraWidth(notchWidth: notchWidth) }

    /// The band grown on the left only (a peek with nothing for the right ear): a wing left of the camera and
    /// nothing right of it, plus the resting hover target over the notch itself.
    public var closedLeftLive: NSRect {
        let band = NSRect(x: closedWide.midX - cameraWidth / 2 - Self.compactSide, y: closedWide.minY,
                          width: cameraWidth + Self.compactSide, height: closedWide.height)
        return band.union(closed)
    }

    /// The menu bar's height on a display without a notch (24–38 pt, 30 when it is hidden). The hub's band and
    /// the external pill both use it, so they are the same height.
    public static func menuBarHeight(screen: NSRect, visible: NSRect) -> CGFloat {
        let menuBar = screen.maxY - visible.maxY
        return min(38, max(24, menuBar > 0 ? menuBar : 30))
    }

    public static func on(screen: NSRect, visible: NSRect, notchLeft: CGFloat?, notchRight: CGFloat?, safeTop: CGFloat) -> NotchGeometry {
        let center: CGFloat
        let width: CGFloat
        let height: CGFloat
        if safeTop > 0, let left = notchLeft, let right = notchRight, right > left {
            center = (left + right) / 2; width = right - left; height = safeTop
        } else {
            center = screen.midX; width = 0; height = menuBarHeight(screen: screen, visible: visible)
        }
        // Hover target: the notch itself plus 4 pt each side so it is easy to reach, so passing nearby doesn't open it.
        let targetWidth = width > 0 ? width + 8 : 160
        let closed = NSRect(x: center - targetWidth / 2, y: screen.maxY - height, width: targetWidth, height: height)
        let wideWidth = cameraWidth(notchWidth: width) + 2 * compactSide
        let closedWide = NSRect(x: center - wideWidth / 2, y: screen.maxY - height, width: wideWidth, height: height)
        let openWidth = min(openSize.width, screen.width - 32)
        var x = center - openWidth / 2
        x = min(max(screen.minX + 16, x), screen.maxX - 16 - openWidth)
        let margin = shadowMargin
        let open = NSRect(x: x - margin, y: screen.maxY - openSize.height - margin, width: openWidth + 2 * margin, height: openSize.height + margin)
        return NotchGeometry(closed: closed, closedWide: closedWide, open: open, notchWidth: width, notchHeight: height)
    }

    @MainActor public static func on(_ screen: NSScreen) -> NotchGeometry {
        on(screen: screen.frame, visible: screen.visibleFrame, notchLeft: screen.auxiliaryTopLeftArea?.maxX,
           notchRight: screen.auxiliaryTopRightArea?.minX, safeTop: screen.safeAreaInsets.top)
    }

    /// The built-in notched display when present, else the main display.
    @MainActor public static func preferredScreen() -> NSScreen? {
        notchedScreen() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The display with a camera notch, if one is connected and awake (nil in clamshell).
    @MainActor public static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// The display under the pointer.
    @MainActor public static func pointerScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// Width of the pill when it shows both a tab's live content and the accessory readout (AI usage).
    public static let widePillWidth: CGFloat = 360

    /// The live-activity pill on a display without a notch: the hub's own shape at rest, menu-bar high and as
    /// wide as the band, so music, dictation and a result are one shape that never changes width (wider only
    /// while it also shows the accessory).
    public func pill(wide: Bool = false) -> NSRect {
        let width = wide ? max(Self.widePillWidth, closedWide.width) : closedWide.width
        return NSRect(x: closedWide.midX - width / 2, y: closedWide.minY, width: width, height: closedWide.height)
    }

    /// The invisible hover strip at the top centre of a display without a notch.
    public static func strip(on screen: NSRect) -> NSRect {
        NSRect(x: screen.midX - 80, y: screen.maxY - 3, width: 160, height: 3)
    }
}
