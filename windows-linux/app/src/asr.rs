//! Local recognition with sherpa-onnx: NVIDIA Parakeet TDT v3 and OpenAI Whisper models, downloaded
//! once from the sherpa-onnx releases and run fully offline afterwards.

use anyhow::{anyhow, bail, Context, Result};
use sherpa_rs::transducer::{TransducerConfig, TransducerRecognizer};
use sherpa_rs::whisper::{WhisperConfig, WhisperRecognizer};
use std::path::{Path, PathBuf};
use mouthy_core::SpeechEngine;

const RELEASES: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models";
pub const PARAKEET: &str = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
pub const WHISPER_MODELS: &[(&str, &str)] = &[
    ("tiny.en", "Tiny English (fastest)"),
    ("base.en", "Base English"),
    ("small", "Small (multilingual)"),
    ("medium", "Medium (multilingual)"),
    ("turbo", "Turbo (multilingual)"),
];

pub fn models_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Mouthy").join("models")
}

pub fn archive_name(engine: SpeechEngine, whisper: &str) -> String {
    match engine {
        SpeechEngine::Parakeet => PARAKEET.to_string(),
        SpeechEngine::Whisper => format!("sherpa-onnx-whisper-{whisper}"),
    }
}

pub fn installed(engine: SpeechEngine, whisper: &str) -> bool {
    files(engine, whisper).is_ok()
}

fn find(dir: &Path, suffix: &str) -> Result<String> {
    let mut matches: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(suffix)))
        .collect();
    // Prefer int8 weights when both precisions ship.
    matches.sort_by_key(|p| !p.to_string_lossy().contains("int8"));
    matches.first().map(|p| p.to_string_lossy().into_owned()).ok_or_else(|| anyhow!("missing {suffix}"))
}

enum Files {
    Parakeet { encoder: String, decoder: String, joiner: String, tokens: String },
    Whisper { encoder: String, decoder: String, tokens: String },
}

fn files(engine: SpeechEngine, whisper: &str) -> Result<Files> {
    let dir = models_dir().join(archive_name(engine, whisper));
    Ok(match engine {
        SpeechEngine::Parakeet => Files::Parakeet {
            encoder: find(&dir, "encoder.int8.onnx").or_else(|_| find(&dir, "encoder.onnx"))?,
            decoder: find(&dir, "decoder.int8.onnx").or_else(|_| find(&dir, "decoder.onnx"))?,
            joiner: find(&dir, "joiner.int8.onnx").or_else(|_| find(&dir, "joiner.onnx"))?,
            tokens: find(&dir, "tokens.txt")?,
        },
        SpeechEngine::Whisper => Files::Whisper {
            encoder: find(&dir, "encoder.int8.onnx").or_else(|_| find(&dir, "encoder.onnx"))?,
            decoder: find(&dir, "decoder.int8.onnx").or_else(|_| find(&dir, "decoder.onnx"))?,
            tokens: find(&dir, "tokens.txt")?,
        },
    })
}

/// Downloads and unpacks a model archive. `progress` receives 0…1.
/// SHA-256 of each release archive, pinned 2026-10-04 so a replaced upstream asset is refused.
pub const ARCHIVE_SHA256: &[(&str, &str)] = &[
    ("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"),
    ("sherpa-onnx-whisper-tiny.en", "2bd6cf965c8bb3e068ef9fa2191387ee63a9dfa2a4e37582a8109641c20005dd"),
    ("sherpa-onnx-whisper-base.en", "475bc7052ce299c007f6d5d5407ba8601f819a2867f6eecee510ed17df581542"),
    ("sherpa-onnx-whisper-small", "486a46afbb7ba798507190ffe02fea2dd726049af212e774537efac6afb210a6"),
    ("sherpa-onnx-whisper-medium", "614b1172557049069d846c29d9399640bce83a4dd6c580decebd9ce2a4f32c33"),
    ("sherpa-onnx-whisper-turbo", "b11acbbcd660b44a8e0df33724feb5aaa709cf65668f2823d59f656312544f22"),
];

