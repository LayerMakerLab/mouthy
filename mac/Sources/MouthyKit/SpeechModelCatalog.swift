import Foundation
import FluidAudio
import Speech
import MouthyCore

enum SpeechModelID: Hashable, Sendable {
    case apple, parakeet, whisper(WhisperModel)

    static var all: [Self] { [.apple, .parakeet] + WhisperModel.allCases.map { .whisper($0) } }
    var title: String {
        switch self {
        case .apple: "Apple speech"
        case .parakeet: "Parakeet v3"
        case .whisper(.baseEnglish): "Whisper Base English"
        case .whisper(.small): "Whisper Small"
        case .whisper(.medium): "Whisper Medium"
        case .whisper(.turbo): "Whisper Large v3 Turbo"
        }
    }
}

struct SpeechModelRow: Identifiable, Sendable {
    let id: SpeechModelID
    var status: String
    var size: String
    var installed = false
    var canDownload = true
    var canRemove = false
}

/// Download byte counts from publisher file metadata at immutable revisions (2026-10-06).
/// FluidAudio and WhisperKit download their current upstream revision, so those pre-download totals
/// are estimates, labelled "About". They include tokenizers and Parakeet's vocabulary boosting model.
/// Intel's archive is SHA-256 pinned in SherpaParakeet, so its transfer size is known exactly.
/// No metadata requests run in Settings. See docs/models.md for the file selection and sources.
enum ModelDownloadSize {
    static let parakeetCoreML: Int64 = 483_257_242 + 102_803_869
    static let parakeetIntel: Int64 = 487_170_055
    static func whisper(_ model: WhisperModel) -> Int64 {
        switch model {
        case .baseEnglish: 149_114_215
        case .small: 220_113_912
        case .medium: 1_532_417_382
        case .turbo: 629_481_698
        }
    }
    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    static func download(_ id: SpeechModelID, intel: Bool) -> String {
        switch id {
        case .apple: "Size managed by macOS"
        case .parakeet where intel: "\(formatted(parakeetIntel)) download"
        case .parakeet: "About \(formatted(parakeetCoreML)) download"
        case let .whisper(model): "About \(formatted(whisper(model))) download"
        }
    }

    /// Logical bytes of regular files, including compiled-model package contents. No symlink traversal;
    /// unknown/unreadable sizes stay unknown rather than presenting a partial sum as a complete size.
    static func diskBytes(in folder: URL) -> Int64? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        guard let root = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]), root.isSymbolicLink == false else { return nil }
        var failed = false
        guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                          errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var total: Int64 = 0
        for case let file as URL in entries {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return nil }
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            if values.isRegularFile == true {
                guard let size = values.fileSize else { return nil }
                total += Int64(size)
            }
        }
        return failed ? nil : total
    }
}

enum SpeechModelCatalog {
    /// What the Parakeet row adds after its status, in plain words.
    static func parakeetDetail(intel: Bool) -> String { intel ? " · Built for Intel Macs" : " · With your vocabulary" }

    static func localRows() -> [SpeechModelRow] {
        let intel = SherpaParakeet.preferred
        let folders = intel ? [SherpaParakeet.folder] : ParakeetRecognizer.downloadFolders
        let sizes = folders.map { ModelDownloadSize.diskBytes(in: $0) }
        let bytes = sizes.allSatisfy { $0 != nil } ? sizes.compactMap { $0 }.reduce(0, +) : nil
        let ready = ParakeetRecognizer.installed
        let hostOwned = !intel && ParakeetRecognizer.modelDirectory != nil
        var parakeet = row(.parakeet, ready: ready, bytes: bytes, supported: true, intel: intel)
        parakeet.status += parakeetDetail(intel: intel)
        if ready && !intel && !ParakeetRecognizer.boostingInstalled {
            parakeet.status = "Installed · Vocabulary download missing"
            parakeet.canDownload = true
        }
        if hostOwned { parakeet.status = "Managed by host app"; parakeet.canRemove = false; parakeet.canDownload = false }
        return [parakeet] + WhisperModel.allCases.map { model in
            row(.whisper(model), ready: WhisperRecognizer.installed(model),
                bytes: ModelDownloadSize.diskBytes(in: WhisperRecognizer.folder(model)), supported: WhisperRecognizer.supported, intel: intel)
        }
    }

    static func row(_ id: SpeechModelID, ready: Bool, bytes: Int64?, supported: Bool, intel: Bool) -> SpeechModelRow {
        let partial = !ready && (bytes ?? 0) > 0
        let disk = bytes.map { " · \(ModelDownloadSize.formatted($0)) on disk" } ?? " · Disk size unavailable"
        return SpeechModelRow(id: id, status: !supported ? "Needs Apple silicon" : ready ? "Installed" : partial ? "Incomplete download" : "Not downloaded",
                              size: ModelDownloadSize.download(id, intel: intel) + (ready || partial ? disk : ""),
                              installed: ready, canDownload: supported && !ready, canRemove: ready || partial)
    }

    static func appleRow(locale: String) async -> SpeechModelRow {
        var row = SpeechModelRow(id: .apple, status: "Unavailable for this Mac or language", size: "Size managed by macOS", canDownload: false)
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { return row }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        row.installed = status == .installed
        row.canDownload = status == .supported
        row.canRemove = await reservation(for: supported) != nil
        row.status = switch status {
        case .installed: "Installed"
        case .downloading: "Downloading…"
        case .supported: "Not downloaded"
        case .unsupported: "Unavailable for this language"
        @unknown default: "Unknown status"
        }
        row.status += " · \(supported.localizedString(forIdentifier: supported.identifier) ?? supported.identifier)"
        return row
    }

    private static func reservation(for supported: Locale) async -> Locale? {
        // AssetInventory may reserve a locale variant instead of the exact requested identifier.
        for locale in await AssetInventory.reservedLocales {
            if await SpeechTranscriber.supportedLocale(equivalentTo: locale) == supported { return locale }
        }
        return nil
    }

    static func releaseApple(locale: String) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)),
              let reserved = await reservation(for: supported),
              await AssetInventory.release(reservedLocale: reserved) else {
            throw MouthyFailure("No Apple speech reservation to release. macOS manages these shared files.")
        }
    }
}
