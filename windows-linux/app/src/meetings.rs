//! Meeting recording: microphone and system audio are written to separate
//! WAV tracks only after an explicit Start, then transcribed afterwards into one timestamped transcript.
//! Windows captures system audio with WASAPI loopback; Linux uses PipeWire's `pw-record` on the sink.

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread::JoinHandle;

/// Two hours, like the Mac app.
const MAX_SECONDS: u64 = 7_200;

pub fn root() -> PathBuf {
    dirs::document_dir().unwrap_or_else(|| dirs::home_dir().unwrap_or_default()).join("Mouthy Meetings")
}

/// Streams one cpal device to a mono 16-bit WAV file on a writer thread.
struct Track { stop: mpsc::Sender<()>, thread: Option<JoinHandle<Result<()>>> }

impl Track {
    fn start(device: cpal::Device, path: PathBuf) -> Result<Self> {
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<()>>();
        let thread = std::thread::spawn(move || -> Result<()> {
            let config = match device.default_input_config().or_else(|_| device.default_output_config()) {
                Ok(c) => c,
                Err(e) => { let _ = ready_tx.send(Err(e.into())); return Ok(()); }
            };
            let rate = config.sample_rate().0;
            let channels = config.channels() as usize;
            let spec = hound::WavSpec { channels: 1, sample_rate: rate, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
            let (tx, rx) = mpsc::sync_channel::<Vec<i16>>(256);
            let writer_path = path.clone();
            let limit = rate as u64 * MAX_SECONDS;
            let writer = std::thread::spawn(move || -> Result<()> {
                let mut wav = hound::WavWriter::create(writer_path, spec)?;
                let mut written = 0u64;
                for block in rx {
                    for s in block { if written < limit { wav.write_sample(s)?; written += 1; } }
                }
                wav.finalize()?;
                Ok(())
            });
            let send = move |mono: Vec<i16>| { let _ = tx.try_send(mono); };
            let error = |e| eprintln!("Mouthy meeting audio error: {e}");
            let stream = match config.sample_format() {
                cpal::SampleFormat::F32 => device.build_input_stream(&config.into(), move |d: &[f32], _: &_| {
                    send(d.chunks(channels).map(|f| ((f.iter().sum::<f32>() / channels as f32).clamp(-1.0, 1.0) * 32767.0) as i16).collect())
                }, error, None),
                cpal::SampleFormat::I16 => device.build_input_stream(&config.into(), move |d: &[i16], _: &_| {
                    send(d.chunks(channels).map(|f| (f.iter().map(|&s| s as i32).sum::<i32>() / channels as i32) as i16).collect())
                }, error, None),
                other => { let _ = ready_tx.send(Err(anyhow!("Unsupported audio format {other:?}"))); return Ok(()); }
            };
            match stream.map_err(anyhow::Error::from).and_then(|s| { s.play()?; Ok(s) }) {
                Ok(stream) => { let _ = ready_tx.send(Ok(())); let _ = stop_rx.recv(); drop(stream); }
                Err(e) => { let _ = ready_tx.send(Err(e)); }
            }
            writer.join().map_err(|_| anyhow!("writer stopped"))?
        });
        ready_rx.recv().map_err(|_| anyhow!("Audio capture did not start."))??;
        Ok(Self { stop: stop_tx, thread: Some(thread) })
    }
    fn finish(mut self) -> Result<()> {
        let _ = self.stop.send(());
        self.thread.take().map(|t| t.join().map_err(|_| anyhow!("capture stopped"))?).unwrap_or(Ok(()))
    }
}

#[allow(dead_code)]
enum System { Track(Track), Process(std::process::Child), None }

pub struct Meeting { pub dir: PathBuf, mic: Track, system: System }

impl Meeting {
    pub fn start(mic_device: &str) -> Result<Self> {
        let stamp = chrono_stamp();
        let dir = root().join(format!("Meeting {stamp}"));
        // Recordings and transcripts stay readable by this user only.
        crate::store::private_dir(&root())?;
        crate::store::private_dir(&dir)?;
        let host = cpal::default_host();
        let mic = if mic_device.is_empty() { host.default_input_device() } else {
            host.input_devices()?.find(|d| d.name().map(|n| n == mic_device).unwrap_or(false)).or_else(|| host.default_input_device())
        }.ok_or_else(|| anyhow!("No microphone is available."))?;
        let mic = Track::start(mic, dir.join("microphone.wav"))?;
        let system = start_system(&dir.join("system.wav"));
        Ok(Self { dir, mic, system })
    }
    pub fn has_system_audio(&self) -> bool { !matches!(self.system, System::None) }
    pub fn stop(self) -> Result<PathBuf> {
        self.mic.finish()?;
        match self.system {
            System::Track(t) => { let _ = t.finish(); }
            System::Process(mut child) => {
                #[cfg(unix)]
                unsafe { libc_kill(child.id() as i32); }
                let _ = child.wait();
            }
            System::None => {}
        }
        Ok(self.dir)
    }
}

#[cfg(unix)]
unsafe fn libc_kill(pid: i32) {
    extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
    kill(pid, 2); // SIGINT lets pw-record finalize the WAV header
}

#[cfg(windows)]
fn start_system(path: &Path) -> System {
    // WASAPI: an input stream on the default output device is a loopback capture.
    cpal::default_host().default_output_device()
        .and_then(|d| Track::start(d, path.to_path_buf()).ok())
        .map(System::Track).unwrap_or(System::None)
}

#[cfg(target_os = "linux")]
fn start_system(path: &Path) -> System {
    std::process::Command::new("pw-record")
        .args(["-P", "{ stream.capture.sink = true }", "--channels", "1", "--rate", "48000"])
        .arg(path)
        .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
        .spawn().map(System::Process).unwrap_or(System::None)
}

#[cfg(target_os = "macos")]
fn start_system(_: &Path) -> System { System::None }

fn chrono_stamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    // Civil date from Unix days (UTC), avoiding a date dependency.
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02} {:02}.{:02}.{:02} UTC", rem / 3600, rem % 3600 / 60, rem % 60)
}

