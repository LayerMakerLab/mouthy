# Speech model storage

Settings → Speech models lists Apple speech for the selected language, Parakeet v3 and all four Whisper variants. Downloading or removing a row does not select it for dictation. Choose the active engine and Whisper variant in Speech. Network blocking disables downloads; existing local models remain usable.

Apple manages shared speech assets. Mouthy can request their installation and release its language reservation. macOS controls when unused files are removed and does not expose their size through `AssetInventory`. The tile says “Size managed by macOS”; it never claims that releasing a reservation immediately frees space. [Apple's release API](https://developer.apple.com/documentation/speech/assetinventory/release(reservedlocale:)).

Parakeet uses Core ML on Apple silicon and the bundled sherpa-onnx runtime with an int8 model on Intel. The Core ML total includes the CTC vocabulary model downloaded by Mouthy. Removal moves the model, legacy cache and vocabulary model to Trash; other apps using that shared cache may need to download again. Host-provided model folders are managed by the host app. Whisper requires Apple silicon.

The tile measures regular-file bytes on disk, including compiled-model package contents, without following symlinks. Incomplete downloads can be removed or downloaded again. Moving files to Trash does not reclaim disk space until Trash is emptied.

## Download size evidence

Counts below are transfer file bytes, verified against publisher metadata on 2026-10-06. Core ML downloads follow the upstream revision chosen by the existing SDKs, so Mouthy labels these totals “About”; the immutable revisions below identify the metadata used, not an added download pin. Installed sizes can differ because of compilation, older cached files and SDK bookkeeping. These estimates require no network requests from Settings.

| Model | Download bytes | Metadata source and selection |
| --- | ---: | --- |
| Parakeet v3 Core ML | 586,061,111 | 483,257,242 for [v3 at 7dd20fe](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe), plus 102,803,869 for [CTC at accdafd](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml/tree/accdafd8cf8a2ff1cabe3c11e54416b405d409aa). |
| Parakeet v3 Intel int8 | 487,170,055 | [sherpa-onnx archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2), SHA-256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`. Exact pinned archive size. |
| Whisper Base English | 149,114,215 | 146,707,731 model + 2,406,484 tokenizer bytes. |
| Whisper Small | 220,113,912 | 217,350,763 model + 2,763,149 tokenizer bytes. |
| Whisper Medium | 1,532,417,382 | 1,529,654,233 model + 2,763,149 tokenizer bytes. |
| Whisper Large v3 Turbo | 629,481,698 | 626,718,238 model + 2,763,460 tokenizer bytes. |

Parakeet selection matches FluidAudio 0.17.4: `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, plus root JSON/text metadata. CTC selects `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc` and root JSON/text metadata.

Whisper model totals sum every file inside each `WhisperModel.rawValue` directory in [whisperkit-coreml at 0f63a78](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482). Each adds `tokenizer.json` and `tokenizer_config.json` from the revisions already pinned in `WhisperRecognizer.tokenizers`: [Base English](https://huggingface.co/openai/whisper-base.en/tree/911407f4214e0e1d82085af863093ec0b66f9cd6), [Small](https://huggingface.co/openai/whisper-small/tree/973afd24965f72e36ca33b3055d56a652f456b4d), [Medium](https://huggingface.co/openai/whisper-medium/tree/abdf7c39ab9d0397620ccaea8974cc764cd0953e), [Large v3](https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1).
