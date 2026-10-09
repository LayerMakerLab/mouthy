import AppKit
import CoreAudio
import AudioToolbox
import MouthyCore

/// Quiets other audio while dictating and restores exactly what it changed.
/// Mute uses the default output device; pause sends the system play/pause key only when another
/// process is actually producing output, and resumes only if nothing started playing meanwhile.
@MainActor
final class MediaControl {
    private enum Change { case muted(AudioDeviceID), lowered(AudioDeviceID, Float32), paused }
    private var change: Change?

    func engage(_ mode: MediaWhileDictating) {
        guard change == nil else { return }
        switch mode {
        case .nothing: return
        case .mute:
            guard let device = Self.defaultOutput() else { return }
            if Self.mute(device) == false, Self.setMute(device, true) {
                change = .muted(device)
            } else if Self.mute(device) == nil, let volume = Self.volume(device), volume > 0, Self.setVolume(device, 0) {
                change = .lowered(device, volume)
            }
        case .pause:
            guard Self.otherProcessIsPlaying() else { return }
            Self.sendPlayPause()
            change = .paused
        }
    }

    func release() {
        guard let change else { return }
        self.change = nil
        switch change {
        case .muted(let device):
            // Leave it alone if the person changed it while dictating.
            if Self.mute(device) == true { _ = Self.setMute(device, false) }
        case .lowered(let device, let volume):
            if let current = Self.volume(device), current == 0 { _ = Self.setVolume(device, volume) }
        case .paused:
            if !Self.otherProcessIsPlaying() { Self.sendPlayPause() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func defaultOutput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }
    static func mute(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    static func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
    static func volume(_ device: AudioDeviceID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func setVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = volume
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
    /// True when any process other than Mouthy is currently running audio output.
    static func otherProcessIsPlaying() -> Bool {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.contains { process in
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            var pid = pid_t(0); var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != ownPID else { return false }
            var runningAddress = Self.address(kAudioProcessPropertyIsRunningOutput)
            var running = UInt32(0); var runningSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
        }
    }
    static func sendPlayPause() {
        let playKey = 16 // NX_KEYTYPE_PLAY
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (playKey << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
