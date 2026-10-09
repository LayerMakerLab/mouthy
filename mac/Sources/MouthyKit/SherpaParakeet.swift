import CryptoKit
import CSherpaOnnx
import Foundation
import MouthyCore

/// NVIDIA Parakeet v3 through sherpa-onnx (ONNX Runtime on the CPU) for Intel Macs. They have no Neural Engine,
/// so Core ML runs Parakeet about 2.5 s per sentence there (2019 MacBook Pro, i7-9750H); sherpa-onnx runs the
/// same model, same accuracy, in about 0.3 s. The runtime ships inside Mouthy.app (Contents/Frameworks/
/// sherpa-onnx, Intel only) and the model is the archive the Windows and Linux apps use, pinned by SHA-256.
enum SherpaParakeet {
    static let name = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    static let archiveSHA256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
    static let archive = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(name).tar.bz2")!
    static let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
    static var folder: URL { LocalStore.supportDirectory.appendingPathComponent("Models/sherpa-onnx/\(name)", isDirectory: true) }

    /// The bundled runtime, when this build carries it.
    static var library: URL? {
        let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("sherpa-onnx/libsherpa-onnx-c-api.dylib")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Intel Macs with the bundled runtime use sherpa-onnx; everything else keeps Core ML.
    static var preferred: Bool {
        #if arch(x86_64)
        return library != nil && ProcessInfo.processInfo.environment["MOUTHY_PARAKEET_BACKEND"] != "coreml"
        #else
        return false
        #endif
    }

    static var installed: Bool {
        files.allSatisfy { file in
            let path = folder.appendingPathComponent(file).path
            return (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
        }
    }

    /// Downloads the model archive, checks its SHA-256 and unpacks it as plain files.
    static func download(progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Downloading Parakeet to this Mac…")
        let (temporary, response) = try await URLSession.shared.download(from: archive)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MouthyFailure("The Parakeet download failed. Try again later.") }
        progress("Checking the download…")
        guard try sha256(of: temporary) == archiveSHA256 else { throw MouthyFailure("The Parakeet download did not match its checksum, so it was not used.") }
        progress("Unpacking Parakeet…")
        let parent = folder.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // bsdtar refuses absolute paths and ".." by default; only the expected regular files are kept below.
        tar.arguments = ["-xjf", temporary.path, "-C", staging.path, "--no-same-owner", "--no-same-permissions"]
        try tar.run(); tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw MouthyFailure("Parakeet could not be unpacked.") }
        let unpacked = staging.appendingPathComponent(name, isDirectory: true)
        let target = staging.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files {
            let source = unpacked.appendingPathComponent(file)
            guard (try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw MouthyFailure("The Parakeet download is missing \(file).")
            }
            try FileManager.default.moveItem(at: source, to: target.appendingPathComponent(file))
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: target, to: folder)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    }
}

/// One loaded sherpa-onnx recognizer. Owned by `ParakeetRecognizer`, which calls it one request at a time.
final class SherpaRecognizer: @unchecked Sendable {
    private let pointer: OpaquePointer

    init() throws {
        guard let library = SherpaParakeet.library, mouthy_sherpa_load(library.path) == 1 else {
            throw MouthyFailure("This copy of Mouthy is missing its Intel speech runtime. Reinstall Mouthy.")
        }
        guard SherpaParakeet.installed else { throw MouthyFailure("Download Parakeet in Settings before using it offline.") }
        let folder = SherpaParakeet.folder
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ value: String) -> UnsafePointer<CChar> { let copy = strdup(value)!; strings.append(copy); return UnsafePointer(copy) }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(folder.appendingPathComponent("encoder.int8.onnx").path)
        config.model_config.transducer.decoder = c(folder.appendingPathComponent("decoder.int8.onnx").path)
        config.model_config.transducer.joiner = c(folder.appendingPathComponent("joiner.int8.onnx").path)
        config.model_config.tokens = c(folder.appendingPathComponent("tokens.txt").path)
        // Four threads measured fastest on a 6-core Intel MacBook Pro; more only adds contention.
        config.model_config.num_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        config.model_config.provider = c("cpu")
        config.model_config.model_type = c("nemo_transducer")
        config.decoding_method = c("greedy_search")
        guard let created = mouthy_sherpa_create_recognizer(&config) else { throw MouthyFailure("Parakeet could not load on this Mac.") }
        pointer = created
    }

    deinit { mouthy_sherpa_destroy_recognizer(pointer) }

    func transcribe(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        guard let text = samples.withUnsafeBufferPointer({ mouthy_sherpa_decode(pointer, $0.baseAddress, Int32($0.count)) }) else { return "" }
        defer { free(text) }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recognizes `samples` but returns only the words that begin at or after sample `start` (the audio before it is
    /// context): "" when no word begins there, nil when the result has no token times.
    func transcribe(_ samples: [Float], wordsFrom start: Int) -> String? {
        var found: Int32 = 0
        let text = samples.withUnsafeBufferPointer {
            mouthy_sherpa_decode_from(pointer, $0.baseAddress, Int32($0.count), Float(start) / 16_000, &found)
        }
        defer { free(text) }
        guard found != 0, let text else { return nil }
        return String(cString: text).replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
