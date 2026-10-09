import SwiftUI
import AppKit
import Carbon
import MouthyNotch

struct ShortcutCapture: NSViewRepresentable {
    var completed: (UInt32?, UInt32?, String?) -> Void
    /// Live modifier glyphs while keys are held, for the recorder's keycaps. Display only.
    var modifiersChanged: ((String) -> Void)? = nil
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.completed = completed; view.modifiersChanged = modifiersChanged
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: CaptureView, context: Context) { nsView.completed = completed; nsView.modifiersChanged = modifiersChanged }
    final class CaptureView: NSView {
        var completed: ((UInt32?, UInt32?, String?) -> Void)?
        var modifiersChanged: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
        override func flagsChanged(with event: NSEvent) {
            modifiersChanged?(ShortcutCapture.glyphs(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { completed?(nil, nil, nil); return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
            var modifiers: UInt32 = 0
            var label = ""
            if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃ " }
            if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥ " }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧ " }
            if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘ " }
            let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            completed?(UInt32(event.keyCode), modifiers, label)
        }
    }

    /// "⌃ ⌥ ⇧ ⌘" in the same order the saved label uses.
    static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined(separator: " ")
    }
}

/// The custom-shortcut recorder: the saved shortcut as keycaps; click it and it listens, showing the
/// modifiers as you hold them, with a glow ring until a key lands or Escape cancels.
struct ShortcutRecorder: View {
    let label: String
    @Binding var recording: Bool
    var begin: () -> Void
    var end: (UInt32?, UInt32?, String?) -> Void
    @State private var held = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if recording { finish(nil, nil, nil) } else { held = ""; recording = true; begin() }
        } label: {
            HStack(spacing: 8) {
                if recording {
                    if held.isEmpty {
                        Text("Press keys…")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MouthyTheme.glow)
                            .transition(.opacity)
                    } else {
                        KeycapRow(shortcut: held).transition(.opacity)
                    }
                } else {
                    KeycapRow(shortcut: label)
                    Image(systemName: "record.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(MouthyTheme.cream2)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Capsule(style: .circular).fill(MouthyTheme.raised))
            .overlay(Capsule(style: .circular).strokeBorder(recording ? MouthyTheme.glow : MouthyTheme.hoof, lineWidth: recording ? 1.5 : 1))
            .shadow(color: MouthyTheme.glow.opacity(recording ? 0.35 : 0), radius: 8)
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .background {
            if recording {
                ShortcutCapture(completed: { finish($0, $1, $2) }, modifiersChanged: { held = $0 })
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: recording)
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: held)
        .help(recording ? "Press the new shortcut, or Escape to cancel" : "Record a custom shortcut")
        .accessibilityLabel(recording ? "Recording shortcut. Press keys, or Escape to cancel." : "Custom shortcut \(label). Click to record a new one.")
    }

    private func finish(_ key: UInt32?, _ modifiers: UInt32?, _ newLabel: String?) {
        recording = false; held = ""
        end(key, modifiers, newLabel)
    }
}
