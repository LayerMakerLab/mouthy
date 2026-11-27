# Design candidate Mouthy voices by blending Kokoro's American female presets; time synthesis on the GPU.
import time, torch, soundfile as sf, os
from kokoro import KPipeline
pipe = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
BLENDS = {
  "1-warm":   {"af_heart": .5, "af_bella": .3, "af_sarah": .2},
  "2-bright": {"af_heart": .45, "af_nova": .3, "af_jessica": .25},
  "3-calm":   {"af_heart": .4, "af_kore": .3, "af_aoede": .3},
  "4-clear":  {"af_bella": .5, "af_kore": .5},
  "5-crisp":  {"af_heart": .4, "af_sky": .3, "af_river": .3},
}
TEXT = ("Hey, I'm [Mouthy](/mˈWθi/). I put your words right where your cursor is. "
        "It's three forty-five, and you have two drafts waiting. Want me to send the first one now, or wait for your yes?")
os.makedirs("picks", exist_ok=True); os.makedirs("voices", exist_ok=True)
for name, mix in BLENDS.items():
    v = sum(w * pipe.load_single_voice(k) for k, w in mix.items())
    torch.save(v, f"voices/{name}.pt")
    t = time.time(); audio = []
    for r in pipe(TEXT, voice=v, speed=1.0): audio.append(r.audio)
    a = torch.cat(audio).numpy(); dt = time.time() - t
    sf.write(f"picks/{name}.wav", a, 24000)
    print(f"{name}: {len(a)/24000:.1f}s audio in {dt:.2f}s ({len(a)/24000/dt:.0f}x real time)")
