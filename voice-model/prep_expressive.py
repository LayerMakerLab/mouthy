# Keep only clean takes, add phonemes, write training lists. Whisper drops clips that skip or garble words
# (Turbo is autoregressive and can hallucinate). Usage: prep_expressive.py <data_dir>
import os, re, random, sys, numpy as np, soundfile as sf
from scipy.signal import resample_poly
from faster_whisper import WhisperModel
from kokoro import KPipeline
TONES = ["neutral", "excited", "calm", "worried"]
d = sys.argv[1]; root = os.path.abspath(d)
rows = [l.rstrip("\n").split("|") for l in open(f"{d}/meta.txt")]
w = WhisperModel("small.en", device="cuda", compute_type="float16")
g2p = KPipeline(lang_code="a", model=False)
norm = lambda s: re.sub(r"[^a-z' ]", " ", s.lower().replace("-", " ")).split()
def wer(r, h):
    dd = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        p, dd[0] = dd[0], i
        for j, hw in enumerate(h, 1): p, dd[j] = dd[j], min(dd[j] + 1, dd[j - 1] + 1, p + (rw != hw))
    return dd[-1]
keep, dropped = [], []
for key, tone, text in rows:
    a, sr = sf.read(f"{d}/wavs/{key}.wav", dtype="float32")
    hyp = " ".join(s.text for s in w.transcribe(resample_poly(a, 2, 3).astype(np.float32), beam_size=1)[0])
    r = norm(text); errs = wer(r, norm(hyp)); e = errs / max(1, len(r)); secs = len(a) / sr
    digits = any(c.isdigit() for c in hyp)  # Whisper writes numbers as digits; only the length check applies then
    if (not digits and errs > max(1, round(0.15 * len(r)))) or secs > 1.2 * (0.6 + 0.45 * len(r)): dropped.append((e, key, text, hyp)); continue
    ph = " ".join(x.phonemes for x in g2p(text.replace("Mouthy", "[Mouthy](/mˈWθi/)"))).strip()
    if ph: keep.append((f"{root}/wavs/{key}.wav", TONES.index(tone), ph))
print(f"kept {len(keep)}, dropped {len(dropped)}")
for e, k, t, h in sorted(dropped, reverse=True)[:8]: print(f"  {e:.0%} {k} | {t} | {h.strip()}")
open(f"{d}/dropped.txt", "w").write("".join(f"{k}|{e:.2f}|{t}|{h.strip()}\n" for e, k, t, h in dropped))
random.seed(1); random.shuffle(keep); nv = min(150, len(keep) // 10); val, train = keep[:nv], keep[nv:]
os.makedirs("data/mouthy-expr", exist_ok=True)
for name, part in [("train", train), ("val", val)]:
    open(f"data/mouthy-expr/{name}.txt", "w").write("".join(f"{p}|{s}|{ph}\n" for p, s, ph in part))
    open(f"data/mouthy-expr/vocos-{name}.txt", "w").write("".join(f"{p}\n" for p, _, _ in part))
print(len(train), "train,", len(val), "val")
