import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

@Test func modelDiskSizeCountsPackagesAndSkipsSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Encoder.mlmodelc")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 123).write(to: package.appendingPathComponent("weights.bin"))
    try Data(repeating: 0, count: 17).write(to: root.appendingPathComponent("tokens.json"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: package)
    #expect(ModelDownloadSize.diskBytes(in: root) == 140)
    #expect(ModelDownloadSize.diskBytes(in: root.appendingPathComponent("missing")) == 0)
    #expect(ModelDownloadSize.diskBytes(in: root.appendingPathComponent("linked")) == nil)
}

@Test func modelRowsDistinguishIncompleteUnsupportedAndInstalled() {
    let missing = SpeechModelCatalog.row(.whisper(.small), ready: false, bytes: 0, supported: true, intel: false)
    #expect(missing.canDownload && !missing.canRemove && missing.status == "Not downloaded")
    let partial = SpeechModelCatalog.row(.whisper(.small), ready: false, bytes: 100, supported: true, intel: false)
    #expect(partial.canDownload && partial.canRemove && partial.status == "Incomplete download")
    #expect(partial.size.contains("on disk"))
    let ready = SpeechModelCatalog.row(.parakeet, ready: true, bytes: nil, supported: true, intel: true)
    #expect(!ready.canDownload && ready.canRemove && ready.installed)
    #expect(ready.size.contains("Disk size unavailable"))
    let intel = SpeechModelCatalog.row(.whisper(.medium), ready: false, bytes: 0, supported: false, intel: true)
    #expect(!intel.canDownload && intel.status == "Needs Apple silicon")
    #expect(ModelDownloadSize.download(.parakeet, intel: false).hasPrefix("About"))
    #expect(!ModelDownloadSize.download(.parakeet, intel: true).hasPrefix("About"))
    #expect(SpeechModelID.all.count == 2 + WhisperModel.allCases.count)
}

@MainActor @Test func modelActionsRespectBusyAndLocalOnlyWithoutChangingSelection() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: LocalStore(directory: root), enablesHotkey: false)
    model.preferences.speechEngine = .apple
    model.preferences.whisperModel = .baseEnglish
    model.preferences.localOnly = true
    for id in SpeechModelID.all { model.installModel(id) }
    #expect(!model.setupBusy && model.status.contains("Network use is blocked"))
    model.preferences.localOnly = false
    model.phase = .listening
    for id in SpeechModelID.all { model.installModel(id); model.removeModel(id) }
    #expect(!model.setupBusy)
    #expect(model.preferences.speechEngine == .apple && model.preferences.whisperModel == .baseEnglish)
}
