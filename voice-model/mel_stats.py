# Mel mean and deviation over a training list (what Matcha normalises with), written into the data config.
import re, sys, torch, soundfile as sf
from matcha.utils.audio import mel_spectrogram
lst, cfg = sys.argv[1], sys.argv[2]; limit = int(sys.argv[3]) if len(sys.argv) > 3 else None
s = s2 = n = 0.0
for line in open(lst).readlines()[:limit]:
    a, sr = sf.read(line.split("|")[0], dtype="float32"); assert sr == 24000, sr
    m = mel_spectrogram(torch.from_numpy(a)[None], 1024, 100, 24000, 256, 1024, 0, 12000, center=False)
    s += m.sum().item(); s2 += (m ** 2).sum().item(); n += m.numel()
mean = s / n; std = (s2 / n - mean ** 2) ** 0.5
print(f"mel_mean: {mean:.6f}\nmel_std: {std:.6f}")
if limit is None:
    t = open(cfg).read(); t = re.sub(r"mel_mean: .*", f"mel_mean: {mean:.6f}", t); t = re.sub(r"mel_std: .*", f"mel_std: {std:.6f}", t)
    open(cfg, "w").write(t)