/// Lists recorded meetings, newest first, with whether a transcript exists.
pub fn list() -> Vec<(String, String, bool)> {
    let mut items: Vec<(String, String, bool)> = std::fs::read_dir(root()).map(|d| d.filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path().to_string_lossy().into_owned(), e.path().join("transcript.txt").exists()))
        .collect()).unwrap_or_default();
    items.sort_by(|a, b| b.0.cmp(&a.0));
    items
}

/// Splits long audio near quiet moments into chunks of at most `max` samples.
pub fn chunks(samples: &[f32], max: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = 0;
    let frame = 1_600; // 100 ms at 16 kHz
    while start < samples.len() {
        let mut end = (start + max).min(samples.len());
        if end < samples.len() {
            let search_from = end.saturating_sub(frame * 50).max(start + frame);
            let mut best = (f32::MAX, end);
            let mut i = search_from;
            while i + frame <= end {
                let energy: f32 = samples[i..i + frame].iter().map(|v| v * v).sum();
                if energy < best.0 { best = (energy, i + frame / 2); }
                i += frame;
            }
            end = best.1;
        }
        out.push((start, end));
        start = end;
    }
    out
}

/// Transcribes both tracks with `recognize` and writes transcript.txt with [hh:mm:ss] labels.
pub fn transcribe(dir: &Path, recognize: &mut dyn FnMut(&[f32]) -> String) -> Result<PathBuf> {
    let mut lines: Vec<(usize, String)> = Vec::new();
    for (file, label) in [("microphone.wav", "You"), ("system.wav", "Others")] {
        let path = dir.join(file);
        if !path.exists() { continue; }
        let samples = crate::audio::read_wav(&path)?;
        for (start, end) in chunks(&samples, 16_000 * 25) {
            let text = recognize(&samples[start..end]);
            if !text.trim().is_empty() { lines.push((start, format!("{label}: {}", text.trim()))); }
        }
    }
    lines.sort_by_key(|l| l.0);
    let body: String = lines.iter().map(|(at, line)| {
        let s = at / 16_000;
        format!("[{:02}:{:02}:{:02}] {line}\n", s / 3600, s % 3600 / 60, s % 60)
    }).collect();
    let out = dir.join("transcript.txt");
    std::fs::write(&out, if body.is_empty() { "No speech was detected.\n".to_string() } else { body })?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_cover_audio_and_prefer_quiet_cuts() {
        let mut samples = vec![0.5f32; 16_000 * 60];
        for s in &mut samples[16_000 * 22..16_000 * 22 + 3_200] { *s = 0.0; }
        let parts = chunks(&samples, 16_000 * 25);
        assert_eq!(parts.first().unwrap().0, 0);
        assert_eq!(parts.last().unwrap().1, samples.len());
        assert!(parts[0].1 > 16_000 * 22 && parts[0].1 < 16_000 * 22 + 3_200);
        assert!(parts.windows(2).all(|w| w[0].1 == w[1].0));
    }
    #[test]
    fn stamp_looks_like_a_date() {
        let s = chrono_stamp();
        assert!(s.starts_with("20") && s.ends_with("UTC"), "{s}");
    }
}

/// `MOUTHY_TEST_MODELS=1 MOUTHY_TEST_WAV=speech.wav cargo test --release -p mouthy-app real_meeting -- --nocapture`
#[cfg(test)]
mod real {
    #[test]
    fn real_meeting_transcript() {
        if std::env::var("MOUTHY_TEST_MODELS").as_deref() != Ok("1") { return; }
        let dir = std::env::temp_dir().join("mouthy-meeting-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::copy(std::env::var("MOUTHY_TEST_WAV").unwrap(), dir.join("microphone.wav")).unwrap();
        let mut loaded = crate::asr::load(mouthy_core::SpeechEngine::Parakeet, "", "en").unwrap();
        let file = super::transcribe(&dir, &mut |s| crate::asr::transcribe(&mut loaded, s)).unwrap();
        let text = std::fs::read_to_string(file).unwrap();
        println!("{text}");
        assert!(text.starts_with("[00:00:00] You: ") && text.contains("garden"));
    }
}
