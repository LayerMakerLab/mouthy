import SwiftUI

/// Mouthy's type scale: SF Pro Rounded for display, SF Pro for body. No serif, no tracked caps.
public enum MouthyType {
    public static let title = Font.system(size: 30, weight: .semibold, design: .rounded)
    public static let titleTracking: CGFloat = -0.6
    public static let headline = Font.system(size: 17, weight: .semibold, design: .rounded)
    /// Shown in cream2.
    public static let section = Font.system(size: 13, weight: .semibold, design: .rounded)
    public static let body = Font.system(size: 14)
    public static let callout = Font.system(size: 13)
    /// Shown in cream2.
    public static let caption = Font.system(size: 12)
    public static let numeral = Font.system(size: 26, weight: .medium, design: .rounded).monospacedDigit()
    public static let numeralLarge = Font.system(size: 34, weight: .medium, design: .rounded).monospacedDigit()
    public static let notchTimer = Font.system(size: 22, weight: .regular, design: .rounded).monospacedDigit()
    public static let notchStopwatch = Font.system(size: 28, weight: .regular, design: .rounded).monospacedDigit()
    public static let notchUsage = Font.system(size: 18, weight: .regular, design: .rounded).monospacedDigit()
}

/// One set of springs for the whole app, so every surface moves the same way.
public enum MouthyMotion {
    public static let page = Animation.smooth(duration: 0.32)
    public static let select = Animation.spring(response: 0.34, dampingFraction: 0.82)
    public static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    public static let hover = Animation.easeOut(duration: 0.18)
    public static let pose = Animation.spring(response: 0.4, dampingFraction: 0.75)
    public static let toast = Animation.spring(response: 0.4, dampingFraction: 0.8)
    public static let notchOpen = Animation.spring(response: 0.38, dampingFraction: 0.8)
    public static let notchClose = Animation.spring(response: 0.3, dampingFraction: 0.92)
    public static let tab = Animation.spring(response: 0.32, dampingFraction: 0.86)
    public static let morph = Animation.spring(response: 0.36, dampingFraction: 0.9)
    /// Growing out of the bare notch into a live state: quicker than `morph`, because the ears show only once the
    /// wings cover them (about 80% of the way) and the person speaking should see them within about 110 ms.
    public static let grow = Animation.spring(response: 0.2, dampingFraction: 0.9)
    /// The notch's content changing in place (a pose, an ear, one state's words for the next): a 100 ms
    /// cross-dissolve with no delay, so no frame between two states is empty.
    public static let dissolve = Animation.easeInOut(duration: 0.1)
    /// What every animation becomes when Reduce Motion is on.
    public static let reduced = Animation.easeInOut(duration: 0.15)

    /// `animation`, or a short ease when Reduce Motion is on.
    public static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}
