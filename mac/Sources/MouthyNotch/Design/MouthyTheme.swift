import SwiftUI
import AppKit

/// The giraffe palette. App windows follow the Mac's appearance: light (sunlit cream, white cards, cocoa ink, giraffe
/// orange) or dark (night cocoa, cream ink). The notch, the recording pill and anything else that sits on the black
/// screen edge are always dark. Each token keeps its role in both: `night` is the backdrop, `cream` the main ink,
/// `glow` the accent ink. Never blue.
public enum MouthyTheme {
    // Backgrounds
    public static let night = dynamic(dark: 0x140C07, light: 0xFFF4E3)
    public static let night2 = dynamic(dark: 0x22140B, light: 0xFFE3BD)
    // Surfaces
    public static let surface = dynamic(dark: 0x2B1A10, light: 0xFFFCF7)
    public static let raised = dynamic(dark: 0x3A2416, light: 0xFFF5E8)
    /// Hoof chocolate: hairlines and deep shadows.
    public static let hoof = dynamic(dark: 0x4A2A17, light: 0xF0D8B6)
    public static let hairline = hoof
    // Brand
    public static let orange = Color(hex: 0xE08A2E)
    public static let patch = Color(hex: 0xC96F1E)
    public static let glow = dynamic(dark: 0xFFB547, light: 0xD9700F)
    public static let glowHi = dynamic(dark: 0xFFD27A, light: 0xF5A94A)
    // Text
    public static let cream = dynamic(dark: 0xF6E3C1, light: 0x2B1A10)
    public static let cream2 = dynamic(dark: 0xCBB08C, light: 0x7A5838)
    public static let cream3 = cream2.opacity(0.6)
    /// Ink on giraffe orange (primary buttons, selected chips): dark in both appearances.
    public static let onOrange = Color(hex: 0x140C07)
    /// Ear pink: a success flourish only.
    public static let pink = dynamic(dark: 0xF2A0A6, light: 0xE07882)
    /// Errors and attention.
    public static let ember = dynamic(dark: 0xEB6145, light: 0xD4472B)
    /// Switches: the off track and the knob (white on a light window).
    public static let switchTrack = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0x140C07, alpha: 0.8) : NSColor(srgb: 0xEFDCC0, alpha: 1)
    })
    public static let knob = dynamic(dark: 0xF6E3C1, light: 0xFFFFFF)
    public static let knobOff = dynamic(dark: 0xCBB08C, light: 0xFFFFFF)
    /// The lit top edge of tiles and glass.
    public static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0xF6E3C1, alpha: 0.10) : NSColor(srgb: 0xFFFFFF, alpha: 0.7)
    })

    /// The lit top of primary buttons.
    public static let primaryTop = Color(hex: 0xF2A24E)

    /// Every solid token by name. The hex tables below are read from these colours, so each value is written once.
    public static let named: [(name: String, color: Color)] = [
        ("night", night), ("night2", night2), ("surface", surface), ("raised", raised), ("hoof", hoof),
        ("orange", orange), ("patch", patch), ("glow", glow), ("glowHi", glowHi), ("cream", cream), ("cream2", cream2),
        ("onOrange", onOrange), ("pink", pink), ("ember", ember), ("knob", knob), ("knobOff", knobOff), ("primaryTop", primaryTop)
    ]
    /// Every solid token as sRGB hex in the dark (notch) appearance, for tests and tooling.
    public static var tokens: [(name: String, hex: UInt32)] { named.compactMap { t in hexValue(t.color).map { (t.name, $0) } } }
    /// The same tokens in the light appearance (windows in Light mode).
    public static var lightTokens: [(name: String, hex: UInt32)] { named.compactMap { t in hexValue(t.color, dark: false).map { (t.name, $0) } } }

    /// Window background, top-leading to bottom-trailing.
    public static let backdrop = LinearGradient(colors: [night, night2], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Primary buttons: lit top, giraffe orange, amber patch at the bottom.
    public static let primaryFill = LinearGradient(colors: [primaryTop, orange, patch], startPoint: .top, endPoint: .bottom)
    /// Level bars and progress.
    public static let barFill = LinearGradient(colors: [glowHi, orange], startPoint: .top, endPoint: .bottom)
    /// Warm polished metal (the notch's old silver roles).
    public static let metal = LinearGradient(colors: [glowHi, orange, patch], startPoint: .top, endPoint: .bottom)

    // Opacity and elevation conventions
    public static let hoverFill = cream.opacity(0.05)
    public static let shadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgb: 0x000000, alpha: 0.35) : NSColor(srgb: 0x8A4F18, alpha: 0.12)
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
        public static let sidebar: CGFloat = 22, tile: CGFloat = 20, card: CGFloat = 14, row: CGFloat = 10
    }
    public enum Layout {
        public static let pageHorizontal: CGFloat = 32, pageTop: CGFloat = 28, contentMaxWidth: CGFloat = 860, tileGap: CGFloat = 16
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
