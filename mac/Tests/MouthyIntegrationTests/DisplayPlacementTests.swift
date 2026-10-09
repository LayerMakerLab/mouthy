import Testing
import AppKit
import AVFoundation
import MouthyCore
@testable import MouthyKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_ROUTING"] == "1"))
@MainActor func externalMicrophoneSurvivesUnrelatedDisplayNotification() async throws {
    try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    let device = try #require(AudioDevices.defaultInput())
    try #require(!AudioDevices.isBuiltIn(device))
    let service = SpeechService()
    let provider = SpeechEngine(rawValue: ProcessInfo.processInfo.environment["MOUTHY_TEST_ROUTING_ENGINE"] ?? "apple") ?? .apple
    var frames = 0
    var failures = 0
    service.onWaveform = { _ in frames += 1 }
    service.onFailure = { _ in failures += 1 }
    do {
        try await service.start(locale: "en-US", vocabulary: "", inputDeviceUID: device.id, provider: provider, status: { _ in })
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(service.inputDeviceName == device.name)
        #expect(service.isActive && frames > 0 && failures == 0)
        print("External routing capture: engine=\(provider.rawValue), frames=\(frames), failures=\(failures)")
    } catch { await service.cancel(); throw error }
    await service.cancel()
    #expect(!service.isActive)
    let failuresAfterCancel = failures
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(failures == failuresAfterCancel)

    // Model the stopped-engine state produced by an output-only configuration
    // change, without mutating the user's system playback device during tests.
    let engine = AVAudioEngine()
    let selected = try AudioDevices.select(device.id, engine: engine)
    let format = engine.inputNode.inputFormat(forBus: 0)
    var resumedFrames = 0
    try AudioCompat.installTap(on: engine.inputNode, bufferSize: 1_024, format: format) { _, _ in
        Task { @MainActor in resumedFrames += 1 }
    }
    defer { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
    try engine.start()
    engine.stop()
    let otherFormat = try #require(AVAudioFormat(commonFormat: format.commonFormat,
                                               sampleRate: format.sampleRate == 48_000 ? 44_100 : 48_000,
                                               channels: format.channelCount, interleaved: format.isInterleaved))
    #expect(!AudioDevices.resumeUnchangedInput(selected, format: otherFormat, engine: engine))
    #expect(!engine.isRunning)
    let missing = InputDevice(id: "mouthy-test-disconnected-input", name: "Disconnected test input", objectID: 0)
    #expect(!AudioDevices.resumeUnchangedInput(missing, format: format, engine: engine))
    #expect(!engine.isRunning)
    #expect(AudioDevices.resumeUnchangedInput(selected, format: format, engine: engine))
    try await Task.sleep(for: .milliseconds(300))
    let firstFrames = resumedFrames
    #expect(firstFrames > 0)
    #expect(AudioDevices.resumeUnchangedInput(selected, format: format, engine: engine))
    try await Task.sleep(for: .milliseconds(300))
    #expect(resumedFrames > firstFrames)
    print("External routing restart: engine=\(provider.rawValue), callbacksResumed=\(resumedFrames > firstFrames), invalidRoutesRejected=true")
}

@Test(.enabled(if: AudioDevices.lidClosed))
@MainActor func closedLidRejectsBuiltInMicrophoneBeforeCapture() throws {
    let builtIn = try #require(AudioDevices.inputs().first(where: AudioDevices.isBuiltIn))
    let engine = AVAudioEngine()
    #expect(throws: MouthyFailure.self) { try AudioDevices.select(builtIn.id, engine: engine) }
    #expect(!engine.isRunning)
}

@Test func islandSitsInTheMenuBarCenterOfExternalDisplays() {
    for screen in [NSRect(x: 0, y: 0, width: 2560, height: 1440),
                   NSRect(x: -1440, y: -600, width: 1440, height: 2560),
                   NSRect(x: 2560, y: -300, width: 1080, height: 1920)] {
        let visible = NSRect(x: screen.minX, y: screen.minY + 60, width: screen.width, height: screen.height - 90)
        let island = RecordingPlacement.island(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, notchHeight: 0)
        #expect(screen.contains(island.panel))
        #expect(island.panel.maxY == screen.maxY)
        #expect(abs(island.panel.midX - screen.midX) < 0.5)
        #expect(island.height == 30 && island.notchWidth == 0)
    }
}

@Test func islandGrowsOutOfThePhysicalNotch() {
    let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let island = RecordingPlacement.island(screen: screen, visible: NSRect(x: 0, y: 0, width: 1512, height: 950), notchLeft: 662, notchRight: 850, notchHeight: 32)
    #expect(screen.contains(island.panel))
    #expect(island.panel.maxY == screen.maxY)
    #expect(abs(island.panel.midX - 756) < 0.5)
    #expect(island.height == 32 && island.notchWidth == 188 && island.restingWidth > 188)
}

@Test func islandSitsInABottomCornerOnDisplaysWithoutANotch() {
    let screen = NSRect(x: 1512, y: 0, width: 2560, height: 1440), visible = NSRect(x: 1512, y: 70, width: 2560, height: 1345)
    let right = RecordingPlacement.island(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, notchHeight: 0, corner: .bottomRight)
    #expect(right.floating && right.panel.maxX <= visible.maxX && right.panel.maxX > visible.maxX - 60 && right.panel.minY < visible.minY + 30)
    let left = RecordingPlacement.island(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, notchHeight: 0, corner: .bottomLeft)
    #expect(left.floating && left.panel.minX >= visible.minX && left.panel.minX < visible.minX + 40)
    // The notch display ignores the corner and stays on the notch.
    let notched = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 950),
                                            notchLeft: 662, notchRight: 850, notchHeight: 32, corner: .bottomRight)
    #expect(!notched.floating && notched.notchWidth > 0)
}
