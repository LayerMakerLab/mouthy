//! Microphone capture: any input format → 16 kHz mono f32, with a live level for the overlay.
//! The cpal stream is not `Send`, so it lives on its own thread until stopped.

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub const SAMPLE_RATE: u32 = 16_000;
/// Ten minutes, matching the Mac app's local-engine cap.
const MAX_SECONDS: usize = 600;

/// A running RMS window. Audio callbacks need only two numbers, not a second sample buffer.
struct LevelMeter {
    length: usize,
    count: usize,
    energy: f32,
}

impl LevelMeter {
    fn new(length: usize) -> Self { Self { length: length.max(1), count: 0, energy: 0.0 } }

    fn push(&mut self, sample: f32) -> Option<f32> {
        self.energy += sample * sample;
        self.count += 1;
        if self.count < self.length { return None; }
        let rms = (self.energy / self.count as f32).sqrt();
        self.count = 0;
        self.energy = 0.0;
        Some(rms)
    }
}

pub struct Recording {
    stop: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
    samples: Arc<Mutex<Vec<f32>>>,
    rate: u32,
    pub device_name: String,
}

pub fn input_devices() -> Vec<String> {
    cpal::default_host().input_devices().map(|d| d.filter_map(|d| d.name().ok()).collect()).unwrap_or_default()
}

impl Recording {
    /// Starts capturing. `level` receives RMS levels (0…1) about every 50 ms.
    pub fn start(device: &str, level: impl Fn(f32) + Send + 'static) -> Result<Self> {
        let host = cpal::default_host();
        let device = if device.is_empty() {
            host.default_input_device()
        } else {
            host.input_devices()?.find(|d| d.name().map(|n| n == device).unwrap_or(false)).or_else(|| host.default_input_device())
        }
        .ok_or_else(|| anyhow!("No microphone is available."))?;
        let device_name = device.name().unwrap_or_else(|_| "Microphone".into());
        let config = device.default_input_config()?;
        let rate = config.sample_rate().0;
        let channels = config.channels() as usize;
        let samples = Arc::new(Mutex::new(Vec::<f32>::with_capacity(rate as usize * 30)));
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<()>>();
        let sink = samples.clone();
        let limit = rate as usize * MAX_SECONDS;
        let thread = std::thread::spawn(move || {
            let mut meter = LevelMeter::new((rate / 20) as usize);
            let mut push = move |mono: &mut dyn Iterator<Item = f32>| {
                let mut latest = None;
                let mut buffer = sink.lock();
                for s in mono {
                    if buffer.len() < limit {
                        buffer.push(s);
                    }
                    if let Some(rms) = meter.push(s) {
                        if rms > 0.02 { crate::enter_key::HEARD.store(true, std::sync::atomic::Ordering::SeqCst); }
                        latest = Some((rms * 4.0).min(1.0));
                    }
                }
                // Webview IPC must not hold up a snapshot/split waiting for the capture buffer.
                drop(buffer);
                if let Some(value) = latest { level(value); }
            };
            let error = |e| eprintln!("Mouthy audio error: {e}");
            let stream = match config.sample_format() {
                cpal::SampleFormat::F32 => device.build_input_stream(&config.into(), move |data: &[f32], _: &_| {
                    push(&mut data.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32))
                }, error, None),
                cpal::SampleFormat::I16 => device.build_input_stream(&config.into(), move |data: &[i16], _: &_| {
                    push(&mut data.chunks(channels).map(|f| f.iter().map(|&s| s as f32 / 32768.0).sum::<f32>() / channels as f32))
                }, error, None),
                cpal::SampleFormat::U16 => device.build_input_stream(&config.into(), move |data: &[u16], _: &_| {
                    push(&mut data.chunks(channels).map(|f| f.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).sum::<f32>() / channels as f32))
                }, error, None),
                other => { let _ = ready_tx.send(Err(anyhow!("Unsupported microphone format {other:?}."))); return; }
            };
            match stream.map_err(anyhow::Error::from).and_then(|s| { s.play()?; Ok(s) }) {
                Ok(stream) => {
                    let _ = ready_tx.send(Ok(()));
                    let _ = stop_rx.recv();
                    drop(stream);
                }
                Err(e) => { let _ = ready_tx.send(Err(e)); }
            }
        });
        ready_rx.recv().map_err(|_| anyhow!("The microphone did not start."))??;
        Ok(Self { stop: stop_tx, thread: Some(thread), samples, rate, device_name })
    }

    /// Hands over the audio so far (16 kHz mono) and keeps recording into an empty buffer.
    pub fn take(&self) -> Vec<f32> {
        let taken = std::mem::take(&mut *self.samples.lock());
        resample_owned(taken, self.rate, SAMPLE_RATE)
    }

    /// The audio so far as 16 kHz mono, only while it fits the live preview's budget.
    pub fn snapshot(&self, max_seconds: usize) -> Option<Vec<f32>> {
        let copy = {
            let samples = self.samples.lock();
            if samples.len() > self.rate as usize * max_seconds { return None; }
            samples.clone()
        };
        Some(resample_owned(copy, self.rate, SAMPLE_RATE))
    }

    /// Stops capture and returns 16 kHz mono samples. `cut_at`, when set, marks when the stop was
    /// requested; audio recorded after it (key clicks, music resuming) is dropped before recognition.
    pub fn finish(mut self, cut_at: Option<Instant>) -> Vec<f32> {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() { let _ = thread.join(); }
        let recorded_until = Instant::now();
        let samples = std::mem::take(&mut *self.samples.lock());
        let samples = resample_owned(samples, self.rate, SAMPLE_RATE);
        match cut_at {
            Some(cut_at) => trim(samples, recorded_until, cut_at, SAMPLE_RATE),
            None => samples,
        }
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() { let _ = thread.join(); }
    }
}

