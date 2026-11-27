# Spot-check the training audio: Whisper transcribes 60 random clips; report word error rate against the script.
import random, re, sys, soundfile as sf, numpy as np
from scipy.signal import resample_poly
from faster_whisper import WhisperModel
voice = sys.argv[1]
rows = [l.rstrip("\n").split("|") for l in open(f"data/{voice}/meta.txt")]
random.seed(3); rows = random.sample(rows, 60)
m = WhisperModel("small.en", device="cuda", compute_type="float16")
norm = lambda s: re.sub(r"[^a-z' ]", " ", s.lower().replace("-", " ")).split()
def wer(r, h):
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        p, d[0] = d[0], i
        for j, hw in enumerate(h, 1): p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (rw != hw))
    return d[-1]
errs = words = 0; worst = []
for k, _, text in rows:
    a, sr = sf.read(f"data/{voice}/wavs/{k}.wav", dtype="float32")
    hyp = " ".join(s.text for s in m.transcribe(resample_poly(a, 2, 3).astype(np.float32), beam_size=1)[0])
    e = wer(norm(text), norm(hyp)); errs += e; words += len(norm(text)); worst.append((e / max(1, len(norm(text))), text, hyp))
print(f"word error rate {100*errs/words:.1f}% over {words} words")
for r, t, h in sorted(worst, reverse=True)[:4]: print(f"  {r:.0%} | {t} | {h.strip()}")
