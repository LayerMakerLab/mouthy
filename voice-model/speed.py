# Time text-tokens -> audio for a Matcha (3 ODE steps) + Vocos voice on the M5 CPU, ISTFT included.
import sys, time, statistics, numpy as np, onnxruntime as ort
acoustic, vocoder = sys.argv[1], sys.argv[2]  # a Matcha ONNX model and a Vocos ONNX vocoder
def istft(mag, x, y, n_fft=1024, hop=256):
    spec = mag * (x + 1j * y)                       # (freq, frames)
    frames = np.fft.irfft(spec.T, n=n_fft) * np.hanning(n_fft + 1)[:-1]
    out = np.zeros(hop * (len(frames) - 1) + n_fft)
    for i, f in enumerate(frames): out[i * hop:i * hop + n_fft] += f
    return out
for threads in (1, 2, 4):
    so = ort.SessionOptions(); so.intra_op_num_threads = threads
    am = ort.InferenceSession(acoustic, so)
    vo = ort.InferenceSession(vocoder, so)
    for label, n_ph in [("short phrase  (~'Sending it now.')", 15), ("full sentence (~12 words)", 55)]:
        ids = np.random.default_rng(0).integers(10, 60, size=(1, 2 * n_ph + 1)); ids[0, ::2] = 0
        feed = {"x": ids, "x_lengths": np.array([ids.shape[1]]), "scales": np.array([0.667, 1.0], np.float32)}  # matcha.onnx.export
        def run():
            mel = am.run(None, feed)[0]; mag, x, y = vo.run(None, {"mels": mel}); return istft(mag[0], x[0], y[0])
        run(); ts = []
        for _ in range(9):
            t = time.perf_counter(); a = run(); ts.append((time.perf_counter() - t) * 1000)
        print(f"{threads} thread(s) | {label}: {len(a)/24000:4.1f}s of audio | median {statistics.median(ts):4.0f} ms, best {min(ts):4.0f} ms")
