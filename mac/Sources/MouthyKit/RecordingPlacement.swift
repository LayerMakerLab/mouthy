import AppKit

/// Where the recording island lives: top center of the screen, merged into its top edge — grown out
/// of the camera notch on a notched display, or set into the empty middle of the menu bar elsewhere.
struct IslandGeometry: Equatable {
    /// The transparent panel, larger than the island so it can grow (hover, outcome, agent question) without moving.
    let panel: NSRect
    /// Island height (notch or menu-bar height, or the floating pill's height).
    let height: CGFloat
    /// Physical notch width (0 without a notch); content stays out of it.
    let notchWidth: CGFloat
    /// Width of the island when resting.
    let restingWidth: CGFloat
    /// A floating pill in a bottom corner (displays without a notch) rather than attached to the top edge.
    var floating = false
    /// For a floating pill, the corner it hugs; it grows toward the middle of the screen.
    var corner: IslandCorner = .top
    /// Extra width when hovered.
    static let hoverGrowth: CGFloat = 36
    /// Extra width while the outcome ("Inserted · Notes") shows.
    static let successGrowth: CGFloat = 60
    /// Extra width while an agent's question shows.
    static let questionGrowth: CGFloat = 180
    /// Room below (or above, for a floating pill) for a second line or the expanded question.
    static let expansion: CGFloat = 60
    /// Outward fillet where the island meets the screen edge, like the hardware notch.
    static let shoulder: CGFloat = 7
    /// Space kept around the island for the attention shake and the soft shadow.
    static let margin: CGFloat = 10
}

/// Where the recording island goes on displays without a notch (the notch display always uses the notch).
enum IslandCorner: Int { case top = 0, bottomLeft = 1, bottomRight = 2 }

enum RecordingPlacement {
    /// Resting width of the island where the label sits inline (no notch in the way).
    static let inlineWidth: CGFloat = 236
    /// Height of the floating corner pill.
    static let floatingHeight: CGFloat = 36

    static func island(screen: NSRect, visible: NSRect, notchLeft: CGFloat?, notchRight: CGFloat?, notchHeight: CGFloat,
                       corner: IslandCorner = .top) -> IslandGeometry {
        let notched = notchHeight > 0 && (notchLeft ?? 0) > 0 && (notchRight ?? 0) > (notchLeft ?? 0)
        let growth = max(IslandGeometry.hoverGrowth, IslandGeometry.successGrowth, IslandGeometry.questionGrowth)
        if !notched, corner != .top {
            // A compact floating pill above the Dock, out of the way in a bottom corner.
            let height = floatingHeight, resting = inlineWidth, inset: CGFloat = 18
            let width = resting + growth + 2 * IslandGeometry.margin
            let x = corner == .bottomLeft ? visible.minX + inset - IslandGeometry.margin : visible.maxX - inset - width + IslandGeometry.margin
            let panel = NSRect(x: x, y: visible.minY + inset - IslandGeometry.margin, width: width,
                               height: height + 2 * IslandGeometry.margin + IslandGeometry.expansion)
            return IslandGeometry(panel: panel, height: height, notchWidth: 0, restingWidth: resting, floating: true, corner: corner)
        }
        let height: CGFloat
        let notchWidth: CGFloat
        let center: CGFloat
        let resting: CGFloat
        if notchHeight > 0, let left = notchLeft, let right = notchRight, right > left {
            height = notchHeight
            notchWidth = right - left
            center = (left + right) / 2
            resting = notchWidth + 2 * 64
        } else {
            // External displays: match the menu bar so the island reads as part of the screen edge.
            let menuBar = screen.maxY - visible.maxY
            height = min(38, max(26, menuBar > 0 ? menuBar : 30))
            notchWidth = 0
            center = screen.midX
            resting = inlineWidth
        }
        let width = resting + growth + 2 * (IslandGeometry.shoulder + IslandGeometry.margin)
        let x = min(max(screen.minX, center - width / 2), screen.maxX - width)
        let panelHeight = height + IslandGeometry.margin + IslandGeometry.expansion
        let panel = NSRect(x: x, y: screen.maxY - panelHeight, width: width, height: panelHeight)
        return IslandGeometry(panel: panel, height: height, notchWidth: notchWidth, restingWidth: resting)
    }
}
