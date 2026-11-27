# Record the training lines in the 5-crisp voice with expression: Chatterbox Turbo (MIT), build time only.
# Each line gets a tone (neutral, excited, calm, worried) by steering Turbo with a tone reference in the same voice.
# Book lines get one tone; the conversational lines are recorded in all four so the model learns tone as a control.
# Usage: record_expressive.py <out_dir> [<n_lines>]   (resumable; meta.txt rows: key|tone|text)
import json, os, random, sys, time, torch, soundfile as sf
from chatterbox.tts_turbo import ChatterboxTurboTTS
TONES = ["neutral", "excited", "calm", "worried"]
out = sys.argv[1]; limit = int(sys.argv[2]) if len(sys.argv) > 2 else None
os.makedirs(f"{out}/wavs", exist_ok=True)
rng = random.Random(7)
def pick(text):
    if "!" in text: w = [.2, .6, .1, .1]
    elif "?" in text: w = [.4, .2, .15, .25]
    else: w = [.45, .15, .25, .15]
    return rng.choices(TONES, w)[0]
jobs = [(f"b{i:05d}", pick(t), t) for i, t in enumerate(json.load(open("data/lines.json")))]
talk = [l.strip() for l in open("data/talk.txt") if l.strip()]
jobs += [(f"t{i:03d}{tone[0]}", tone, t) for i, t in enumerate(talk) for tone in TONES]
rng.shuffle(jobs); jobs = jobs[:limit]
m = ChatterboxTurboTTS.from_pretrained(device="cuda"); conds = {}
for tone in TONES: m.prepare_conditionals(f"voices/tones/{tone}.wav"); conds[tone] = m.conds
done = set(l.split("|")[0] for l in open(f"{out}/meta.txt")) if os.path.exists(f"{out}/meta.txt") else set()
meta = open(f"{out}/meta.txt", "a"); t0 = time.time(); secs = 0.0
for n, (key, tone, text) in enumerate(jobs):
    if key in done: continue
    m.conds = conds[tone]; torch.manual_seed(n)
    a = m.generate(text)[0].numpy(); secs += len(a) / m.sr
    sf.write(f"{out}/wavs/{key}.wav", a, m.sr); meta.write(f"{key}|{tone}|{text}\n"); meta.flush()
    if n % 500 == 0: print(f"{n}/{len(jobs)} lines, {secs/3600:.2f} h audio, {time.time()-t0:.0f} s", flush=True)
print(f"done: {secs/3600:.2f} h audio in {time.time()-t0:.0f} s", flush=True)
