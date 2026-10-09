import Foundation
import SwiftUI
import Testing
import MouthyCore
import MouthyKit
import MouthyNotch

/// Compiles against every API host apps use, through plain (non-testable) imports, so a revamp that breaks
/// source compatibility fails here instead of in host apps.
@MainActor final class APIProbeTab: NotchTab {
    let id = "test.api-probe"
    let title = "Probe"
    let symbolName = "star"
    var badge: NotchBadge? { NotchBadge(count: 1, tone: .attention, tint: NotchPalette.ember) }
    func makeBody() -> AnyView { AnyView(EqualizerBars(playing: false, tint: NotchPalette.shine).smokedGlass(Capsule())) }
}

@MainActor @Test func publicAPIStaysSourceCompatibleForHosts() {
    // NotchDictation: the original initializer shape still compiles; the prompt is optional.
    let state = NotchDictation(target: "Atlas", level: 0.5, partialText: "hello", transcribing: false)
    #expect(state.prompt == nil)
    #expect(NotchDictation(target: "Atlas", prompt: "Which branch?").prompt == "Which branch?")
    let _: NotchBadge.Tone = .neutral

    // NotchHub surface.
    let hub = NotchHub.shared
    let probe = APIProbeTab()
    hub.register(probe)
    hub.tabDidChange(id: probe.id)
    _ = hub.isOpen
    _ = hub.isRunning
    let present: (NotchDictation) -> Void = hub.presentDictation(_:)
    let presentSession: (DictationSession, String) -> Void = hub.presentDictation(session:target:)
    let end: () -> Void = hub.endDictation
    let result: (String, Bool) -> Void = hub.presentResult(_:ok:)
    let openFromHost: (Bool) -> Void = hub.setOpenFromHost(_:)
    _ = (present, presentSession, end, result, openFromHost)
    hub.unregister(id: probe.id)

    // NotchPalette names.
    _ = [NotchPalette.shine, NotchPalette.silver, NotchPalette.graphite, NotchPalette.ember]
    _ = [NotchPalette.metal, NotchPalette.sheen]

    // MouthyTabs.
    let all: () -> [any NotchTab] = MouthyTabs.all
    let attach: (NotchHub, [String]) -> Void = MouthyTabs.attach(to:leading:)
    let detach: (NotchHub) -> Void = MouthyTabs.detach(from:)
    _ = (all, attach, detach, MouthyTabs.storageFolder)

    // DictationSession and SpeechModels.
    let session = DictationSession(configuration: DictationConfiguration(engine: .parakeet, locale: "en-US"))
    _ = session.phase; _ = session.partialText; _ = session.level; _ = session.isRunning
    let start: () async throws -> Void = session.start
    let stop: () async -> String? = session.stop
    _ = (start, stop)
    _ = SpeechModels.isInstalled(.parakeet)
    let download: (URL?, @escaping @Sendable (String) -> Void) async throws -> Void = SpeechModels.downloadParakeet(modelDirectory:progress:)
    let transcribe: (URL, DictationConfiguration) async throws -> String = SpeechModels.transcribe(fileAt:configuration:)
    _ = (download, transcribe)

    // New public design types carry Mouthy/Mascot prefixes.
    _ = MouthyTheme.orange; _ = MouthyType.title; _ = MouthyMotion.page
    _ = MouthyWaveform(level: 0, active: false)
    _ = MascotGlyph(pose: .listen, size: 20)
    _ = MascotPose.allCases
}
