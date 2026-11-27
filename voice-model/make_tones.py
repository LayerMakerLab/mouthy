# Tone references in the 5-crisp voice (Chatterbox Turbo, MIT), then a check that each one steers the same sentence differently.
import time, numpy as np, torch, soundfile as sf, librosa
from chatterbox.tts_turbo import ChatterboxTurboTTS
from chatterbox.models.voice_encoder import VoiceEncoder
from huggingface_hub import hf_hub_download
m = ChatterboxTurboTTS.from_pretrained(device="cuda")
tones = {
 "neutral": ["The meeting moved to Thursday at ten.", "Your files are saved in the projects folder.", "The build finished and every test passed.", "I sent the new link to everyone on the list."],
 "excited": ["Oh my gosh, it actually worked!", "No way, that's incredible news!", "Yes! We finally did it!", "This is the best day I've had all month!"],
 "calm": ["Hey, it's okay. Take a slow breath.", "There's no rush. We'll go one step at a time.", "You're doing fine. Let's just ease into it.", "Rest for a minute. I'll be right here."],
 "worried": ["Hold on, something doesn't look right.", "Wait, did we just lose all of that?", "I'm not sure this is safe to run.", "Oh no. I think the drive is failing."],
}
gap = np.zeros(int(0.35 * 24000), np.float32)
for tone, lines in tones.items():
    parts = []
    for t in lines:
        torch.manual_seed(0); a = m.generate(t, audio_prompt_path="picks/5-crisp.wav")[0].numpy()
        parts += [librosa.resample(a, orig_sr=m.sr, target_sr=24000) if m.sr != 24000 else a, gap]
    sf.write(f"voices/tones/{tone}.wav", np.concatenate(parts), 24000)
ve = VoiceEncoder(); ve.load_state_dict(torch.load(hf_hub_download("ResembleAI/chatterbox", "ve.pt"), map_location="cpu")); ve.eval()
def emb(a): e = ve.embeds_from_wavs([librosa.resample(a, orig_sr=24000, target_sr=16000)], sample_rate=16000)[0]; return e / np.linalg.norm(e)
r = emb(sf.read("picks/5-crisp.wav", dtype="float32")[0])
def stats(a):
    p, v, _ = librosa.pyin(a, fmin=120, fmax=500, sr=24000, frame_length=1024, hop_length=256); x = p[v & ~np.isnan(p)]
    st = 12 * np.log2(x / 200); return np.median(st), np.percentile(st, 95) - np.percentile(st, 5)
probe = ["I found the file you were looking for. It was in the downloads folder.", "Are you sure you want to send that now?"]
spent = audio = 0.0
for tone in tones:
    for j, t in enumerate(probe):
        torch.manual_seed(0); t0 = time.time(); a = m.generate(t, audio_prompt_path=f"voices/tones/{tone}.wav")[0].numpy()
        if m.sr != 24000: a = librosa.resample(a, orig_sr=m.sr, target_sr=24000)
        spent += time.time() - t0; audio += len(a) / 24000
        sf.write(f"render/expr/tone-{tone}-{j}.wav", a, 24000); med, rng = stats(a)
        print(f"{tone:8s} probe{j}: pitch {med:+5.1f} st vs 200Hz, range {rng:4.1f} st, {len(a)/24000:4.1f}s, voice match {float(emb(a) @ r):.2f}", flush=True)
print(f"speed: {audio/spent:.1f}x real time")
