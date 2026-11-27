# Rank Matcha checkpoints on the held-out lines: Whisper word error rate and speaking-rate drift against the recordings.
# Runs on the CPU (the GPU may still be training). Without a trained vocoder it uses Griffin-Lim, which is enough to
# compare checkpoints for skipped or garbled words; judge sound quality by ear with the real vocoder.
# Usage: eval_checkpoints.py <n_lines> <ckpt> [<ckpt> ...]
import json, re, sys, time, numpy as np, soundfile as sf, torch, librosa
from scipy.signal import resample_poly
from faster_whisper import WhisperModel
from matcha.models.matcha_tts import MatchaTTS
from matcha.text import text_to_sequence
from matcha.utils.utils import intersperse

torch.set_num_threads(8)
n_lines, ckpts = int(sys.argv[1]), sys.argv[2:]
lines = json.load(open("data/lines.json"))
rows = [l.rstrip("\n").split("|") for l in open("data/mouthy/val.txt")][:n_lines]
whisper = WhisperModel("small.en", device="cpu", compute_type="int8", cpu_threads=8)
norm = lambda s: re.sub(r"[^a-z' ]", " ", s.lower().replace("-", " ")).split()

def wer(r, h):
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        p, d[0] = d[0], i
        for j, hw in enumerate(h, 1): p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (rw != hw))
    return d[-1]

def hear(audio):
    return " ".join(s.text for s in whisper.transcribe(resample_poly(audio, 2, 3).astype(np.float32), beam_size=1)[0])

for path in ckpts:  # "recordings" = the training audio itself through Griffin-Lim: the floor for this test
    model = None if path == "recordings" else MatchaTTS.load_from_checkpoint(path, map_location="cpu", weights_only=False).eval()
    errs = words = 0; ratios = []; worst = []; t0 = time.time()
    for wav, phonemes in rows:
        text = lines[int(wav.rsplit("/", 1)[1][:-4])]
        if model is None:
            a, _ = sf.read(wav, dtype="float32")
            mel = librosa.feature.melspectrogram(y=a, sr=24000, n_fft=1024, hop_length=256, n_mels=100, fmax=12000, power=1.0)
        else:
            x = torch.tensor(intersperse(text_to_sequence(phonemes, ["mouthy_phonemes"])[0], 0))[None]
            with torch.inference_mode():
                out = model.synthesise(x, torch.tensor([x.shape[1]]), n_timesteps=10, temperature=0.667)
            mel = np.exp(out["mel"][0].numpy())
        audio = librosa.feature.inverse.mel_to_audio(mel, sr=24000, n_fft=1024, hop_length=256, fmax=12000, power=1.0, n_iter=32)
        ratios.append(len(audio) / sf.info(wav).frames)
        e = wer(norm(text), norm(hear(audio))); n = len(norm(text)); errs += e; words += n
        worst.append((e / max(1, n), text))
    r = np.array(ratios)
    print(f"{path.rsplit('/', 1)[-1]:32s} WER {100*errs/words:5.1f}%  length vs recording {r.mean():.3f} (sd {r.std():.3f})  {time.time()-t0:.0f}s", flush=True)
    for w, t in sorted(worst, reverse=True)[:2]: print(f"    {w:.0%} | {t}", flush=True)
