import SwiftUI
import AppKit

/// The palette: soft charcoal and paper, one leaf-lime accent used sparingly (the main button, rings, level bars,
/// switches, small icons), and the giraffe as the only orange thing on screen. App windows follow the Mac's
/// appearance: light (paper, white cards, near-black ink) or dark (charcoal, soft white ink). Locked on a design board
/// of real renders, 2026-11-25.
/// The notch, the recording pill and anything else that sits on the black screen edge are always dark. Each token
/// keeps its role in both. The names are from the first palette (a cocoa and copper one, replaced 2026-11-25) and
/// stay because host apps use them: `night` is the backdrop, `cream` the main ink, `orange` the accent fill, `glow`
/// the accent ink, `hoof` the hairline. Never blue.
public enum MouthyTheme {
    // Backgrounds
    public static let night = dynamic(dark: 0x171717, light: 0xF5F5F1)
    public static let night2 = dynamic(dark: 0x1F1F1F, light: 0xEBEBE6)
    // Surfaces
    public static let surface = dynamic(dark: 0x272727, light: 0xFFFFFF)
    public static let raised = dynamic(dark: 0x313131, light: 0xF7F7F4)
    /// Hairlines and deep shadows.
    public static let hoof = dynamic(dark: 0x3E3E3E, light: 0xDEDED8)
    public static let hairline = hoof
    // Accent: leaf lime. The fill is the same in both appearances; ink on it is always dark.
    public static let orange = Color(hex: 0xC2F04E)
    public static let patch = Color(hex: 0xAEE23A)
    public static let glow = dynamic(dark: 0xCFF56A, light: 0x3F7A12)
    public static let glowHi = dynamic(dark: 0xE4FAA4, light: 0x6CAE2A)
    // Text
    public static let cream = dynamic(dark: 0xF2F2EE, light: 0x171717)
    public static let cream2 = dynamic(dark: 0xA6A6A0, light: 0x5F5F5A)
    public static let cream3 = cream2.opacity(0.75)
    /// Ink on the accent (primary buttons, selected chips): dark in both appearances.
    public static let onOrange = Color(hex: 0x131B08)
    /// Ear pink: a success flourish only.
    public static let pink = dynamic(dark: 0xF2A0A6, light: 0xE07882)
    /// The giraffe's own light: the microphones on its head are warm lamps, whatever the accent is.
    public static let lamp = Color(hex: 0xFFC25C)
    public static let lampHi = Color(hex: 0xFFE3A6)
    /// Errors and attention.
    public static let ember = dynamic(dark: 0xFF6B57, light: 0xC93522)
    /// Switches: the off track and the knob (white on a light window).
    public static let switchTrack = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0x101010, alpha: 0.8) : NSColor(srgb: 0xE2E2DC, alpha: 1)
    })
    public static let knob = dynamic(dark: 0xF2F2EE, light: 0xFFFFFF)
    public static let knobOff = dynamic(dark: 0xA6A6A0, light: 0xFFFFFF)
    /// The lit top edge of tiles and glass.
    public static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0xF2F2EE, alpha: 0.08) : NSColor(srgb: 0xFFFFFF, alpha: 0.7)
    })

    /// The lit top of primary buttons (nearly the fill: a flat button, not polished metal).
    public static let primaryTop = Color(hex: 0xCCF462)

    /// Every solid token by name. The hex tables below are read from these colours, so each value is written once.
    public static let named: [(name: String, color: Color)] = [
        ("night", night), ("night2", night2), ("surface", surface), ("raised", raised), ("hoof", hoof),
        ("orange", orange), ("patch", patch), ("glow", glow), ("glowHi", glowHi), ("cream", cream), ("cream2", cream2),
        ("onOrange", onOrange), ("pink", pink), ("lamp", lamp), ("lampHi", lampHi), ("ember", ember), ("knob", knob), ("knobOff", knobOff), ("primaryTop", primaryTop)
    ]
    /// Every solid token as sRGB hex in the dark (notch) appearance, for tests and tooling.
    public static var tokens: [(name: String, hex: UInt32)] { named.compactMap { t in hexValue(t.color).map { (t.name, $0) } } }
    /// The same tokens in the light appearance (windows in Light mode).
    public static var lightTokens: [(name: String, hex: UInt32)] { named.compactMap { t in hexValue(t.color, dark: false).map { (t.name, $0) } } }

    /// Window background, top-leading to bottom-trailing.
    public static let backdrop = LinearGradient(colors: [night, night2], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Primary buttons: the accent, a touch lighter at the top.
    public static let primaryFill = LinearGradient(colors: [primaryTop, orange, patch], startPoint: .top, endPoint: .bottom)
    /// Level bars and progress.
    public static let barFill = LinearGradient(colors: [glowHi, orange], startPoint: .top, endPoint: .bottom)
    /// The accent as a soft gradient (the notch's old silver roles).
    public static let metal = LinearGradient(colors: [glowHi, orange, patch], startPoint: .top, endPoint: .bottom)

    // Opacity and elevation conventions
    public static let hoverFill = cream.opacity(0.05)
    public static let shadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0x000000, alpha: 0.35) : NSColor(srgb: 0x1A1A1A, alpha: 0.10)
    })
    public static let shadowRadius: CGFloat = 18
    public static let shadowY: CGFloat = 10
    /// The solid surface used in place of glass when Reduce Transparency is on.
    public static let solidGlass = surface

    // Spacing and radii
    public enum Space {
        public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 40
    }
    public enum Radius {
        /// The corner macOS gives Mouthy's windows (AppKit reports 16 for a titled window, toolbar or not, macOS 26).
        public static let window: CGFloat = 16
        /// A card inset from a window's corner is concentric with it: its radius is the window's less the inset. The
        /// sidebar was 22 inside a 16-point corner, 10 points in, and its bright edge curved wider than the window's
        /// own.
        public static let sidebar: CGFloat = window - Layout.windowInset
        public static let tile: CGFloat = 20, card: CGFloat = 14, row: CGFloat = 10
    }
    public enum Layout {
        /// How far a card that meets a window's corner (the sidebar, the first-run stage) sits from the window's edges.
        public static let windowInset: CGFloat = 6
        public static let pageHorizontal: CGFloat = 36, pageTop: CGFloat = 32, contentMaxWidth: CGFloat = 860, tileGap: CGFloat = 20
    }

    /// A token that follows the appearance it is drawn in.
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(srgb: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }

    /// sRGB hex of a colour as drawn in the dark (notch) or light (window) appearance, or nil when it cannot be
    /// expressed in sRGB.
    static func hexValue(_ color: Color, dark: Bool = true) -> UInt32? {
        var srgb: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { srgb = NSColor(color).usingColorSpace(.sRGB) }
        guard let srgb else { return nil }
        let r = UInt32((srgb.redComponent * 255).rounded()), g = UInt32((srgb.greenComponent * 255).rounded()), b = UInt32((srgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

extension NSColor {
    convenience init(srgb hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// Draws a Mouthy surface in one appearance whatever the host or the Mac uses: `.dark` for the notch and the
    /// recording pill. Windows set none and follow the Mac.
    public func mouthyAppearance(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme).preferredColorScheme(scheme)
    }
}

extension Color {
    /// sRGB colour from 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
