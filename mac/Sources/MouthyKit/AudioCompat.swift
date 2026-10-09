import AVFoundation
import AudioToolbox
import Speech

/// macOS 26 support: macOS 27 adds a safer tap API, buffer copying, `withAudioUnit` and
/// AnalyzerInputConverter. On 26 the long-standing equivalents are used instead.
enum AudioCompat {
    /// Installs a microphone tap that hands each buffer over as an independent copy.
    static func installTap(on node: AVAudioInputNode, bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                           handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        if #available(macOS 27.0, *) {
            try node.installAudioTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
                handler(AVAudioPCMBuffer(copying: buffer), time)
            }
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
                guard let copy = copy(buffer) else { return }
                handler(copy, time)
            }
        }
    }

    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let input = from.mData, let output = to.mData else { continue }
            memcpy(output, input, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Runs `body` with the input node's audio unit.
    static func withAudioUnit<T>(_ node: AVAudioInputNode, _ body: (AudioUnit?) throws -> T) rethrows -> T {
        if #available(macOS 27.0, *) {
            return try node.withAudioUnit { try body($0) }
        }
        return try body(node.audioUnit)
    }
}

/// Converts microphone buffers into the analyzer's format.
protocol AnalyzerFeedConverter: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

@available(macOS 27.0, *)
final class ModernAnalyzerConverter: AnalyzerFeedConverter {
    private let converter: AnalyzerInputConverter
    init(format: AVAudioFormat) { converter = AnalyzerInputConverter(analyzerFormat: format) }
    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> [AnalyzerInput] { try converter.convert(buffer, at: time) }
    func flush() throws -> [AnalyzerInput] { try converter.flush() }
}

/// macOS 26: resample with AVAudioConverter; the analyzer timestamps input in arrival order.
final class LegacyAnalyzerConverter: AnalyzerFeedConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    init(format: AVAudioFormat) { self.format = format }
    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> [AnalyzerInput] {
        if buffer.format == format { return [AnalyzerInput(buffer: buffer)] }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { throw MouthyFailure("This microphone format cannot be converted for speech recognition.") }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { return [] }
        return [AnalyzerInput(buffer: output)]
    }
    func flush() throws -> [AnalyzerInput] { [] }
}
