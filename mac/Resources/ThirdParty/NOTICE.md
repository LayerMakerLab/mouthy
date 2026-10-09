# Local speech dependencies

Mouthy uses FluidAudio 0.17.4 (FluidInference, Apache-2.0) for Core ML inference:
https://github.com/FluidInference/FluidAudio/tree/v0.17.4

NVIDIA Parakeet TDT 0.6B v3 model, converted to Core ML by FluidInference:
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
Model license: CC BY 4.0, https://creativecommons.org/licenses/by/4.0/
The conversion is supplied by FluidInference; Mouthy does not alter model weights.
Models download separately and run locally. No inference audio is sent to a model host.

WeSpeaker ResNet34-LM speaker model, trained on VoxCeleb, used by "Only my voice":
https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM (commit f0c48c298fd835726c27956a5d617bad7115627e)
WeSpeaker: https://github.com/wenet-e2e/wespeaker. VoxCeleb (A. Nagrani, J. S. Chung, A. Zisserman and others, University
of Oxford): https://www.robots.ox.ac.uk/~vgg/data/voxceleb/
Model license: CC BY 4.0, https://creativecommons.org/licenses/by/4.0/
Changed: converted to Core ML by LayerMaker LLC with a fixed 2 s (200-frame) fbank input so it runs on the Neural
Engine; the fbank front end runs in Mouthy. Weights are not otherwise altered. It ships inside the app and runs locally.

Dependency license texts are included beside this notice. Source versions are pinned in Package.resolved.

WhisperKit / Argmax OSS 1.1.0 (MIT), used for actual local OpenAI Whisper inference:
https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.0
Whisper models and tokenizer assets derive from OpenAI Whisper (MIT):
https://github.com/openai/whisper
Core ML conversions by Argmax: https://huggingface.co/argmaxinc/whisperkit-coreml
Mouthy does not alter model weights. Models download separately on explicit request.
WhisperKit's license and third-party notices are included beside this file.

On Intel Macs, Mouthy runs the same Parakeet model through sherpa-onnx 1.13.8 (Next-gen Kaldi, Apache-2.0)
and ONNX Runtime (Microsoft, MIT), bundled in Contents/Frameworks/sherpa-onnx and loaded only on Intel:
https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8
https://github.com/microsoft/onnxruntime
The int8 ONNX export of NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0) is published by the sherpa-onnx project:
https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
Mouthy's bridge (Sources/CSherpaOnnx) includes the unmodified sherpa-onnx C API header.

# Updates

Sparkle 2.10.0 (MIT, with the bundled bsdiff and other notices in Sparkle-LICENSE.txt) checks for and installs
updates in the Mouthy app only; it is embedded as Contents/Frameworks/Sparkle.framework:
https://github.com/sparkle-project/Sparkle/tree/2.10.0
