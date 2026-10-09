import SwiftUI
import AppKit

/// The giraffe palette: night cocoa backgrounds, giraffe orange, mic-glow amber and cream. Never blue.
public enum MouthyTheme {
    // Backgrounds
    public static let night = Color(hex: 0x140C07)
    public static let night2 = Color(hex: 0x22140B)
    // Surfaces
    public static let surface = Color(hex: 0x2B1A10)
    public static let raised = Color(hex: 0x3A2416)
    /// Hoof chocolate: hairlines and deep shadows.
    public static let hoof = Color(hex: 0x4A2A17)
    public static let hairline = hoof
    // Brand
    public static let orange = Color(hex: 0xE08A2E)
    public static let patch = Color(hex: 0xC96F1E)
    public static let glow = Color(hex: 0xFFB547)
    public static let glowHi = Color(hex: 0xFFD27A)
    // Text
    public static let cream = Color(hex: 0xF6E3C1)
    public static let cream2 = Color(hex: 0xCBB08C)
    public static let cream3 = cream2.opacity(0.6)
    /// Ear pink: a success flourish only.
    public static let pink = Color(hex: 0xF2A0A6)
    /// Errors and attention.
    public static let ember = Color(hex: 0xEB6145)

    /// Every solid token as sRGB hex, for tests and tooling.
    public static let tokens: [(name: String, hex: UInt32)] = [
        ("night", 0x140C07), ("night2", 0x22140B), ("surface", 0x2B1A10), ("raised", 0x3A2416), ("hoof", 0x4A2A17),
        ("orange", 0xE08A2E), ("patch", 0xC96F1E), ("glow", 0xFFB547), ("glowHi", 0xFFD27A),
        ("cream", 0xF6E3C1), ("cream2", 0xCBB08C), ("pink", 0xF2A0A6), ("ember", 0xEB6145), ("primaryTop", 0xF2A24E)
    ]

    /// Window background, top-leading to bottom-trailing.
    public static let backdrop = LinearGradient(colors: [night, night2], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Primary buttons: lit top, giraffe orange, amber patch at the bottom.
    public static let primaryFill = LinearGradient(colors: [Color(hex: 0xF2A24E), orange, patch], startPoint: .top, endPoint: .bottom)
    /// Level bars and progress.
    public static let barFill = LinearGradient(colors: [glowHi, orange], startPoint: .top, endPoint: .bottom)
    /// Warm polished metal (the notch's old silver roles).
    public static let metal = LinearGradient(colors: [glowHi, orange, patch], startPoint: .top, endPoint: .bottom)

    // Opacity and elevation conventions
    public static let hoverFill = cream.opacity(0.05)
    public static let shadow = Color.black.opacity(0.35)
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

    /// sRGB hex of a colour, or nil when it cannot be expressed in sRGB.
    static func hexValue(_ color: Color) -> UInt32? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = UInt32((srgb.redComponent * 255).rounded()), g = UInt32((srgb.greenComponent * 255).rounded()), b = UInt32((srgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

extension Color {
    /// sRGB colour from 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
