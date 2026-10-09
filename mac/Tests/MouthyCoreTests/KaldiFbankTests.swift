import Foundation
import Testing
@testable import MouthyCore

/// Rows 0, 11 and 22 of `torchaudio.compliance.kaldi.fbank(x, num_mel_bins=80, frame_length=25, frame_shift=10,
/// sample_frequency=16000, window_type="hamming")` (torch 2.7.0) for `fbankFixtureSignal`, rounded to 4 decimals.
/// Written by the conversion script kept with the model's source (`convert.py`).
private let torchaudioRows: [Int: [Float]] = [
    0: [9.7612, 9.81, 9.3165, 7.7511, 9.6607, 10.98, 11.8594, 12.1654, 11.3173, 8.8814,
        11.5322, 12.9854, 19.1604, 22.3908, 23.2155, 22.1259, 18.3824, 11.8798, 12.6579, 13.8586,
        13.5309, 12.224, 13.1071, 13.283, 12.057, 12.8356, 12.7976, 12.2262, 12.846, 12.4626,
        12.8524, 12.8065, 13.1109, 13.4361, 13.4988, 14.2358, 13.8173, 18.8569, 23.9526, 24.0894,
        19.6925, 14.8193, 14.3779, 14.0329, 13.9338, 13.3156, 13.3642, 13.1301, 12.7609, 12.7445,
        12.6421, 12.3858, 12.2183, 12.1541, 12.0472, 11.9047, 11.7576, 11.6336, 11.5143, 11.4341,
        11.39, 11.455, 11.6954, 12.1885, 12.9242, 13.8705, 22.5971, 24.0965, 18.0802, 14.5704,
        14.1406, 13.7664, 13.5174, 13.3823, 13.2281, 13.1387, 13.1046, 13.0322, 13.0235, 13.0271],
    11: [12.6041, 13.5294, 13.2946, 12.1923, 11.4496, 12.3454, 13.5219, 13.9313, 13.311, 9.2661,
         12.6336, 11.8117, 19.1309, 22.3974, 23.2153, 22.1177, 18.4593, 12.6836, 11.3723, 12.7164,
         12.4404, 10.9305, 11.3969, 11.7838, 10.7883, 10.6875, 10.9415, 11.1381, 11.049, 11.0934,
         12.0534, 11.5534, 12.6071, 12.8721, 13.1183, 13.9598, 13.5107, 18.8568, 23.9523, 24.0896,
         19.6906, 14.8913, 14.5544, 14.1292, 14.1457, 13.5524, 13.5605, 13.4709, 13.1269, 13.0617,
         13.091, 12.9556, 12.8194, 12.7818, 12.7891, 12.7818, 12.7753, 12.7964, 12.8422, 12.8846,
         13.0178, 13.159, 13.3666, 13.6665, 14.0867, 14.6776, 22.5984, 24.096, 18.0876, 13.6879,
         12.9218, 12.1557, 11.6865, 11.1848, 10.9015, 10.5741, 10.4026, 10.274, 10.1666, 10.1238],
    22: [13.07, 13.9873, 13.7476, 12.6435, 11.8798, 12.7491, 13.9242, 14.322, 13.6935, 9.6582,
         13.0297, 10.8705, 19.1165, 22.4002, 23.2156, 22.1131, 18.4954, 12.9704, 9.7913, 11.4389,
         11.3891, 10.315, 9.0486, 9.8673, 10.5622, 10.7942, 9.7694, 11.4614, 11.7961, 11.1147,
         12.5875, 12.1783, 12.8959, 13.361, 13.3107, 14.264, 13.6963, 18.8563, 23.9527, 24.089,
         19.6972, 14.6779, 14.3615, 13.8546, 13.8522, 13.2288, 13.1576, 13.0604, 12.6922, 12.5594,
         12.5656, 12.4227, 12.2659, 12.1968, 12.1861, 12.1753, 12.1764, 12.1966, 12.2636, 12.3217,
         12.4858, 12.6695, 12.9314, 13.2944, 13.7951, 14.465, 22.5981, 24.0962, 18.0828, 13.9765,
         13.3459, 12.758, 12.3619, 12.0626, 11.8021, 11.6045, 11.4983, 11.3485, 11.295, 11.2749],
]

/// Three tones at the int16 scale, 0.25 s: the same formula the conversion script uses.
private let fbankFixtureSignal: [Float] = (0..<4_000).map { n in
    let t = Double(n) / 16_000
    return Float((6_000 * sin(2 * .pi * 440 * t) + 2_500 * sin(2 * .pi * 1_730 * t + 0.3)
                  + 800 * sin(2 * .pi * 5_100 * t)).rounded())
}

@Test func kaldiFbankMatchesTorchaudio() {
    let fbank = KaldiFbank()
    let features = fbank.features(fbankFixtureSignal)
    #expect(features.count == 23 * 80)
    var worst: Float = 0
    for (row, expected) in torchaudioRows {
        for band in 0..<80 { worst = max(worst, abs(features[row * 80 + band] - expected[band])) }
    }
    #expect(worst < 2e-3, "largest difference from torchaudio: \(worst)")
}

@Test func kaldiFbankFramesFollowSnipEdges() {
    #expect(KaldiFbank.frameCount(sampleCount: 399) == 0)
    #expect(KaldiFbank.frameCount(sampleCount: 400) == 1)
    #expect(KaldiFbank.frameCount(sampleCount: 32_240) == 200)
    #expect(KaldiFbank.frameCount(sampleCount: 32_399) == 200)
    #expect(KaldiFbank.sampleCount(frames: 200) == 32_240)
    #expect(KaldiFbank().features([Float](repeating: 1, count: 399)).isEmpty)
}

@Test func kaldiFbankSilenceIsTheLogFloor() {
    // A constant signal is all DC, which each frame removes; every band then sits at log(Float.ulpOfOne).
    let features = KaldiFbank().features([Float](repeating: 1_000, count: 1_000))
    #expect(features.count == 4 * 80)
    #expect(features.allSatisfy { abs($0 - log(Float.ulpOfOne)) < 1e-4 })
}

@Test func meanSubtractionCentersEveryBand() {
    var features = KaldiFbank().features(fbankFixtureSignal)
    KaldiFbank.subtractMean(&features, bands: 80)
    for band in 0..<80 {
        let mean = stride(from: band, to: features.count, by: 80).map { features[$0] }.reduce(0, +) / 23
        #expect(abs(mean) < 1e-4)
    }
}
