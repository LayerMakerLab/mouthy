import AppKit
import ApplicationServices
import Carbon
import MouthyCore

@MainActor
final class HotkeyService {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var currentPreset = 0
    // Hold-Fn state: recording starts after a short hold with no other key, ends on release.
    private var fnHeld = false, fnStarted = false, fnOtherKey = false
    private var fnPending: DispatchWorkItem?
    private var doubleTap = DoubleTapShortcut()
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// When the shortcut that fired last began (event clock: seconds since boot). Recording stops here, so the
    /// shortcut's own key clicks are never recognized as words.
    private(set) var gestureStartedAt: TimeInterval?
    var onCancel: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onToggleHub: (() -> Void)?
    var onModeShortcut: ((Int) -> Void)?
    /// The dictation shortcut registered on a late retry after failing at first.
    var onLateRegistration: (() -> Void)?
    private var pasteLastReference: EventHotKeyRef?
    private var hubReference: EventHotKeyRef?
    private var modeReferences: [Int: EventHotKeyRef] = [:]
    /// The arguments of the last `register` call, used again after the Mac wakes.
    struct Registration: Equatable {
        var preset = 0, keyCode: UInt32 = 49, modifiers: UInt32 = 6144
        var modes: [ModeShortcut?] = []
    }
    private(set) var lastRegistration: Registration?
    private var carbonKeys: (preset: Int, keyCode: UInt32, modifiers: UInt32, modes: [ModeShortcut?]) = (0, 49, 6144, [])
    private var retries: [DispatchWorkItem] = []
    /// A shortcut is being recorded (`suspend()`): nothing re-registers until the next explicit `register`.
    private(set) var isSuspended = false
    /// False for a dry service (tests): `register` only records its arguments and never touches Carbon or event monitors.
    private let live: Bool
    /// Times `register` ran, including re-registration after wake.
    private(set) var registrations = 0
    init(live: Bool = true) {
        self.live = live
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
    }
    /// After sleep, Carbon hotkeys and event monitors can stop delivering: register again with the last arguments,
    /// whatever the preset, unless a shortcut is being recorded. Returns whether it re-registered.
    @discardableResult
    func didWake() -> Bool {
        guard let last = lastRegistration, !isSuspended else { return false }
        _ = register(preset: last.preset, customKeyCode: last.keyCode, customModifiers: last.modifiers, modeShortcuts: last.modes)
        return true
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let pasteLastReference { UnregisterEventHotKey(pasteLastReference) }
        if let hubReference { UnregisterEventHotKey(hubReference) }
        modeReferences.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    static let labels = ["⌃ ⌥ Space", "⌘ ⇧ Space", "⌃ ⇧ Space"]
    /// Releases every shortcut while one is being recorded. Wake and automatic re-registration stay off until
    /// the next explicit `register`.
    func suspend() {
        teardown()
        isSuspended = true
    }
    private func teardown() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let pasteLastReference { UnregisterEventHotKey(pasteLastReference); self.pasteLastReference = nil }
        if let hubReference { UnregisterEventHotKey(hubReference); self.hubReference = nil }
        modeReferences.values.forEach { UnregisterEventHotKey($0) }; modeReferences = [:]
        retries.forEach { $0.cancel() }; retries = []
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        doubleTap.reset()
    }
    func register(preset: Int, customKeyCode: UInt32 = 49, customModifiers: UInt32 = 6144, modeShortcuts: [ModeShortcut?] = []) -> Bool {
        teardown()
        isSuspended = false
        registrations += 1
        lastRegistration = Registration(preset: preset, keyCode: customKeyCode, modifiers: customModifiers, modes: modeShortcuts)
        guard live else { return true }
        currentPreset = preset
        carbonKeys = (preset, customKeyCode, customModifiers, modeShortcuts)
        let registered: Bool
        if preset == 4 || preset == 5 {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handleModifier(event) }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.handleModifier(event); return event }
            _ = registerCarbonKeys()
            registered = globalMonitor != nil && localMonitor != nil
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.onCancel?() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.onCancel?() }; return event
            }
            registered = registerCarbonKeys()
        }
        // A host app may still hold these keys for a moment while Mouthy launches; it lets go when it sees
        // Mouthy start. Retry whatever failed twice, then give up quietly.
        if !allCarbonKeysRegistered {
            for delay in [1.5, 4.0] {
                let retry = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.allCarbonKeysRegistered else { return }
                        let hadMain = self.mainKeyRegistered
                        if self.registerCarbonKeys(), !hadMain, self.carbonKeys.preset < 4 { self.onLateRegistration?() }
                    }
                }
                retries.append(retry)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
            }
        }
        return registered
    }
    private var mainKeyRegistered: Bool { carbonKeys.preset >= 4 || reference != nil }
    private var allCarbonKeysRegistered: Bool {
        let modes = carbonKeys.modes.indices.allSatisfy { carbonKeys.modes[$0] == nil || modeReferences[$0] != nil }
        return mainKeyRegistered && pasteLastReference != nil && hubReference != nil && modes
    }
    /// Registers each Carbon hotkey that is not registered yet. Returns whether the dictation shortcut is registered.
    private func registerCarbonKeys() -> Bool {
        guard installHandler() else { return false }
        let target = GetApplicationEventTarget()
        // Mode shortcuts use ids 100+index; a taken combination is skipped.
        for (index, shortcut) in carbonKeys.modes.enumerated() where modeReferences[index] == nil {
            guard let shortcut else { continue }
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x564F4943, id: UInt32(100 + index)),
                                   target, 0, &reference) == noErr, let reference { modeReferences[index] = reference }
        }
        // ⌃⌘V pastes the last result again; failure (e.g. taken by another app) leaves dictation unaffected.
        if pasteLastReference == nil {
            RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | cmdKey), EventHotKeyID(signature: 0x564F4943, id: 2), target, 0, &pasteLastReference)
        }
        // ⌃⌥N opens or closes the notch hub.
        if hubReference == nil {
            RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x564F4943, id: 3), target, 0, &hubReference)
        }
        let preset = carbonKeys.preset
        guard preset < 4 else { return true }
        if reference == nil {
            let modifiers = [UInt32(controlKey | optionKey), UInt32(cmdKey | shiftKey), UInt32(controlKey | shiftKey)]
            RegisterEventHotKey(preset == 3 ? carbonKeys.keyCode : UInt32(kVK_Space), preset == 3 ? carbonKeys.modifiers : modifiers[max(0, min(2, preset))],
                                EventHotKeyID(signature: 0x564F4943, id: 1), target, 0, &reference)
        }
        return reference != nil
    }
    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let time = GetEventTime(event)
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let id = identifier.id
            Task { @MainActor in
                if id == 2 { if pressed { service.onPasteLast?() }; return }
                if id == 3 { if pressed { service.onToggleHub?() }; return }
                if id >= 100 { if pressed { service.onModeShortcut?(Int(id) - 100) }; return }
                service.gestureStartedAt = time > 0 ? time : ProcessInfo.processInfo.systemUptime
                if pressed { service.onPress?() } else { service.onRelease?() }
            }
            return noErr
        }, 2, &specs, pointer, &handler)
        return status == noErr
    }
    private func handleModifier(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onCancel?() }
        if currentPreset == 5 { handleFn(event); return }
        if doubleTap.update(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue,
                            isModifierEvent: event.type == .flagsChanged, timestamp: event.timestamp) {
            gestureStartedAt = doubleTap.gestureStartedAt ?? event.timestamp
            onPress?()
        }
    }
    /// Hold Fn/🌐 to talk. Fn shortcuts (Fn+arrow, Fn+F-keys) never start recording: another key
    /// pressed while Fn is held cancels.
    private func handleFn(_ event: NSEvent) {
        if event.type == .keyDown {
            guard fnHeld else { return }
            fnOtherKey = true; fnPending?.cancel()
            if fnStarted { fnStarted = false; onCancel?() }
            return
        }
        guard event.keyCode == 63 || event.keyCode == 179 else { return }
        let down = event.modifierFlags.contains(.function)
        if down && !fnHeld {
            fnHeld = true; fnOtherKey = false
            let start = DispatchWorkItem { [weak self] in
                guard let self, self.fnHeld, !self.fnOtherKey else { return }
                self.fnStarted = true; self.onPress?()
            }
            fnPending = start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: start)
        } else if !down && fnHeld {
            fnHeld = false; fnPending?.cancel()
            if fnStarted { fnStarted = false; gestureStartedAt = event.timestamp; onRelease?() }
        }
    }
}

