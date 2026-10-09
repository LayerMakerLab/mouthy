import AppKit
import AVFoundation
import ScreenCaptureKit
import MouthyCore

/// Writes bounded PCM blocks on a serial capture queue. No screen pixels are requested or saved.
final class MeetingAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var files: [SCStreamOutputType: AVAudioFile] = [:]
    private var converters: [SCStreamOutputType: AVAudioConverter] = [:]
    private var origin: Double?
    private let folder: URL
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let onFailure: @Sendable (String) -> Void
    let onWaveform: @Sendable (MicrophoneFrame) -> Void
    private var meterFrames = 0
    init(folder: URL, onFailure: @escaping @Sendable (String) -> Void, onWaveform: @escaping @Sendable (MicrophoneFrame) -> Void) {
        self.folder = folder; self.onFailure = onFailure; self.onWaveform = onWaveform
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let inputFormat = AVAudioFormat(streamDescription: streamDescription) else { throw MouthyFailure("Meeting audio format is unreadable.") }
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            guard count > 0, count < 192_000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else { throw MouthyFailure("Meeting audio could not be read.") }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            try write(buffer, timestamp: timestamp, type: type)
        } catch { accepting = false; onFailure(error.localizedDescription) }
    }
    // Internal entry point also verifies file conversion/timing without desktop capture permission.
    func write(_ input: AVAudioPCMBuffer, timestamp: Double, type: SCStreamOutputType) throws {
        guard timestamp.isFinite else { throw MouthyFailure("Meeting audio has invalid timestamps.") }
        if origin == nil { origin = timestamp }
        let offset = max(0, timestamp - (origin ?? timestamp))
        guard offset <= 7200 else { throw MouthyFailure("Meeting stopped at the two-hour recording limit. Your audio is saved.") }
        if converters[type]?.inputFormat != input.format { converters[type] = AVAudioConverter(from: input.format, to: format) }
        guard let converter = converters[type] else { throw MouthyFailure("Meeting audio conversion is unavailable.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw MouthyFailure("Meeting audio allocation failed.") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw MouthyFailure("Meeting audio conversion failed.") }
        if files[type] == nil {
            let url = folder.appendingPathComponent(type == .audio ? "System audio.wav" : "Microphone.wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            files[type] = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let file = files[type] else { return }
        let targetFrame = AVAudioFramePosition(offset * 16_000)
        // Keep the two tracks on the same clock, including gaps; never accumulate a whole recording in RAM.
        while file.length < targetFrame - 160 {
            let missing = AVAudioFrameCount(min(16_000, targetFrame - file.length))
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: missing)!
            silence.frameLength = missing
            memset(silence.floatChannelData![0], 0, Int(missing) * MemoryLayout<Float>.size)
            try file.write(from: silence)
        }
        try file.write(from: output)
        if type == .microphone, let values = output.floatChannelData?[0] {
            meterFrames += Int(output.frameLength)
            if meterFrames >= 533 {
                meterFrames = 0
                onWaveform(MicrophoneFrame.measure(UnsafeBufferPointer(start: values, count: Int(output.frameLength))))
            }
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        for (type, converter) in converters {
            guard let file = files[type] else { continue }
            for _ in 0..<8 {
                let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                if error != nil || status == .error { break }
                if output.frameLength > 0 { try? file.write(from: output) }
                if status == .endOfStream || output.frameLength == 0 { break }
            }
        }
        accepting = false; files.removeAll(); converters.removeAll()
    }
}

@MainActor final class MeetingRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var working = false
    @Published private(set) var folder: URL?
    @Published private(set) var message = "Save microphone and system audio as separate local tracks."
    private var stream: SCStream?
    private var sink: MeetingAudioSink?
    private let queue = DispatchQueue(label: "dev.mouthy.Mouthy.meeting", qos: .userInitiated)
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var stopping = false
    private var limit: Task<Void, Never>?
    var onState: ((Bool, Bool, String) -> Void)?
    var onWaveform: ((MicrophoneFrame) -> Void)?
    func start(folder destination: URL, inputUID: String) {
        guard !working, !recording else { return }
        generation = UUID(); let token = generation
        working = true; message = "Preparing meeting capture…"; onState?(false, true, message)
        operation = Task { [self] in
            do {
                guard await SpeechService.permission() else { throw MouthyFailure("Allow microphone access in System Settings before recording a meeting.") }
                try Task.checkCancellation()
                guard generation == token else { return }
                let input = inputUID.isEmpty ? AudioDevices.defaultInput() : AudioDevices.inputs().first { $0.id == inputUID }
                guard let input else { throw MouthyFailure("The selected microphone is disconnected.") }
                guard !(AudioDevices.lidClosed && AudioDevices.isBuiltIn(input)) else {
                    throw MouthyFailure("The MacBook lid is closed. Choose an external microphone before recording a meeting.")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard let display = content.displays.first else { throw MouthyFailure("No display is available for system audio capture.") }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw MouthyFailure("That meeting folder already exists. Start again to use a new folder.") }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                folder = destination
                let sink = MeetingAudioSink(folder: destination, onFailure: { [weak self] error in
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        await self?.stop(reason: error)
                    }
                }, onWaveform: { [weak self] frame in Task { @MainActor in
                    guard self?.generation == token else { return }
                    self?.onWaveform?(frame)
                } })
                self.sink = sink
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3; config.showsCursor = false
                config.capturesAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                config.captureMicrophone = true; config.microphoneCaptureDeviceID = input.id
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: queue)
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: queue)
                self.stream = stream
                try await stream.startCapture()
                try Task.checkCancellation()
                guard generation == token else { return }
                working = false; recording = true; message = "Recording microphone + system audio to \(destination.lastPathComponent)."
                onState?(true, false, message)
                limit = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(7200)); try Task.checkCancellation(); await self?.stop(reason: "Two-hour limit reached. Meeting audio is saved.") } catch {}
                }
            } catch {
                guard generation == token else { return }
                await stop(reason: error is CancellationError ? "Meeting cancelled. Any captured audio remains in its folder." : error.localizedDescription)
            }
        }
    }
    func cancel() { operation?.cancel(); Task { await stop(reason: "Meeting stopped. Any captured audio remains in its folder.") } }
    func stop(reason: String? = nil) async {
        guard !stopping, stream != nil || working || recording else { return }
        generation = UUID(); operation?.cancel()
        stopping = true; defer { stopping = false }
        limit?.cancel(); limit = nil
        let old = stream; stream = nil
        working = true; recording = false; onState?(false, true, "Finishing meeting files…")
        do { try await old?.stopCapture() } catch { message = error.localizedDescription }
        sink?.close(); sink = nil
        working = false
        message = reason ?? "Meeting saved locally. Transcribe the tracks when ready."
        onState?(false, false, message)
    }
    var audioFiles: [URL] {
        guard let folder else { return [] }
        return ["Microphone.wav", "System audio.wav"].map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
