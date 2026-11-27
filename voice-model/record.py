# Read every script line in the chosen Mouthy voice with Kokoro (build time only) and keep the phonemes it used.
import json, os, sys, time, torch, soundfile as sf
from kokoro import KPipeline
os.chdir(os.path.dirname(os.path.abspath(__file__))); voice_name = sys.argv[1]
pipe = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
voice = torch.load(f"../voices/{voice_name}.pt")
lines = json.load(open("lines.json"))
out = f"{voice_name}"; os.makedirs(f"{out}/wavs", exist_ok=True)
done = set(l.split("|")[0] for l in open(f"{out}/meta.txt")) if os.path.exists(f"{out}/meta.txt") else set()
meta = open(f"{out}/meta.txt", "a"); t0 = time.time(); secs = 0.0
for i, text in enumerate(lines):
    key = f"{i:05d}"
    if key in done: continue
    audio, ph = [], []
    for r in pipe(text, voice=voice, speed=1.0):
        if r.audio is not None: audio.append(r.audio); ph.append(r.phonemes)
    if not audio: continue
    a = torch.cat(audio).numpy(); secs += len(a) / 24000
    sf.write(f"{out}/wavs/{key}.wav", a, 24000)
    meta.write(f"{key}|{' '.join(ph)}|{text}\n"); meta.flush()
    if i % 500 == 0: print(f"{i}/{len(lines)} lines, {secs/3600:.2f} h audio, {time.time()-t0:.0f} s", flush=True)
print(f"done: {secs/3600:.2f} h audio in {time.time()-t0:.0f} s", flush=True)