struct InsertionTarget {
    let pid: pid_t
    let name: String
    let bundleID: String
    let selectionRange: CFRange?
    let element: AXUIElement?
    let selectedText: String
    let secure: Bool
    var url: String? = nil
    /// Up to 300 characters around the cursor, for modes that include context.
    var nearbyText: String = ""
}

@MainActor
final class TextDelivery {
    // Seams for the headless delivery harness, which uses a background target and never takes screen focus.
    static var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    static var pasteboard = NSPasteboard.general
    /// The field, position and text of the last verified insertion, for learning corrected words.
    static var lastInsertion: (element: AXUIElement, location: Int, text: String)?
    static func value(of element: AXUIElement) -> String? { attribute(element, kAXValueAttribute) as? String }
    static var postPaste: (pid_t, UInt16) -> Void = { _, keyCode in
        // Through the HID stream: Chromium/Electron editors ignore events posted to a process.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    static var accessibilityAllowed: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused = attribute(app, kAXFocusedUIElementAttribute)
        if focused == nil {
            // Electron/Chromium apps build their accessibility tree only after this documented opt-in.
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for _ in 0..<3 where focused == nil {
                usleep(60_000)
                focused = attribute(app, kAXFocusedUIElementAttribute)
            }
        }
        guard let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }
    private static func selectionRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
    /// The page address of the browser web area containing `element`, for website-matched modes.
    static func pageURL(_ element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                if let url = attribute(node, kAXURLAttribute) { return (url as? URL)?.absoluteString ?? (url as? String) }
            }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }
    /// Presses Return in the focused app, for modes whose output is "Insert and press Return".
    static func pressReturn() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        // Marked so the dictation Return tap lets Mouthy's own Return through.
        down.setIntegerValueField(.eventSourceUserData, value: ReturnKeyTap.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: ReturnKeyTap.syntheticMarker)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    static func capture() -> InsertionTarget? {
        guard let app = frontmost(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = accessibilityAllowed ? focusedElement(pid: app.processIdentifier) : nil
        if let element, (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole {
            return InsertionTarget(pid: app.processIdentifier, name: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "", selectionRange: nil, element: nil, selectedText: "", secure: true)
        }
        let selected = element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? ""
        let url = element.flatMap(pageURL)
        let around = element.flatMap { surroundings(of: attribute($0, kAXValueAttribute) as? String, range: selectionRange($0)) }
        let nearby = around.map { String($0.before.suffix(200)) + "‸" + String($0.after.prefix(100)) } ?? ""
        return InsertionTarget(pid: app.processIdentifier, name: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "", selectionRange: element.flatMap(selectionRange), element: element, selectedText: selected, secure: false, url: url, nearbyText: nearby)
    }
    /// Pastes into whatever is focused now. `target` (captured when recording started) is only used to
    /// keep a selection rewrite from landing on a different selection.
    static func deliver(_ text: String, to target: InsertionTarget?, smartFormatting: Bool = false, replacingSelection: Bool = false, submit: Bool = false) async -> String {
        guard !text.isEmpty else { return "No text to insert." }
        guard accessibilityAllowed else { return "Ready to copy. Enable Accessibility for automatic insertion." }
        guard let app = frontmost(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "Ready to copy. No other app is focused."
        }
        let name = app.localizedName ?? "App"
        let field = focusedElement(pid: app.processIdentifier)
        if let refusal = DeliveryPolicy.refusal(role: field.flatMap { attribute($0, kAXRoleAttribute) as? String },
                                                subrole: field.flatMap { attribute($0, kAXSubroleAttribute) as? String },
                                                secureInput: IsSecureEventInputEnabled()) {
            return "Ready to copy. " + refusal
        }
        if replacingSelection {
            guard let target, target.pid == app.processIdentifier,
                  (field.flatMap { attribute($0, kAXSelectedTextAttribute) as? String } ?? "") == target.selectedText else {
                return "Ready to copy. The selection changed, so the rewrite was not applied."
            }
        }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) {
            return "Ready to copy. Control characters prevented automatic insertion."
        }
        guard let pasteKey = PasteShortcut.keyCode() else { return "Ready to copy. No paste shortcut was found for this keyboard layout." }
        guard let snapshot = clipboardSnapshot() else { return "Ready to copy. The existing clipboard could not be safely preserved." }
        let before = field.flatMap { attribute($0, kAXValueAttribute) as? String }
        let range = field.flatMap(selectionRange)
        var text = text
        if smartFormatting, !replacingSelection, let context = surroundings(of: before, range: range) {
            text = SmartInsertion.adjust(text, before: context.before, after: context.after)
        }
        let expected = expectedValue(afterInserting: text, into: before, range: range)
        guard await waitForModifierRelease() else { return "Ready to copy. Release the modifier keys to paste." }
        // Focus may have moved while modifiers were held: check again right before the keystrokes.
        guard stillFocused(pid: app.processIdentifier, field: field) else { return "Ready to copy. Focus changed before pasting." }
        guard paste(text, keyCode: pasteKey, pid: app.processIdentifier) else { return "Text copied. Paste it into your app." }
        if submit {
            // Send right away; give the app a moment to take the paste before Return.
            try? await Task.sleep(for: .milliseconds(140))
            guard stillFocused(pid: app.processIdentifier, field: field) else {
                await restoreClipboard(snapshot)
                return "Pasted into \(name). Not sent, because focus changed."
            }
            pressReturn()
            try? await Task.sleep(for: .milliseconds(200))
            await restoreClipboard(snapshot)
            return "Sent in \(name)."
        }
        // Read back as soon as the app shows the text (usually a few tens of ms). Apps that expose no text
        // get the full 400 ms so they have taken the paste before the clipboard is put back.
        var observed: String?
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(25))
            observed = field.flatMap { attribute($0, kAXValueAttribute) as? String }
            if expected != nil, observed == expected { break }
        }
        await restoreClipboard(snapshot)
        // Read-back proves insertion where the app exposes its text; many apps (terminals, games) do not.
        let verified = expected != nil && observed == expected
        lastInsertion = verified ? field.flatMap { f in range.map { (f, $0.location, text) } } : nil
        return verified ? "Inserted into \(name)." : "Pasted into \(name)."
    }
    /// The same app and field are focused, and no password field or secure input has appeared.
    private static func stillFocused(pid: pid_t, field: AXUIElement?) -> Bool {
        guard frontmost()?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return false }
        let now = focusedElement(pid: pid)
        if (now.flatMap { attribute($0, kAXSubroleAttribute) as? String }) == kAXSecureTextFieldSubrole { return false }
        switch (field, now) {
        case (nil, nil): return true
        case let (before?, now?): return CFEqual(before, now)
        default: return false
        }
    }
    static func clipboardSnapshot() -> [[(NSPasteboard.PasteboardType, Data)]]? {
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        var bytes = 0
        let limit = 16 * 1024 * 1024
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            // Types that cannot be read (file promises, lazy data) are skipped rather than blocking insertion.
            for type in item.types { if let data = item.data(forType: type) { representations.append((type, data)) } }
            // Keep text and small types first; large alternates (e.g. a TIFF copy of a screenshot) only while they fit.
            representations.sort { ($0.0 == .string ? 0 : $0.1.count) < ($1.0 == .string ? 0 : $1.1.count) }
            var kept: [(NSPasteboard.PasteboardType, Data)] = []
            for representation in representations where bytes + representation.1.count <= limit {
                kept.append(representation); bytes += representation.1.count
            }
            // An item whose readable data was all too large to keep would vanish from the clipboard: refuse instead.
            // Data that can no longer be read (its app quit) is already gone and blocks nothing.
            if !representations.isEmpty, kept.isEmpty { return nil }
            if !kept.isEmpty { snapshot.append(kept) }
        }
        return snapshot
    }
    private static var pastedChangeCount = 0
    /// Waits briefly for held shortcut modifiers to be released so ⌘V is not read as another chord; false when they
    /// are still held after a second (pasting then could run another app's command).
    static func waitForModifierRelease() async -> Bool {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for _ in 0..<20 where !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty
    }
    /// nspasteboard.org markers: clipboard managers that follow the convention skip transient items and treat
    /// auto-generated ones as not copied by the person.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    /// Callers have already confirmed the target app is frontmost.
    private static func paste(_ text: String, keyCode: UInt16, pid: pid_t) -> Bool {
        let clipboard = pasteboard
        // Marked so clipboard history apps never record the dictated words passing through.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        clipboard.clearContents(); clipboard.writeObjects([item])
        pastedChangeCount = clipboard.changeCount
        postPaste(pid, keyCode)
        return true
    }
    private static func restoreClipboard(_ snapshot: [[(NSPasteboard.PasteboardType, Data)]]) async {
        let clipboard = pasteboard
        guard clipboard.changeCount == pastedChangeCount else { return }
        clipboard.clearContents()
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            // Putting the old contents back is not a new copy: history apps should not list it again.
            if !representations.contains(where: { $0.0 == autoGeneratedType }) { item.setData(Data(), forType: autoGeneratedType) }
            return item
        }
        clipboard.writeObjects(items)
    }
    static func surroundings(of value: String?, range: CFRange?) -> (before: String, after: String)? {
        guard let value, let range, range.location >= 0, range.length >= 0 else { return nil }
        let source = value as NSString
        guard range.location + range.length <= source.length else { return nil }
        let start = max(0, range.location - 200)
        let end = min(source.length, range.location + range.length + 200)
        return (source.substring(with: NSRange(location: start, length: range.location - start)),
                source.substring(with: NSRange(location: range.location + range.length, length: end - range.location - range.length)))
    }
    static func expectedValue(afterInserting text: String, into value: String?, range: CFRange?) -> String? {
        guard let value, let range, range.location >= 0, range.length >= 0 else { return nil }
        let source = value as NSString
        guard range.location <= source.length, range.length <= source.length - range.location else { return nil }
        return source.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
