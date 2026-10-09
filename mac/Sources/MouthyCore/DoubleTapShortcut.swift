import Foundation

/// A right-Command tap must be short and unaccompanied by another key.
public struct DoubleTapShortcut {
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var firstPressedAt: TimeInterval?
    /// When the first tap of the last recognized double tap went down (event clock, seconds since boot). Audio from
    /// here on is the shortcut being pressed, not speech.
    public private(set) var gestureStartedAt: TimeInterval?
    public init() {}
    public mutating func reset() { pressedAt = nil; releasedAt = nil; firstPressedAt = nil }
    /// macOS key code 54 identifies right Command. Some keyboard remappers emit
    /// only the aggregate Command flag, without device-specific left/right bits.
    public mutating func update(keyCode: UInt16, modifierFlags: UInt, isModifierEvent: Bool, timestamp: TimeInterval) -> Bool {
        let command: UInt = 1 << 20
        let leftCommand: UInt = 0x08
        let rightCommand: UInt = 0x10
        let otherModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 23)
        guard isModifierEvent, keyCode == 54,
              modifierFlags & (otherModifiers | leftCommand) == 0 else {
            reset()
            return false
        }
        return update(isDown: modifierFlags & (command | rightCommand) != 0, timestamp: timestamp)
    }
    public mutating func update(isDown: Bool, timestamp: TimeInterval) -> Bool {
        if isDown {
            // A press always starts fresh: a release lost to secure input must not cost the next double tap.
            pressedAt = timestamp
            return false
        }
        guard let pressedAt else { return false }
        self.pressedAt = nil
        guard timestamp >= pressedAt, timestamp - pressedAt <= 0.3 else { releasedAt = nil; return false }
        // The interval is between taps, not between releases: a second tap
        // beginning inside the window remains valid until its short release.
        if let last = releasedAt, pressedAt >= last, pressedAt - last <= 0.4 {
            releasedAt = nil
            gestureStartedAt = firstPressedAt ?? pressedAt
            firstPressedAt = nil
            return true
        }
        releasedAt = timestamp
        firstPressedAt = pressedAt
        return false
    }
}
