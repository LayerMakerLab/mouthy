# Third-party components (Windows and Linux)

Mouthy for Windows and Linux is GPL-3.0. It is built with these components, each under its own license:

| Component | License |
| --- | --- |
| [Tauri](https://github.com/tauri-apps/tauri) 2 and its global-shortcut and single-instance plugins | Apache-2.0 or MIT |
| [sherpa-rs](https://github.com/thewh1teagle/sherpa-rs) 0.6 | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) runtime libraries (downloaded at build time) | Apache-2.0 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (bundled with sherpa-onnx) | MIT |
| [cpal](https://github.com/RustAudio/cpal), [hound](https://github.com/ruuda/hound) | Apache-2.0 |
| [enigo](https://github.com/enigo-rs/enigo) | MIT |
| [arboard](https://github.com/1Password/arboard), serde, serde_json, regex, ureq, tiny_http, uuid, dirs, tar, bzip2, hmac, sha2, parking_lot, anyhow, url, windows-rs | MIT or Apache-2.0 |
| libbzip2 1.0.8, bundled with the bzip2 crate (built in on Windows; on Linux only when no system libbz2 is found) | bzip2 license (BSD-style) |

The complete dependency list with versions is in `Cargo.lock`; `cargo metadata` reports each crate's license.

Speech models are downloaded separately when you ask for them and are not part of this repository:

- NVIDIA Parakeet TDT 0.6B v3 ([model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)), CC BY 4.0, in the sherpa-onnx conversion.
- OpenAI Whisper ([repository](https://github.com/openai/whisper)), MIT, in the sherpa-onnx conversion.
