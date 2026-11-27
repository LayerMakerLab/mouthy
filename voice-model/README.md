# Mouthy's voice model

Mouthy's own text-to-speech voice, trained from zero. The architecture is open (Matcha-TTS for text to sound picture,
Vocos for sound picture to audio, both MIT); the weights are Mouthy's. Kokoro-82M (Apache 2.0) is used only at build
time to speak the training scripts in a voice designed for Mouthy; nothing of Kokoro ships.

Work folder layout (Linux with an NVIDIA GPU): `Matcha-TTS/` and `vocos/` (upstream clones with `matcha.patch` and
`vocos.patch` applied), `.venv` (PyTorch, Kokoro, Matcha, faster-whisper), `.venv-vocos` (PyTorch, pytorch_lightning 1.9),
`voices/`, `data/` (holding `scripts.py`, `record.py`, `filelists.py`), and `train.sh`.

1. `design_voice.py`: blends Kokoro's American English female presets into candidate voices and renders a sample of each.
2. `data/scripts.py`: reading scripts from public-domain books (Project Gutenberg) plus spelled-out numbers, times and dates.
3. `data/record.py <voice>`: speaks every script line in the chosen voice and keeps the phonemes used (about 14 hours of
   audio in 15 minutes on an RTX 3080).
4. `check_clarity.py <voice>`: Whisper transcribes random clips; the word error rate catches garbled audio.
5. `data/filelists.py <voice>`: training and check lists. Then `matcha/utils/generate_data_statistics.py -i mouthy.yaml`
   and put the mean and deviation into `configs/data/mouthy.yaml`.
6. `train.sh`: the acoustic model to 150k steps, then the vocoder, one after the other on one GPU.
7. `eval_checkpoints.py <lines> recordings <ckpt>...`: Whisper word error rate and length against the recordings on the
   held-out lines, per checkpoint, on the CPU (Griffin-Lim stands in for the vocoder; "recordings" is the floor).
8. `speed.py <acoustic.onnx> <vocoder.onnx>`: time from phoneme tokens to audio on the CPU.

Expressive version (Kokoro reads questions flat, so the voice copied that): Chatterbox Turbo (MIT, build time only)
copies the 5-crisp voice and adds expression. Copy `talk.txt` into `data/`, then:

9. `make_tones.py`: four tone references in the 5-crisp voice (neutral, excited, calm, worried) and a check that each
   one steers the same sentence differently.
10. `expressive.sh`: `record_expressive.py` (book lines in one tone each, the conversational lines in all four),
    `prep_expressive.py` (Whisper drops skipped or garbled takes; phonemes; lists of `wav|tone|phonemes`), `mel_stats.py`,
    then the acoustic model with tone as its speaker input (`experiment=mouthy-expr`, `n_spks: 4`) and a vocoder fine-tune.

Phonemes are Kokoro's US English set (misaki, Apache 2.0). Speed measured on an M5 CPU with a model of the same size:
a short phrase in about 15 ms, a twelve-word sentence in about 37 ms.
