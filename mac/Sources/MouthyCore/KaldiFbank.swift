import Accelerate
import Foundation

/// Kaldi's log mel filterbank exactly as `torchaudio.compliance.kaldi.fbank` computes it with the settings WeSpeaker's
/// ResNet34 uses: 16 kHz, 25 ms frames every 10 ms (snip edges), DC offset removed per frame, pre-emphasis 0.97,
/// Hamming window, 512-point power spectrum, triangular mel bands from 20 Hz to Nyquist, natural log floored at
/// `Float.ulpOfOne`, no dither, no energy column. Samples are on the int16 scale (WeSpeaker reads WAVs unnormalized),
/// so multiply -1...1 audio by 32 768 first. Pure Accelerate; safe to share across threads.
public final class KaldiFbank: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let frameLength = 400
    public static let frameShift = 160
    public static let fftLength = 512
    static let preemphasis: Float = 0.97

    public let melBins: Int
    private let window: [Float]
    /// (fftLength / 2) × melBins, row-major. The Nyquist bin has zero weight in Kaldi, so it is left out.
    private let melWeights: [Float]
    private let setup: FFTSetup

    public init(melBins: Int = 80, lowFrequency: Double = 20) {
        self.melBins = melBins
        let n = Self.frameLength
        window = (0..<n).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        func mel(_ frequency: Double) -> Double { 1127 * log(1 + frequency / 700) }
        let half = Self.fftLength / 2, binWidth = Double(Self.sampleRate) / Double(Self.fftLength)
        let low = mel(lowFrequency), high = mel(Double(Self.sampleRate) / 2)
        let delta = (high - low) / Double(melBins + 1)
        var weights = [Float](repeating: 0, count: half * melBins)
        for bin in 0..<half {
            let m = mel(binWidth * Double(bin))
            for band in 0..<melBins {
                let left = low + Double(band) * delta, center = low + Double(band + 1) * delta
                let right = low + Double(band + 2) * delta
                let rising = (m - left) / (center - left), falling = (right - m) / (right - center)
                weights[bin * melBins + band] = Float(max(0, min(rising, falling)))
            }
        }
        melWeights = weights
        setup = vDSP_create_fftsetup(vDSP_Length(9), FFTRadix(kFFTRadix2))!  // 2^9 = fftLength
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public static func frameCount(sampleCount: Int) -> Int {
        sampleCount < frameLength ? 0 : 1 + (sampleCount - frameLength) / frameShift
    }

    public static func sampleCount(frames: Int) -> Int { frames > 0 ? (frames - 1) * frameShift + frameLength : 0 }

    /// Log mel energies, `frameCount(sampleCount:)` rows of `melBins`, row-major.
    public func features(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { features($0) }
    }

    public func features(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = Self.frameCount(sampleCount: samples.count)
        guard frames > 0, let base = samples.baseAddress else { return [] }
        let n = vDSP_Length(Self.frameLength), half = Self.fftLength / 2
        var power = [Float](repeating: 0, count: frames * half)
        var frame = [Float](repeating: 0, count: Self.fftLength)  // samples 400..<512 stay zero (padding)
        var previous = [Float](repeating: 0, count: Self.frameLength)
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        for index in 0..<frames {
            frame.withUnsafeMutableBufferPointer { frame in
                let f = frame.baseAddress!
                f.update(from: base + index * Self.frameShift, count: Self.frameLength)
                var mean: Float = 0
                vDSP_meanv(f, 1, &mean, n)
                var negative = -mean
                vDSP_vsadd(f, 1, &negative, f, 1, n)
                // Pre-emphasis: x[i] - 0.97 x[i-1], with x[-1] = x[0].
                previous.withUnsafeMutableBufferPointer { p in
                    p[0] = f[0]
                    (p.baseAddress! + 1).update(from: f, count: Self.frameLength - 1)
                    var coefficient = -Self.preemphasis
                    vDSP_vsma(p.baseAddress!, 1, &coefficient, f, 1, f, 1, n)
                }
                vDSP_vmul(f, 1, window, 1, f, 1, n)
            }
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(9), FFTDirection(kFFTDirection_Forward))
                    power.withUnsafeMutableBufferPointer { p in
                        let row = p.baseAddress! + index * half
                        vDSP_zvmags(&split, 1, row, 1, vDSP_Length(half))
                        row[0] = r[0] * r[0]  // imagp[0] holds the Nyquist bin, which has no mel weight
                        var quarter: Float = 0.25  // vDSP's real FFT returns twice the DFT
                        vDSP_vsmul(row, 1, &quarter, row, 1, vDSP_Length(half))
                    }
                }
            }
        }
        var energies = [Float](repeating: 0, count: frames * melBins)
        vDSP_mmul(power, 1, melWeights, 1, &energies, 1, vDSP_Length(frames), vDSP_Length(melBins), vDSP_Length(half))
        var floor = Float.ulpOfOne, count = Int32(energies.count)
        vDSP_vthr(energies, 1, &floor, &energies, 1, vDSP_Length(energies.count))
        vvlogf(&energies, energies, &count)
        return energies
    }

    /// Subtracts each band's mean over all frames (WeSpeaker's cepstral mean normalization for one window).
    public static func subtractMean(_ features: inout [Float], bands: Int) {
        let frames = bands > 0 ? features.count / bands : 0
        guard frames > 0 else { return }
        features.withUnsafeMutableBufferPointer { buffer in
            for band in 0..<bands {
                let start = buffer.baseAddress! + band
                var mean: Float = 0
                vDSP_meanv(start, vDSP_Stride(bands), &mean, vDSP_Length(frames))
                var negative = -mean
                vDSP_vsadd(start, vDSP_Stride(bands), &negative, start, vDSP_Stride(bands), vDSP_Length(frames))
            }
        }
    }
}
