// Headless insertion target for DeliveryTests: an accessory app whose text view lives in an
// off-screen window. It never activates or takes screen focus. A distributed notification
// stands in for the ⌘V keystroke and pastes from the private test pasteboard.
import AppKit

let pasteboardName = NSPasteboard.Name("dev.mouthy.Mouthy.delivery-test")
/// Never on screen: AppKit pulls a titled window back onto a display when it is shown (it kept popping
/// up), so this one is borderless, refuses to be moved onto a screen, and is fully transparent.
final class HiddenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

final class Target: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = HiddenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = text
        // Record exactly what Mouthy pastes: no smart quotes, dashes, replacements or corrections of the field's own.
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(text)
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.mouthy.Mouthy.delivery-test.paste"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let value = NSPasteboard(name: pasteboardName).string(forType: .string) else { return }
            self.text.insertText(value, replacementRange: self.text.selectedRange())
        }
        print("ready"); fflush(stdout)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Target()
app.delegate = delegate
app.run()
