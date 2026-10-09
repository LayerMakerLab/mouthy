import Foundation
import AVFoundation

struct MediaInput {
    let url: URL
    private let temporary: Bool
    func removeTemporary() { if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
    static func containsSignal(_ url: URL) async throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { throw MouthyFailure("Audio buffer allocation failed.") }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let value = channels[channel][index]
                    if !value.isFinite { throw MouthyFailure("Audio contains invalid samples.") }
                    if abs(value) > 0.0001 { return true }
                }
            }
        }
        return false
    }
    static func prepare(_ url: URL) async throws -> MediaInput {
        if (try? AVAudioFile(forReading: url)) != nil { return MediaInput(url: url, temporary: false) }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw MouthyFailure("This file has no readable audio track.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Mouthy-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent("audio.m4a")
        do {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw MouthyFailure("This media format cannot be imported.") }
            try await exporter.export(to: destination, as: .m4a)
            try Task.checkCancellation()
            return MediaInput(url: destination, temporary: true)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
