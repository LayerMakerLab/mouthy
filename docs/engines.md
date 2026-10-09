# Speech engines

All engines run on your own computer. A model is downloaded once, when you choose it in Settings (or with `download` on the [command line](command-line.md)), and then works without internet. Local Only Mode blocks downloads altogether. Apple Speech uses language files that macOS itself downloads and manages.

## Which one to pick

- **NVIDIA Parakeet v3**: fast and accurate on every platform, including Intel Macs. 25 European languages. The default on Windows, Linux and Intel Macs.
- **OpenAI Whisper**: the widest language coverage (about 100 languages); on the Mac it can also translate into English. Larger models are more accurate and slower.
- **Apple Speech** (Apple silicon Macs): shows the text live while you speak. Languages follow what macOS supports. The default on Apple silicon Macs.

## Availability

| Engine | Mac, Apple silicon | Mac, Intel | Windows | Linux |
| --- | :---: | :---: | :---: | :---: |
| NVIDIA Parakeet v3 | ✓ | ✓ | ✓ | ✓ |
| OpenAI Whisper | ✓ | – | ✓ | ✓ |
| Apple Speech | ✓ | – | – | – |

On the Mac, Whisper runs through [WhisperKit](https://github.com/argmaxinc/WhisperKit), which needs Apple silicon, and macOS offers its on-device speech recognition only on Apple silicon. Intel Macs therefore use Parakeet, which there runs through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on the CPU (bundled with Mouthy, same model and text as the other platforms), because Intel Macs have no Neural Engine for Core ML.

Parakeet and Whisper recognize what you say while you talk: each time you pause, everything since the last long pause is recognized in the background, so when you finish there is usually nothing left to do. On a 2019 Intel MacBook Pro and an M5 MacBook Pro alike, text was ready within a few milliseconds when the shortcut came half a second after the last word.

Each ✓ was checked on real hardware on 2026-10-04 by transcribing the same recording: an M5 MacBook Pro (macOS 27, with network access blocked during transcription), a 2019 Intel MacBook Pro (macOS 26.6), Windows 11 and Arch Linux (Hyprland).

## Models and download sizes

**Mac** (Core ML)

| Model | Languages | Size on disk |
| --- | --- | --- |
| Parakeet v3, with its vocabulary model | 25 European | about 560 MB |
| Whisper base.en | English | about 145 MB |
| Whisper small | about 100 | 216 MB |
| Whisper medium | about 100 | about 1.5 GB |
| Whisper large-v3 turbo | about 100 | 626 MB |

Intel Macs download the Parakeet v3 (int8) model listed for Windows and Linux instead.

**Windows and Linux** ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), runs on the CPU)

| Model | Languages | Download |
| --- | --- | --- |
| Parakeet v3 (int8) | 25 European | 487 MB |
| Whisper tiny.en | English | 118 MB |
| Whisper base.en | English | 208 MB |
| Whisper small | about 100 | 639 MB |
| Whisper medium | about 100 | 1.9 GB |
| Whisper turbo | about 100 | 563 MB |

Parakeet v3's languages: Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish and Ukrainian.

## Integrity

Windows and Linux model archives are checked against a SHA-256 checksum pinned in the source before they are installed; a changed file is refused. On the Mac, the Whisper tokenizer files and the Parakeet archive for Intel Macs are pinned the same way, and the Core ML models come from the [FluidAudio](https://huggingface.co/FluidInference) and [WhisperKit](https://huggingface.co/argmaxinc/whisperkit-coreml) repositories over HTTPS.

## Licenses

- NVIDIA Parakeet TDT 0.6B v3: [CC BY 4.0](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- OpenAI Whisper: [MIT](https://github.com/openai/whisper)

The models are downloaded from their publishers and are not part of this repository.