pub fn download(engine: SpeechEngine, whisper: &str, progress: impl Fn(f32)) -> Result<()> {
    let name = archive_name(engine, whisper);
    let expected = ARCHIVE_SHA256.iter().find(|(n, _)| *n == name).map(|(_, h)| *h).context("No checksum is known for this model")?;
    let root = models_dir();
    std::fs::create_dir_all(&root)?;
    let response = ureq::get(&format!("{RELEASES}/{name}.tar.bz2")).call().context("Model download failed")?;
    let total: u64 = response.header("Content-Length").and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut reader = Progress { inner: response.into_reader(), read: 0, total, progress, hash: sha2::Sha256::default() };
    let staging = root.join(format!(".{name}.partial"));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let checked = (|| -> Result<()> {
        // The checksum is known only at the end, so unpack defensively: plain files and folders only
        // (no links), each confined to the staging folder (`unpack_in` refuses `..` and absolute paths).
        let mut archive = tar::Archive::new(bzip2::read::BzDecoder::new(&mut reader));
        archive.set_preserve_permissions(false);
        for entry in archive.entries().context("Model archive could not be unpacked")? {
            let mut entry = entry.context("Model archive could not be unpacked")?;
            if !matches!(entry.header().entry_type(), tar::EntryType::Regular | tar::EntryType::Directory) { continue; }
            if !entry.unpack_in(&staging).context("Model archive could not be unpacked")? { bail!("The model archive tried to write outside its folder; nothing was changed."); }
        }
        std::io::copy(&mut reader, &mut std::io::sink())?;
        use sha2::Digest;
        let actual: String = std::mem::take(&mut reader.hash).finalize().iter().map(|b| format!("{b:02x}")).collect();
        if actual != expected { bail!("The downloaded model did not match its expected checksum; nothing was changed."); }
        Ok(())
    })();
    if let Err(error) = checked { let _ = std::fs::remove_dir_all(&staging); return Err(error); }
    let unpacked = staging.join(&name);
    let source = if unpacked.exists() { unpacked } else { staging.clone() };
    // Swap only after the new copy checked out, keeping the old one until then.
    let target = root.join(&name);
    let old = root.join(format!(".{name}.old"));
    let _ = std::fs::remove_dir_all(&old);
    let had_old = std::fs::rename(&target, &old).is_ok();
    if let Err(error) = std::fs::rename(&source, &target) {
        if had_old { let _ = std::fs::rename(&old, &target); }
        let _ = std::fs::remove_dir_all(&staging);
        return Err(error.into());
    }
    let _ = std::fs::remove_dir_all(&staging);
    if !installed(engine, whisper) {
        let _ = std::fs::remove_dir_all(&target);
        if had_old { let _ = std::fs::rename(&old, &target); }
        bail!("The downloaded model is incomplete.");
    }
    let _ = std::fs::remove_dir_all(&old);
    Ok(())
}

struct Progress<R, F: Fn(f32)> { inner: R, read: u64, total: u64, progress: F, hash: sha2::Sha256 }
impl<R: std::io::Read, F: Fn(f32)> std::io::Read for Progress<R, F> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        sha2::Digest::update(&mut self.hash, &buf[..n]);
        self.read += n as u64;
        if self.total > 0 && (self.read % (1 << 20) < n as u64 || n == 0) {
            (self.progress)(self.read as f32 / self.total as f32);
        }
        Ok(n)
    }
}

/// A loaded recognizer, kept between dictations and released when the engine changes.
pub enum Recognizer {
    Parakeet(TransducerRecognizer),
    Whisper(WhisperRecognizer),
}
// sherpa-onnx recognizers are used from one thread at a time behind a mutex.
unsafe impl Send for Recognizer {}

pub struct Loaded {
    pub key: String,
    pub recognizer: Recognizer,
}

