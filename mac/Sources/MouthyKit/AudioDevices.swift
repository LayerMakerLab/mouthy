import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import IOKit

struct InputDevice: Identifiable {
    let id: String
    let name: String
    let objectID: AudioDeviceID
    /// Recording through the engine's own default device (the system input), not a device Mouthy set.
    var followsDefault = false
}

enum AudioDevices {
    static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
    static func isBuiltIn(_ device: InputDevice) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &transport) == noErr && transport == kAudioDeviceTransportTypeBuiltIn
    }
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, name: name, objectID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
    static func defaultInput() -> InputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return inputs().first { $0.objectID == device }
    }
    /// Configuration notifications can arrive after startup or an output-only change.
    /// An output change may stop an otherwise valid input-only engine. Restart once
    /// only when the selected input and installed tap format are still identical.
    static func resumeUnchangedInput(_ selected: InputDevice, format: AVAudioFormat, engine: AVAudioEngine) -> Bool {
        guard inputIsUnchanged(selected, format: format, engine: engine) else { return false }
        if !engine.isRunning {
            do { try engine.start() }
            catch { return false }
        }
        return engine.isRunning && inputIsUnchanged(selected, format: format, engine: engine)
    }
    static func inputIsUnchanged(_ selected: InputDevice, format: AVAudioFormat, engine: AVAudioEngine) -> Bool {
        guard !(lidClosed && isBuiltIn(selected)),
              inputs().contains(where: { $0.id == selected.id && $0.objectID == selected.objectID }),
              engine.inputNode.inputFormat(forBus: 0).isEqual(format) else { return false }
        // Following the system input: the engine records through its own device, so check that the input it follows is
        // still this microphone.
        if selected.followsDefault { return defaultInput()?.objectID == selected.objectID }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var matches = false
        AudioCompat.withAudioUnit(engine.inputNode) { unit in
            guard let unit else { return }
            matches = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr && current == selected.objectID
        }
        return matches
    }
    /// AVAudioEngine can stop itself right after starting on a microphone Mouthy chose, and only says so about 120 ms
    /// later. Watching for that for the first 0.6 s and restarting at once keeps the first words.
    @MainActor static func restartIfStopped(_ engine: AVAudioEngine, selected: InputDevice, format: AVAudioFormat, isCurrent: @escaping @MainActor () -> Bool) {
        guard !selected.followsDefault else { return }
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(10))
                guard isCurrent() else { return }
                guard !engine.isRunning else { continue }
                let resumed = resumeUnchangedInput(selected, format: format, engine: engine)
                Diagnostics.dictation.notice("engine stopped itself after starting: \(resumed ? "restarted at once" : "input changed", privacy: .public)")
                return
            }
        }
    }

    @discardableResult
    static func select(_ uid: String, engine: AVAudioEngine) throws -> InputDevice {
        guard let selected = uid.isEmpty ? defaultInput() : inputs().first(where: { $0.id == uid }) else {
            throw MouthyFailure("The selected microphone is disconnected. Choose another input in Settings.")
        }
        guard !(lidClosed && isBuiltIn(selected)) else {
            throw MouthyFailure("The MacBook lid is closed. Choose an external microphone in Settings, or open the lid.")
        }
        // The system input needs no switch. Switching the engine's device, even to the same microphone, makes it stop
        // itself right after starting ("iounit configuration changed") and lose the first 0.1-0.3 s of speech.
        if selected.objectID == defaultInput()?.objectID {
            var following = selected
            following.followsDefault = true
            return following
        }
        var device = selected.objectID
        try AudioCompat.withAudioUnit(engine.inputNode) { unit in
            guard let unit else { throw MouthyFailure("The microphone audio unit is unavailable.") }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw MouthyFailure("The microphone could not be selected (\(status)).") }
        }
        return selected
    }
}