/// Drops the audio recorded after `cut_at`, at most 2 s (a stuck clock must never eat a dictation).
pub fn trim(mut samples: Vec<f32>, recorded_until: Instant, cut_at: Instant, rate: u32) -> Vec<f32> {
    let extra = recorded_until.saturating_duration_since(cut_at).min(Duration::from_secs(2));
    let drop = ((extra.as_secs_f64() * rate as f64) as usize).min(samples.len());
    samples.truncate(samples.len() - drop);
    samples
}

/// Transfers a buffer that is already at the recognizer's rate without copying the recording again.
fn resample_owned(input: Vec<f32>, from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() { input } else { resample(&input, from, to) }
}

/// Linear resampling; adequate for speech recognition input.
pub fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let len = (input.len() as f64 / ratio) as usize;
    (0..len)
        .map(|i| {
            let pos = i as f64 * ratio;
            let index = pos as usize;
            let frac = (pos - index as f64) as f32;
            let a = input[index];
            let b = *input.get(index + 1).unwrap_or(&a);
            a + (b - a) * frac
        })
        .collect()
}

/// Reads a WAV file as 16 kHz mono (for file transcription and tests).
pub fn read_wav(path: &std::path::Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    let channels = spec.channels as usize;
    let raw: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<_, _>>()?,
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader.samples::<i32>().map(|s| s.map(|v| v as f32 / scale)).collect::<Result<_, _>>()?
        }
    };
    let mono = if channels == 1 { raw } else { raw.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32).collect() };
    Ok(resample_owned(mono, spec.sample_rate, SAMPLE_RATE))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resample_halves_length() {
        let input: Vec<f32> = (0..32_000).map(|i| (i as f32 / 100.0).sin()).collect();
        assert_eq!(resample(&input, 32_000, 16_000).len(), 16_000);
    }

    #[test]
    fn meter_keeps_partial_windows_and_resets_after_each_reading() {
        let mut meter = LevelMeter::new(4);
        for sample in [0.1, -0.1, 0.1] { assert!(meter.push(sample).is_none()); }
        assert!((meter.push(-0.1).unwrap() - 0.1).abs() < 1e-6);
        for _ in 0..3 { assert!(meter.push(0.0).is_none()); }
        assert_eq!(meter.push(0.0), Some(0.0));
    }

    #[test]
    fn native_rate_and_stop_cut_reuse_the_recording_allocation() {
        let input = vec![0.25; 48_000];
        let allocation = input.as_ptr();
        let samples = resample_owned(input, SAMPLE_RATE, SAMPLE_RATE);
        assert_eq!(samples.as_ptr(), allocation);
        let cut = Instant::now();
        let samples = trim(samples, cut + Duration::from_millis(100), cut, SAMPLE_RATE);
        assert_eq!(samples.as_ptr(), allocation);
        assert_eq!(samples.len(), 46_400);
        assert!(samples.iter().all(|&sample| sample == 0.25));
    }

    // The stop shortcut's key clicks and music resuming after the stop must never reach the recognizer.
    #[test]
    fn trim_drops_audio_after_the_stop() {
        let samples: Vec<f32> = vec![0.1; 48_000]; // 3 s
        let cut = Instant::now();
        // Recording ended 0.4 s after the stop gesture began: the last 0.4 s goes.
        assert_eq!(trim(samples.clone(), cut + Duration::from_millis(400), cut, 16_000).len(), 48_000 - 6_400);
        // A stop requested after recording ended keeps everything.
        assert_eq!(trim(samples.clone(), cut, cut + Duration::from_millis(200), 16_000).len(), 48_000);
        // A wrong clock never eats more than 2 s.
        assert_eq!(trim(samples.clone(), cut + Duration::from_secs(400), cut, 16_000).len(), 48_000 - 32_000);
    }
}