pub fn load(engine: SpeechEngine, whisper: &str, language: &str) -> Result<Loaded> {
    let threads = std::thread::available_parallelism().map(|n| n.get().min(8) as i32).unwrap_or(4);
    let key = format!("{}|{language}", archive_name(engine, whisper));
    let recognizer = match files(engine, whisper).context("Download the speech model in Settings first.")? {
        Files::Parakeet { encoder, decoder, joiner, tokens } => Recognizer::Parakeet(TransducerRecognizer::new(TransducerConfig {
            encoder, decoder, joiner, tokens,
            model_type: "nemo_transducer".into(),
            num_threads: threads,
            sample_rate: 16_000,
            feature_dim: 80,
            decoding_method: "greedy_search".into(),
            ..Default::default()
        }).map_err(|e| anyhow!("{e}"))?),
        Files::Whisper { encoder, decoder, tokens } => Recognizer::Whisper(WhisperRecognizer::new(WhisperConfig {
            encoder, decoder, tokens,
            language: if language.is_empty() || language == "auto" { String::new() } else { language.into() },
            num_threads: Some(threads),
            ..Default::default()
        }).map_err(|e| anyhow!("{e}"))?),
    };
    Ok(Loaded { key, recognizer })
}

pub fn transcribe(loaded: &mut Loaded, samples: &[f32]) -> String {
    if samples.len() < 1_600 || !should_decode(samples) {
        return String::new();
    }
    match &mut loaded.recognizer {
        Recognizer::Parakeet(r) => r.transcribe(16_000, samples).trim().to_string(),
        // Only Whisper emits non-speech annotations.
        Recognizer::Whisper(r) => clean(&r.transcribe(16_000, samples).text),
    }
}

/// 20 ms analysis frames at 16 kHz, matching the Mac's `SpeechPauses.frame`.
const FRAME: usize = 320;
/// Loud frames in a row before they count as speech: key clicks (the stop shortcut), taps and pops
/// are shorter, and recognizers turn them into words like "Yeah".
const MINIMUM_RUN: usize = 3;
/// Speech needed in a leftover before it is worth recognizing at all.
const MINIMUM_SPEECH_FRAMES: usize = 8;
/// A frame clearly above the room's noise floor is "loud".
const SPEECH_THRESHOLD: f32 = 0.004;
/// A frame below this is silence, not soft voice.
const NOISE_FLOOR: f32 = 0.002;

fn frame_rms(samples: &[f32]) -> f32 {
    let energy: f32 = samples.iter().map(|v| v * v).sum();
    (energy / samples.len() as f32).sqrt()
}

/// Whether `samples` hold real speech: enough loud frames in runs long enough to be voice, not a
/// click or a breath. Mirrors the Mac's `SpeechPauses.hasSpeech`.
fn has_speech(samples: &[f32]) -> bool {
    let mut start = 0;
    let mut run = 0;
    let mut frames = 0;
    while start + FRAME <= samples.len() {
        if frame_rms(&samples[start..start + FRAME]) > SPEECH_THRESHOLD {
            run += 1;
            if run == MINIMUM_RUN { frames += run; } else if run > MINIMUM_RUN { frames += 1; }
            if frames >= MINIMUM_SPEECH_FRAMES { return true; }
        } else {
            run = 0;
        }
        start += FRAME;
    }
    false
}

/// Whether a run of `MINIMUM_RUN` loud frames ever occurred: sustained loud sound such as voice or
/// loud music. A click never reaches a three-frame run, so it is not "heard speech".
fn heard_speech(samples: &[f32]) -> bool {
    let mut start = 0;
    let mut run = 0;
    while start + FRAME <= samples.len() {
        if frame_rms(&samples[start..start + FRAME]) > SPEECH_THRESHOLD {
            run += 1;
            if run >= MINIMUM_RUN { return true; }
        } else {
            run = 0;
        }
        start += FRAME;
    }
    false
}

/// A voice too quiet to cross the loud threshold: its frames still carry energy above the noise
/// floor. Loud frames are ignored (here they are only clicks, because `should_decode` calls this
/// after `heard_speech` is false), so a click pair over silence is not a soft voice.
fn soft_voice(samples: &[f32]) -> bool {
    let mut energy = 0.0f64;
    let mut count = 0usize;
    let mut start = 0;
    while start + FRAME <= samples.len() {
        let rms = frame_rms(&samples[start..start + FRAME]);
        if rms <= SPEECH_THRESHOLD {
            energy += (rms as f64) * (rms as f64);
            count += 1;
        }
        start += FRAME;
    }
    count > 0 && (energy / count as f64).sqrt() as f32 > NOISE_FLOOR
}

