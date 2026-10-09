import AppKit
import CoreGraphics

/// While dictating, a plain Return/Enter press sends what was said so far and keeps listening.
/// The key is taken before the focused app sees it, so the app does not submit its field early.
/// Shift/Option/Command/Control+Return pass through unchanged, as do Mouthy's own synthetic Returns.
@MainActor
final class ReturnKeyTap {
    /// Marks events Mouthy posts itself (TextDelivery.pressReturn) so the tap lets them through.
    nonisolated static let syntheticMarker: Int64 = 0x564F_4943
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Return true to consume the key press.
    var onReturn: (() -> Bool)?
    /// Escape while dictating cancels it and never reaches the app (Esc interrupts agents in terminals).
    var onEscape: (() -> Void)?
    private var consumedEscape = false
    private var consumedDown = false

    var isActive: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<ReturnKeyTap>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.handle(type, event) }
        }, userInfo: context) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil; source = nil; consumedDown = false; consumedEscape = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if key == 53 {
            if type == .keyUp { if consumedEscape { consumedEscape = false; return nil }; return Unmanaged.passUnretained(event) }
            consumedEscape = true
            onEscape?()
            return nil
        }
        guard key == 36 || key == 76, event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            // Swallow the release that belongs to a consumed press.
            if consumedDown { consumedDown = false; return nil }
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]
        guard event.flags.intersection(modifiers).isEmpty, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        if onReturn?() == true { consumedDown = true; return nil }
        return Unmanaged.passUnretained(event)
    }
}
