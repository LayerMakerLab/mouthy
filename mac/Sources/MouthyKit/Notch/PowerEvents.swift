import Foundation
import IOKit.ps
import MouthyNotch
import SwiftUI

/// Shows "Charging · 82%" in the notch when power is plugged in or removed, and warns once at 10%.
/// Driven by IOKit's power-source notification; nothing is checked on a timer.
@MainActor final class PowerEvents {
    static let shared = PowerEvents()
    private var source: CFRunLoopSource?
    private var lastOnPower: Bool?
    private var warnedLow = false

    func start() {
        guard source == nil else { return }
        lastOnPower = Self.read()?.onPower
        guard let created = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerEvents.shared.changed() }
        }, nil)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func changed() {
        guard let state = Self.read() else { return }
        defer { lastOnPower = state.onPower }
        if let lastOnPower, lastOnPower != state.onPower {
            let ears = Self.ears(onPower: state.onPower, percent: state.percent)
            NotchHub.shared.peek(AnyView(PowerPeek(charging: state.onPower, percent: state.percent)), seconds: 3,
                                 leading: ears.leading, trailing: ears.trailing, title: state.onPower ? "Charging" : "On battery")
        }
        if !state.onPower, state.percent <= 10, !warnedLow {
            warnedLow = true
            NotchHub.shared.presentResult("Battery low · \(state.percent)%", ok: false)
        }
        if state.onPower || state.percent > 15 { warnedLow = false }
    }

    /// Nil on Macs without a battery.
    /// The band beside the camera when power changes: bolt or battery, then the percentage.
    static func ears(onPower: Bool, percent: Int) -> (leading: AnyView, trailing: AnyView) {
        (AnyView(Image(systemName: onPower ? "bolt.fill" : "battery.75percent")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)),
         AnyView(Text("\(percent)%")))
    }

    static func read() -> (onPower: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (onPower, current * 100 / maximum)
        }
        return nil
    }
}

/// The standard peek: a small battery filling to its level (mic glow while charging), the state and the percentage.
struct PowerPeek: View {
    let charging: Bool
    let percent: Int
    var body: some View {
        NotchPeekRow(title: charging ? "Charging" : "On battery", value: "\(percent)%") {
            BatteryGlyph(charging: charging, percent: percent)
        }
    }
}

/// A 24 pt battery outline whose fill grows to the level once on appear.
struct BatteryGlyph: View {
    let charging: Bool
    let percent: Int
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let low = !charging && percent <= 20
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(MouthyTheme.cream.opacity(0.55), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(low ? AnyShapeStyle(MouthyTheme.ember) : charging ? AnyShapeStyle(barGradient) : AnyShapeStyle(MouthyTheme.cream))
                    .frame(width: max(2, 16 * CGFloat(filled ? min(max(percent, 0), 100) : 0) / 100))
                    .padding(2.5)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 7.5, weight: .black)).foregroundStyle(MouthyTheme.night)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 21, height: 12)
            Capsule(style: .circular).fill(MouthyTheme.cream.opacity(0.55)).frame(width: 1.5, height: 5)
        }
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { filled = true } }
        .accessibilityHidden(true)
    }
}