/// Whether leftover audio is worth decoding at all: real speech, or a soft voice the loud threshold
/// missed. Key clicks and short noises are neither, so they never become words.
fn should_decode(samples: &[f32]) -> bool {
    if has_speech(samples) { return true; }
    if heard_speech(samples) { return false; }
    soft_voice(samples)
}

/// Drops Whisper's non-speech annotations such as "[BLANK_AUDIO]" or "(music)".
fn clean(text: &str) -> String {
    let re = regex_lite(text);
    re.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn regex_lite(text: &str) -> String {
    let mut out = String::new();
    let mut depth = 0;
    for c in text.chars() {
        match c {
            '[' | '(' => depth += 1,
            ']' | ')' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn annotations_are_removed() {
        assert_eq!(super::clean(" [BLANK_AUDIO] Hello (music) world "), "Hello world");
    }
    #[test]
    fn every_model_has_a_checksum() {
        use super::*;
        let mut names = vec![archive_name(SpeechEngine::Parakeet, "")];
        names.extend(WHISPER_MODELS.iter().map(|(m, _)| archive_name(SpeechEngine::Whisper, m)));
        for name in names { assert!(ARCHIVE_SHA256.iter().any(|(n, h)| *n == name && h.len() == 64), "{name}"); }
    }

    // A steady level, so amplitude equals RMS and each case is exact.
    fn level(seconds: f64, rms: f32) -> Vec<f32> {
        (0..(seconds * 16_000.0) as usize).map(|_| rms).collect()
    }

    #[test]
    fn speech_is_decoded() {
        use super::*;
        assert!(has_speech(&level(0.3, 0.05)));
        assert!(should_decode(&level(0.3, 0.05)));
    }

    // A 20 ms click pair must produce no words: clicks never reach a three-frame run.
    #[test]
    fn a_click_pair_is_not_decoded() {
        use super::*;
        let clicks = [level(0.4, 0.0), level(0.02, 0.3), level(0.15, 0.0), level(0.02, 0.3), level(0.1, 0.0)].concat();
        assert!(!has_speech(&clicks));
        assert!(!should_decode(&clicks));
    }

    // A soft voice with a click on top still decodes: the click is a short run, so it must not
    // silence the soft-voice fallback.
    #[test]
    fn a_soft_voice_with_a_click_is_decoded() {
        use super::*;
        let soft = [level(1.0, 0.003), level(0.04, 0.5)].concat();
        assert!(!has_speech(&soft));
        assert!(should_decode(&soft));
    }

    #[test]
    fn silence_is_not_decoded() {
        use super::*;
        assert!(!should_decode(&level(1.0, 0.0)));
    }
}

/// Real-model check: `MOUTHY_TEST_MODELS=1 MOUTHY_TEST_WAV=speech.wav cargo test -p mouthy-app real_models -- --nocapture`.
#[cfg(test)]
mod real {
    use super::*;
    #[test]
    fn real_models_recognize_speech_and_silence() {
        if std::env::var("MOUTHY_TEST_MODELS").as_deref() != Ok("1") { return; }
        let wav = std::env::var("MOUTHY_TEST_WAV").expect("MOUTHY_TEST_WAV");
        let samples = crate::audio::read_wav(Path::new(&wav)).unwrap();
        for (engine, id) in [(SpeechEngine::Parakeet, ""), (SpeechEngine::Whisper, "base.en")] {
            if !installed(engine, id) { download(engine, id, |_| {}).unwrap(); }
            let mut loaded = load(engine, id, "en").unwrap();
            let started = std::time::Instant::now();
            let text = transcribe(&mut loaded, &samples);
            println!("{engine:?}: {text:?} in {:?}", started.elapsed());
            assert!(text.to_lowercase().contains("garden"), "{text}");
            assert_eq!(transcribe(&mut loaded, &vec![0.0; 32_000]), "");
        }
    }
}
