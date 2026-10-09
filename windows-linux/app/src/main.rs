//! Mouthy for Windows and Linux: press the shortcut, speak, press it again — the text is pasted into
//! the focused app. Local Parakeet/Whisper recognition, modes, spoken punctuation,
//! media muting, history and an MCP endpoint for AI agents.
#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod agent;
mod asr;
mod audio;
mod enter_key;
mod llm;
mod meetings;
mod platform;
mod store;

use parking_lot::Mutex;
use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use store::{AppSettings, HistoryEntry};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use mouthy_core::{DictationMode, MediaWhileDictating, OutputAction, SpeechEngine, WritingMode};

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
enum Phase { Idle, Listening, Finishing }

#[derive(Clone, Default)]
struct Session {
    app: platform::FocusedApp,
    mode: Option<DictationMode>,
    #[allow(dead_code)]
    started: Option<Instant>,
    muted: bool,
    paused: Vec<String>,
    agent: bool,
    /// The mode came from a window title, which a web page controls, so it may not press Return.
    mode_from_title: bool,
}

#[derive(Clone)]
enum Action { Toggle, Mode(uuid::Uuid), Cancel, PasteLast }

struct State {
    settings: Mutex<AppSettings>,
    recording: Mutex<Option<audio::Recording>>,
    phase: Mutex<Phase>,
    session: Mutex<Session>,
    recognizer: Mutex<Option<asr::Loaded>>,
    history: Mutex<Vec<HistoryEntry>>,
    last: Mutex<String>,
    status: Mutex<String>,
    agent: Mutex<Option<mpsc::Sender<String>>>,
    shortcuts: Mutex<Vec<(Shortcut, Action)>>,
    generation: AtomicU64,
    downloading: Mutex<Option<String>>,
    pressed: Mutex<Option<Instant>>,
    picked_mode: Mutex<Option<uuid::Uuid>>,
    splitting: std::sync::atomic::AtomicBool,
    meeting: Mutex<Option<meetings::Meeting>>,
    stats: Mutex<store::UsageStats>,
    segment_start: Mutex<Instant>,
}

fn state(app: &AppHandle) -> tauri::State<'_, State> { app.state::<State>() }

fn set_status(app: &AppHandle, text: impl Into<String>) {
    let text = text.into();
    *state(app).status.lock() = text.clone();
    let _ = app.emit("status", text);
}

/// Windows are created only when needed and destroyed afterwards, so an idle Mouthy runs no web view.
fn window(app: &AppHandle, label: &str) -> Option<tauri::WebviewWindow> {
    if let Some(existing) = app.get_webview_window(label) { return Some(existing); }
    let config = app.config().app.windows.iter().find(|w| w.label == label)?.clone();
    tauri::WebviewWindowBuilder::from_config(app, &config).ok()?.build().ok()
}

fn set_phase(app: &AppHandle, phase: Phase) {
    *state(app).phase.lock() = phase;
    let _ = app.emit("phase", phase);
    // The island hangs from the top center of the main display and only exists while Mouthy works.
    if phase == Phase::Idle || !state(app).settings.lock().show_overlay {
        // Let the check/attention mark and the slide back up finish, then destroy the web view.
        if app.get_webview_window("overlay").is_some() {
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(2_300));
                if *state(&app).phase.lock() == Phase::Idle { if let Some(o) = app.get_webview_window("overlay") { let _ = o.close(); } }
            });
        }
    } else {
        let app = app.clone();
        std::thread::spawn(move || {
        let Some(overlay) = window(&app, "overlay") else { return };
        if !overlay.is_visible().unwrap_or(false) {
            if let Ok(Some(monitor)) = app.primary_monitor() {
                let scale = monitor.scale_factor();
                let width = (160.0 * scale) as i32;
                let origin = monitor.position();
                let x = origin.x + (monitor.size().width as i32 - width) / 2;
                let _ = overlay.set_position(PhysicalPosition::new(x, origin.y));
                let _ = overlay.show();
                platform::place_overlay(x, origin.y, scale);
            } else {
                let _ = overlay.show();
            }
        }
        });
    }
}

fn beep(start: bool) {
    std::thread::spawn(move || {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let Some(device) = cpal::default_host().default_output_device() else { return };
        let Ok(config) = device.default_output_config() else { return };
        let rate = config.sample_rate().0 as f32;
        let channels = config.channels() as usize;
        let frequency = if start { 880.0 } else { 660.0 };
        let mut n = 0f32;
        let total = rate * 0.09;
        let Ok(stream) = device.build_output_stream(&config.into(), move |data: &mut [f32], _: &_| {
            for frame in data.chunks_mut(channels) {
                let envelope = if n < total { (1.0 - n / total) * 0.15 } else { 0.0 };
                let value = (n / rate * frequency * std::f32::consts::TAU).sin() * envelope;
                frame.iter_mut().for_each(|s| *s = value);
                n += 1.0;
            }
        }, |_| {}, None) else { return };
        if stream.play().is_ok() { std::thread::sleep(Duration::from_millis(160)); }
    });
}

// MARK: Dictation lifecycle

fn start(app: &AppHandle, mode_id: Option<uuid::Uuid>, agent: bool) {
    let st = state(app);
    {
        // Claim the session before the microphone starts so a second press cannot start another.
        let mut phase = st.phase.lock();
        if *phase != Phase::Idle { return; }
        *phase = Phase::Listening;
    }
    let settings = st.settings.lock().clone();
    let focused = platform::focused().unwrap_or_default();
    let mode_id = mode_id.or_else(|| st.picked_mode.lock().take());
    let mut mode_from_title = false;
    let mode = if agent { None } else {
        let url = focused.page_hint();
        let by_shortcut = mode_id.and_then(|id| settings.core.modes.iter().find(|m| m.id == id));
        let by_title = || url.as_deref().and_then(|title| settings.core.modes.iter().find(|m| m.websites.iter().any(|s| platform::title_matches_site(title, s))));
        by_shortcut
            .or_else(|| by_title().inspect(|_| mode_from_title = true))
            .or_else(|| mouthy_core::start_mode(&settings.core.modes, None, None, &focused.app))
            .cloned()
    };
    if settings.core.play_sounds { beep(true); }
    let generation = st.generation.fetch_add(1, Ordering::SeqCst) + 1;
    let level_app = app.clone();
    match audio::Recording::start(&settings.core.input_device, move |level| { let _ = level_app.emit_to("overlay", "level", level); }) {
        Ok(recording) => {
            let device = recording.device_name.clone();
            *st.recording.lock() = Some(recording);
            let mut session = Session { app: focused, mode: mode.clone(), started: Some(Instant::now()), agent, mode_from_title, ..Default::default() };
            if settings.core.play_sounds { std::thread::sleep(Duration::from_millis(120)); }
            match settings.core.media_while_dictating {
                MediaWhileDictating::Mute => if platform::output_muted() == Some(false) && platform::set_output_muted(true) { session.muted = true },
                MediaWhileDictating::Pause => session.paused = platform::pause_media(),
                MediaWhileDictating::Nothing => {}
            }
            *st.session.lock() = session;
            *st.segment_start.lock() = Instant::now();
            set_phase(app, Phase::Listening);
            let _ = app.global_shortcut().register(escape());
            let label = mode.map(|m| format!(" · {}", m.name)).unwrap_or_default();
            if !agent { set_status(app, format!("Listening on {device}{label}…")); }
            start_preview(app, generation);
            if !agent {
                enter_key::HEARD.store(false, Ordering::SeqCst);
                let enter_app = app.clone();
                enter_key::start(move || { let a = enter_app.clone(); std::thread::spawn(move || split(&a)); });
            }
            // Same ten-minute cap as the Mac app.
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(600));
                if state(&app).generation.load(Ordering::SeqCst) == generation && *state(&app).phase.lock() == Phase::Listening { stop(&app); }
            });
        }
        Err(error) => {
            *st.phase.lock() = Phase::Idle;
            set_status(app, format!("Microphone unavailable: {error}"));
            if let Some(reply) = st.agent.lock().take() { let _ = reply.send(format!("(Mouthy could not record: {error})")); }
        }
    }
}

/// Live text while speaking: re-decode the audio so far about every 1.5 s (up to 45 s). The first
/// pass also loads the model, so the final transcription starts warm.
fn start_preview(app: &AppHandle, generation: u64) {
    let app = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(1_500));
        let st = state(&app);
        if st.generation.load(Ordering::SeqCst) != generation || *st.phase.lock() != Phase::Listening { return; }
        let Some(samples) = st.recording.lock().as_ref().and_then(|r| r.snapshot(45)) else { return };
        if samples.len() < 8_000 { continue; }
        let settings = st.settings.lock().clone();
        let engine = st.session.lock().mode.as_ref().and_then(|m| m.engine).unwrap_or(settings.core.engine);
        let Ok(text) = recognize(&app, &samples, engine, &settings) else { return };
        if st.generation.load(Ordering::SeqCst) == generation && *st.phase.lock() == Phase::Listening && !text.is_empty() {
            let _ = app.emit("preview", text);
        }
    });
}

fn escape() -> Shortcut { "Escape".parse().expect("Escape shortcut") }

fn release_media(app: &AppHandle) {
    let st = state(app);
    let mut session = st.session.lock();
    if session.muted && platform::output_muted() == Some(true) { platform::set_output_muted(false); }
    session.muted = false;
    if !session.paused.is_empty() { platform::resume_media(&session.paused); session.paused.clear(); }
}

/// Enter while dictating: send what was said so far and keep listening.
fn deliver_split(remember: impl FnOnce(), paste: impl FnOnce() -> Result<(), String>, send: impl FnOnce() -> Result<(), String>,
                 current: impl Fn() -> bool, restore_binding: impl FnOnce()) -> Result<(), String> {
    if !current() { return Err("Cancelled. Nothing was inserted.".into()); }
    remember();
    let result = paste().map_err(|reason| format!("Ready to copy. {reason}")).and_then(|_| {
        if current() { send().map_err(|reason| format!("Pasted. Return was not sent: {reason}")) }
        else { Err("Pasted. Return was not sent because dictation was cancelled.".into()) }
    });
    if current() { restore_binding(); }
    result
}

#[cfg(test)]
mod split_tests {
    use super::deliver_split;
    use std::cell::{Cell, RefCell};

    #[test]
    fn split_restores_listening_after_refusal_but_never_after_cancellation() {
        for case in 0..4 {
            let active = Cell::new(true);
            let remembered = RefCell::new(String::new());
            let events = RefCell::new(Vec::new());
            let result = deliver_split(|| {
                *remembered.borrow_mut() = "recognized segment".into();
            }, || {
                assert_eq!(*remembered.borrow(), "recognized segment", "text is available before a paste can refuse it");
                events.borrow_mut().push("paste");
                if case == 3 { active.set(false); }
                if case == 0 { Err("protected field".into()) } else { Ok(()) }
            }, || {
                events.borrow_mut().push("return");
                if case == 1 { Err("focus changed".into()) } else { Ok(()) }
            }, || active.get(), || events.borrow_mut().push("restore"));
            let expected = match case {
                0 => vec!["paste", "restore"],
                3 => vec!["paste"],
                _ => vec!["paste", "return", "restore"],
            };
            assert_eq!(*events.borrow(), expected);
            assert_eq!(result.is_ok(), case == 2);
            assert_eq!(*remembered.borrow(), "recognized segment");
        }
    }

    #[test]
    fn a_cancelled_split_never_starts_delivery_or_rearms_enter() {
        let result = deliver_split(|| panic!("must not retain a cancelled result"), || panic!("must not paste"),
                                   || panic!("must not send"), || false, || panic!("must not rearm"));
        assert!(result.is_err());
    }
}

fn split(app: &AppHandle) {
    let st = state(app);
    if *st.phase.lock() != Phase::Listening || st.splitting.swap(true, Ordering::SeqCst) { return; }
    let generation = st.generation.load(Ordering::SeqCst);
    let samples = st.recording.lock().as_ref().map(|r| r.take()).unwrap_or_default();
    enter_key::HEARD.store(false, Ordering::SeqCst);
    let settings = st.settings.lock().clone();
    let session = st.session.lock().clone();
    let engine = session.mode.as_ref().and_then(|m| m.engine).unwrap_or(settings.core.engine);
    let result = (|| -> Result<String, String> {
        let raw = recognize(app, &samples, engine, &settings)?;
        let mut text = mouthy_core::process(&raw, &settings.core.replacements, settings.core.punctuation_commands);
        if settings.core.remove_fillers { text = mouthy_core::remove_fillers(&text); }
        if session.mode.as_ref().is_some_and(|m| m.code_dictation) { text = mouthy_core::code_dictation(&text); }
        if !text.chars().any(|c| c.is_alphanumeric()) { return Ok("Listening…".into()); }
        // Escape during recognition cancels the session; nothing may be pasted or sent after that.
        let current = || st.generation.load(Ordering::SeqCst) == generation && *st.phase.lock() == Phase::Listening;
        if !current() { return Ok("Cancelled. Nothing was inserted.".into()); }
        let mut target = platform::focused().unwrap_or_default();
        if target.is_self() && !session.app.is_self() { platform::focus(&session.app); target = session.app.clone(); }
        let text = fit_to_cursor(&text, &settings);
        // Hyprland must lift its binding for our Return. Windows already ignores injected keys and keeps its hook.
        if cfg!(target_os = "linux") { enter_key::stop(); }
        let sent = deliver_split(|| {
            // Keep recognized text available even when a secure or unreadable field refuses delivery.
            *st.last.lock() = text.clone();
            let _ = app.emit("result", &text);
        }, || {
            platform::paste(&text, &target)?;
            record_usage(app, &text);
            std::thread::sleep(Duration::from_millis(120));
            Ok(())
        }, || platform::press_return(&target), current, || {
            if cfg!(target_os = "linux") {
                // Serialize rearming against stop's transition out of Listening.
                let phase = st.phase.lock();
                if *phase == Phase::Listening && st.generation.load(Ordering::SeqCst) == generation {
                    let enter_app = app.clone();
                    enter_key::start(move || { let a = enter_app.clone(); std::thread::spawn(move || split(&a)); });
                }
            }
        });
        Ok(match sent {
            Ok(()) => "Sent. Still listening…".into(),
            Err(reason) => reason,
        })
    })();
    st.splitting.store(false, Ordering::SeqCst);
    set_status(app, result.unwrap_or_else(|e| e));
}

fn stop(app: &AppHandle) {
    let st = state(app);
    // The moment the person asked to stop: audio recorded after it is key clicks or music resuming.
    let cut_at = Instant::now();
    enter_key::stop();
    // Let an Enter split finish first so pieces arrive in order.
    for _ in 0..150 { if !st.splitting.load(Ordering::SeqCst) { break; } std::thread::sleep(Duration::from_millis(20)); }
    let Some(recording) = st.recording.lock().take() else { return };
    let _ = app.global_shortcut().unregister(escape());
    let samples = recording.finish(Some(cut_at));
    release_media(app);
    if st.settings.lock().core.play_sounds { beep(false); }
    set_phase(app, Phase::Finishing);
    // A split may have restored the Linux Enter binding while stop waited for it.
    enter_key::stop();
    set_status(app, "Transcribing on this computer…");
    let generation = st.generation.load(Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || {
        let result = finish(&app, samples, generation);
        if state(&app).generation.load(Ordering::SeqCst) != generation { return; }
        if let Err(error) = result { set_status(&app, error); }
        set_phase(&app, Phase::Idle);
    });
}

fn cancel(app: &AppHandle) {
    let st = state(app);
    enter_key::stop();
    st.generation.fetch_add(1, Ordering::SeqCst);
    let _ = app.global_shortcut().unregister(escape());
    let had = st.recording.lock().take().is_some();
    release_media(app);
    if let Some(reply) = st.agent.lock().take() { let _ = reply.send("(The user cancelled the spoken answer.)".into()); }
    if had || *st.phase.lock() != Phase::Idle {
        set_phase(app, Phase::Idle);
        // A split that was already rearming must finish before the Idle transition takes the phase lock.
        enter_key::stop();
        set_status(app, "Cancelled. Nothing was inserted.");
    }
}

fn toggle(app: &AppHandle, mode: Option<uuid::Uuid>) {
    let phase = *state(app).phase.lock();
    match phase {
        Phase::Idle => start(app, mode, false),
        Phase::Listening => stop(app),
        Phase::Finishing => {}
    }
}

fn recognize(app: &AppHandle, samples: &[f32], engine: SpeechEngine, settings: &AppSettings) -> Result<String, String> {
    let st = state(app);
    let mut slot = st.recognizer.lock();
    let key = format!("{}|{}", asr::archive_name(engine, &settings.core.whisper_model), settings.whisper_language);
    if slot.as_ref().map(|l| l.key != key).unwrap_or(true) {
        *slot = None;
        if *st.phase.lock() != Phase::Listening { set_status(app, "Loading the speech model…"); }
        *slot = Some(asr::load(engine, &settings.core.whisper_model, &settings.whisper_language).map_err(|e| e.to_string())?);
    }
    Ok(asr::transcribe(slot.as_mut().unwrap(), samples))
}

fn finish(app: &AppHandle, samples: Vec<f32>, generation: u64) -> Result<(), String> {
    let st = state(app);
    let settings = st.settings.lock().clone();
    let session = st.session.lock().clone();
    let engine = session.mode.as_ref().and_then(|m| m.engine).unwrap_or(settings.core.engine);
    let raw = recognize(app, &samples, engine, &settings)?;
    if st.generation.load(Ordering::SeqCst) != generation { return Ok(()); }
    if session.agent {
        let answer = mouthy_core::process(&raw, &settings.core.replacements, settings.core.punctuation_commands);
        if let Some(reply) = st.agent.lock().take() { let _ = reply.send(if answer.is_empty() { "(No speech was detected.)".into() } else { answer.clone() }); }
        *st.last.lock() = answer;
        set_status(app, "Answer sent to the agent.");
        return Ok(());
    }
    if raw.trim().is_empty() { set_status(app, "No speech detected. Nothing was inserted."); return Ok(()); }
    let mut mode = session.mode.clone();
    let mut spoken = raw.clone();
    // Speech only ever types: a mode chosen by a spoken trigger word (or by a page-controlled window
    // title) inserts but never presses Return.
    let mut may_submit = !session.mode_from_title;
    if let Some((matched, rest)) = mouthy_core::trigger(&raw, &settings.core.modes) { mode = Some(matched.clone()); spoken = rest; may_submit = false; }
    let (writing, custom, output) = match &mode {
        Some(m) if !m.instructions.trim().is_empty() => (WritingMode::Custom, m.instructions.clone(), m.output),
        Some(m) => (m.writing_mode, settings.custom_instructions.clone(), m.output),
        None => (settings.writing_mode, settings.custom_instructions.clone(), if settings.core.auto_insert { OutputAction::Insert } else { OutputAction::Clipboard }),
    };
    let output = if output == OutputAction::InsertAndReturn && !may_submit { OutputAction::Insert } else { output };
    let mut text = mouthy_core::process(&spoken, &settings.core.replacements, settings.core.punctuation_commands);
    if settings.core.remove_fillers { text = mouthy_core::remove_fillers(&text); }
    if mode.as_ref().is_some_and(|m| m.code_dictation) { text = mouthy_core::code_dictation(&text); }
    let mut note = String::new();
    if writing != WritingMode::Verbatim && !text.is_empty() {
        if settings.ollama_model.is_empty() {
            note = " Choose a local Ollama model in Settings for cleanup; original wording kept.".into();
        } else {
            set_status(app, "Refining on this computer…");
            let context = if mode.as_ref().is_some_and(|m| m.include_context) {
                let clip = arboard::Clipboard::new().ok().and_then(|mut c| c.get_text().ok()).unwrap_or_default();
                format!("App: {}\nWindow: {}\nClipboard: {}", session.app.app, session.app.title, clip.chars().take(500).collect::<String>())
            } else { String::new() };
            match llm::edit(&text, writing, &custom, &settings.ollama_model, &context) {
                Ok(edited) => text = edited,
                Err(_) => note = " Cleanup unavailable; original wording kept.".into(),
            }
        }
    }
    if st.generation.load(Ordering::SeqCst) != generation { return Ok(()); }
    *st.last.lock() = text.clone();
    let _ = app.emit("result", &text);
    if settings.core.keep_history || output == OutputAction::HistoryOnly {
        let entry = HistoryEntry {
            id: uuid::Uuid::new_v4().to_string(),
            date: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
            raw: raw.clone(), text: text.clone(), app: session.app.app.clone(),
            mode: mode.as_ref().map(|m| m.name.clone()).unwrap_or_else(|| "Main".into()),
            seconds: samples.len() as f32 / audio::SAMPLE_RATE as f32,
        };
        let mut history = st.history.lock();
        history.insert(0, entry);
        history.truncate(settings.core.history_limit.clamp(10, 1000));
        let _ = store::save("history.json", &*history);
        let _ = app.emit("history", ());
    }
    let status = match output {
        OutputAction::Clipboard => copy(&text).map(|_| "Copied to the clipboard.".to_string())?,
        OutputAction::HistoryOnly => "Saved to history.".into(),
        OutputAction::Insert | OutputAction::InsertAndReturn => {
            let mut target = platform::focused().unwrap_or_default();
            if target.is_self() && !session.app.is_self() {
                // Mouthy's own window took focus; return it to where dictation started.
                platform::focus(&session.app);
                target = session.app.clone();
            }
            if target.is_self() || target.pid == 0 && cfg!(windows) {
                copy(&text)?;
                "Ready. Copied, because no other app was focused.".into()
            } else {
                let text = fit_to_cursor(&text, &settings);
                platform::paste(&text, &target)?;
                record_usage(app, &text);
                let name = if target.app.is_empty() { "the focused app".to_string() } else { target.app.clone() };
                if output == OutputAction::InsertAndReturn {
                    std::thread::sleep(Duration::from_millis(120));
                    let sent = if st.generation.load(Ordering::SeqCst) == generation {
                        platform::press_return(&target)
                    } else { Err("the dictation was cancelled.".into()) };
                    match sent {
                        Ok(()) => format!("Pasted into {name} and sent with Return."),
                        Err(reason) => format!("Pasted into {name}. Return was not sent: {reason}"),
                    }
                } else {
                    format!("Pasted into {name}.")
                }
            }
        }
    };
    set_status(app, status + &note);
    Ok(())
}

/// Spacing and capitals from the text around the cursor, where the platform can read it.
fn fit_to_cursor(text: &str, settings: &AppSettings) -> String {
    if !settings.core.smart_formatting { return text.to_string(); }
    match platform::cursor_context() {
        Some((before, after)) => mouthy_core::smart_insertion(text, &before, &after),
        None => text.to_string(),
    }
}

/// Counts delivered words and the speaking time behind them.
fn record_usage(app: &AppHandle, text: &str) {
    let st = state(app);
    let seconds = std::mem::replace(&mut *st.segment_start.lock(), Instant::now()).elapsed().as_secs_f64();
    let mut stats = st.stats.lock();
    stats.record(text, seconds);
    let _ = store::save("stats.json", &*stats);
}

fn copy(text: &str) -> Result<(), String> {
    arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())).map_err(|e| e.to_string())
}

fn paste_last(app: &AppHandle) {
    let text = state(app).last.lock().clone();
    if text.is_empty() { set_status(app, "Nothing to paste yet."); return; }
    let app = app.clone();
    std::thread::spawn(move || {
        let target = platform::focused().unwrap_or_default();
        let result = if target.is_self() { copy(&text).map(|_| "Last result copied.".to_string()) } else { platform::paste(&text, &target).map(|_| "Pasted the last result.".to_string()) };
        set_status(&app, result.unwrap_or_else(|e| e));
    });
}

/// Records a spoken answer for an AI agent (blocks the calling HTTP thread).
fn ask(app: &AppHandle, questions: Vec<String>) -> String {
    let st = state(app);
    if !st.settings.lock().agent_voice { return "Spoken answers for agents are turned off in Mouthy settings.".into(); }
    if *st.phase.lock() != Phase::Idle || st.agent.lock().is_some() { return "Mouthy is busy with another dictation. Ask again in a moment.".into(); }
    let (tx, rx) = mpsc::channel();
    *st.agent.lock() = Some(tx);
    beep(true);
    set_status(app, format!("Agent question: {} — speak, then press your shortcut to send.", questions.join(" ")));
    start(app, None, true);
    rx.recv_timeout(Duration::from_secs(900)).unwrap_or_else(|_| "(No answer was given.)".into())
}

// MARK: Shortcuts

fn register_shortcuts(app: &AppHandle) -> Vec<String> {
    let st = state(app);
    let settings = st.settings.lock().clone();
    let shortcuts = app.global_shortcut();
    let _ = shortcuts.unregister_all();
    let mut table = Vec::new();
    let mut problems = Vec::new();
    let mut add = |text: &str, action: Action| match text.parse::<Shortcut>() {
        Ok(shortcut) => match shortcuts.register(shortcut) {
            Ok(()) => table.push((shortcut, action)),
            Err(error) => problems.push(format!("{text}: {error}")),
        },
        Err(_) => problems.push(format!("{text}: not a valid shortcut")),
    };
    add(&settings.core.shortcut, Action::Toggle);
    add("Ctrl+Super+V", Action::PasteLast);
    for mode in &settings.core.modes {
        if let Some(shortcut) = mode.shortcut.as_deref().filter(|s| !s.trim().is_empty()) { add(shortcut, Action::Mode(mode.id)); }
    }
    table.push((escape(), Action::Cancel));
    *st.shortcuts.lock() = table;
    problems
}

fn on_shortcut(app: &AppHandle, shortcut: &Shortcut, pressed: bool) {
    let action = state(app).shortcuts.lock().iter().find(|(s, _)| s == shortcut).map(|(_, a)| a.clone());
    let hold = state(app).settings.lock().core.hold_to_talk;
    match (action, pressed) {
        (Some(Action::Toggle), true) if state(app).settings.lock().automatic_activation => {
            let phase = *state(app).phase.lock();
            if phase == Phase::Idle { *state(app).pressed.lock() = Some(Instant::now()); start(app, None, false) } else if phase == Phase::Listening { stop(app) }
        }
        (Some(Action::Toggle), false) if state(app).settings.lock().automatic_activation => {
            let held = state(app).pressed.lock().take().map(|t| t.elapsed() >= Duration::from_millis(450)).unwrap_or(false);
            if held && *state(app).phase.lock() == Phase::Listening { stop(app) }
        }
        (Some(Action::Toggle), true) => {
            let phase = *state(app).phase.lock();
            if hold && phase == Phase::Idle { start(app, None, false) } else if !hold { toggle(app, None) } else if phase == Phase::Listening { stop(app) }
        }
        (Some(Action::Toggle), false) if hold => if *state(app).phase.lock() == Phase::Listening { stop(app) },
        (Some(Action::Mode(id)), true) => toggle(app, Some(id)),
        (Some(Action::Cancel), true) => cancel(app),
        (Some(Action::PasteLast), true) => paste_last(app),
        _ => {}
    }
}

// MARK: Commands for the settings window

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelInfo { engine: SpeechEngine, id: String, label: String, installed: bool }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    settings: AppSettings,
    phase: Phase,
    status: String,
    last: String,
    models: Vec<ModelInfo>,
    devices: Vec<String>,
    ollama_models: Vec<String>,
    history: Vec<HistoryEntry>,
    stats: store::UsageStats,
    downloading: Option<String>,
    bridge_command: String,
    wayland: bool,
}

#[tauri::command]
fn snapshot(app: AppHandle) -> Snapshot {
    let st = state(&app);
    let mut models = vec![ModelInfo { engine: SpeechEngine::Parakeet, id: String::new(), label: "Parakeet v3 (25 languages)".into(), installed: asr::installed(SpeechEngine::Parakeet, "") }];
    models.extend(asr::WHISPER_MODELS.iter().map(|(id, label)| ModelInfo { engine: SpeechEngine::Whisper, id: id.to_string(), label: format!("Whisper {label}"), installed: asr::installed(SpeechEngine::Whisper, id) }));
    let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "mouthy".into());
    let snapshot = Snapshot {
        settings: st.settings.lock().clone(),
        phase: *st.phase.lock(),
        status: st.status.lock().clone(),
        last: st.last.lock().clone(),
        models,
        devices: audio::input_devices(),
        ollama_models: llm::models(),
        history: st.history.lock().clone(),
        stats: st.stats.lock().clone(),
        downloading: st.downloading.lock().clone(),
        bridge_command: format!("claude mcp add mouthy -- \"{exe}\" --mcp-bridge"),
        wayland: cfg!(target_os = "linux") && std::env::var_os("WAYLAND_DISPLAY").is_some(),
    };
    snapshot
}

#[tauri::command]
fn save_settings(app: AppHandle, settings: AppSettings) -> Vec<String> {
    let st = state(&app);
    let login_changed = st.settings.lock().launch_at_login != settings.launch_at_login;
    *st.settings.lock() = settings.clone();
    let _ = store::save("settings.json", &settings);
    if login_changed { set_launch_at_login(settings.launch_at_login); }
    sync_settings(&app);
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("mouthy"), tray_menu(&app)) { let _ = tray.set_menu(Some(menu)); }
    register_shortcuts(&app)
}

#[tauri::command]
fn toggle_dictation(app: AppHandle) { toggle(&app, None) }

#[tauri::command]
fn cancel_dictation(app: AppHandle) { cancel(&app) }

#[tauri::command]
fn download_model(app: AppHandle, engine: SpeechEngine, id: String) {
    let st = state(&app);
    if st.settings.lock().core.local_only { set_status(&app, "Local Only Mode is on. Turn it off to download models."); return; }
    if st.downloading.lock().is_some() { return; }
    *st.downloading.lock() = Some(asr::archive_name(engine, &id));
    std::thread::spawn(move || {
        let progress_app = app.clone();
        let result = asr::download(engine, &id, |p| { let _ = progress_app.emit("download", p); });
        *state(&app).downloading.lock() = None;
        set_status(&app, match result { Ok(()) => "Model ready. It runs offline from now on.".into(), Err(e) => format!("Download failed: {e}") });
        let _ = app.emit("download", 1.0f32);
    });
}

#[tauri::command]
fn clear_history(app: AppHandle) {
    let st = state(&app);
    st.history.lock().clear();
    let _ = store::save("history.json", &Vec::<HistoryEntry>::new());
}

#[tauri::command]
fn delete_history(app: AppHandle, id: String) {
    let st = state(&app);
    let mut history = st.history.lock();
    history.retain(|e| e.id != id);
    let _ = store::save("history.json", &*history);
}

#[tauri::command]
fn copy_text(text: String) -> Result<(), String> { copy(&text) }

#[tauri::command]
fn meeting_toggle(app: AppHandle) -> Result<bool, String> {
    let st = state(&app);
    if let Some(meeting) = st.meeting.lock().take() {
        let dir = meeting.stop().map_err(|e| e.to_string())?;
        set_status(&app, format!("Meeting saved to {}. Transcribe it when you are ready.", dir.display()));
        return Ok(false);
    }
    if *st.phase.lock() != Phase::Idle { return Err("Finish the current dictation first.".into()); }
    let mic = st.settings.lock().core.input_device.clone();
    let meeting = meetings::Meeting::start(&mic).map_err(|e| e.to_string())?;
    set_status(&app, if meeting.has_system_audio() { "Recording the meeting: microphone and system audio, each on its own track." } else { "Recording the meeting: microphone only (system audio capture is unavailable)." });
    *st.meeting.lock() = Some(meeting);
    Ok(true)
}

#[derive(Serialize)]
struct MeetingInfo { name: String, path: String, transcribed: bool }

#[tauri::command]
fn meeting_list(app: AppHandle) -> (bool, Vec<MeetingInfo>) {
    (state(&app).meeting.lock().is_some(), meetings::list().into_iter().map(|(name, path, transcribed)| MeetingInfo { name, path, transcribed }).collect())
}

#[tauri::command]
fn meeting_transcribe(app: AppHandle, path: String) {
    std::thread::spawn(move || {
        set_status(&app, "Transcribing the meeting on this computer…");
        let settings = state(&app).settings.lock().clone();
        let result = meetings::transcribe(std::path::Path::new(&path), &mut |samples| recognize(&app, samples, settings.core.engine, &settings).unwrap_or_default());
        set_status(&app, match result { Ok(file) => format!("Transcript saved: {}", file.display()), Err(e) => format!("Meeting transcription failed: {e}") });
        let _ = app.emit("meetings", ());
    });
}

#[tauri::command]
fn open_path(path: String) {
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer").arg(&path).spawn();
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(&path).spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(&path).spawn();
}

/// Tray menu with the mode picker for the next dictation.
fn tray_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let modes = state(app).settings.lock().core.modes.clone();
    let toggle_item = MenuItem::with_id(app, "toggle", "Start / Stop Dictation", true, None::<&str>)?;
    let paste_item = MenuItem::with_id(app, "paste", "Paste Last Result", true, None::<&str>)?;
    let open_item = MenuItem::with_id(app, "open", "Open Mouthy", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit Mouthy", true, None::<&str>)?;
    let mut mode_items = vec![MenuItem::with_id(app, "mode:auto", "Automatic", true, None::<&str>)?];
    for mode in &modes { mode_items.push(MenuItem::with_id(app, format!("mode:{}", mode.id), &mode.name, true, None::<&str>)?); }
    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = mode_items.iter().map(|i| i as &dyn tauri::menu::IsMenuItem<tauri::Wry>).collect();
    let picker = Submenu::with_items(app, "Next Dictation Mode", !modes.is_empty(), &refs)?;
    Menu::with_items(app, &[&toggle_item, &picker, &paste_item, &open_item, &PredefinedMenuItem::separator(app)?, &quit_item])
}

/// Merges the sync folder's file into settings and writes the union back.
fn sync_settings(app: &AppHandle) {
    let st = state(app);
    let mut settings = st.settings.lock().clone();
    match store::sync(&mut settings) {
        Ok(true) => { let _ = store::save("settings.json", &settings); *st.settings.lock() = settings; let _ = app.emit("history", ()); }
        Ok(false) => {}
        Err(e) => set_status(app, format!("Sync skipped: {e}")),
    }
}

// MARK: Launch at login

fn set_launch_at_login(enabled: bool) {
    let Ok(exe) = std::env::current_exe() else { return };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let key = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
        let args: Vec<String> = if enabled {
            vec!["add".into(), key.into(), "/v".into(), "Mouthy".into(), "/t".into(), "REG_SZ".into(), "/d".into(), format!("\"{}\" --background", exe.display()), "/f".into()]
        } else {
            vec!["delete".into(), key.into(), "/v".into(), "Mouthy".into(), "/f".into()]
        };
        let _ = std::process::Command::new("reg").args(args).creation_flags(0x0800_0000).status();
    }
    #[cfg(target_os = "linux")]
    {
        let path = dirs::config_dir().unwrap_or_default().join("autostart/mouthy.desktop");
        if enabled {
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            let _ = std::fs::write(&path, format!("[Desktop Entry]\nType=Application\nName=Mouthy\nExec=\"{}\" --background\nX-GNOME-Autostart-enabled=true\n", exe.display()));
        } else {
            let _ = std::fs::remove_file(path);
        }
    }
    #[cfg(target_os = "macos")]
    let _ = (enabled, exe);
}

// MARK: Entry

fn pass_return(app: &AppHandle) {
    let target = platform::focused().unwrap_or_default();
    enter_key::stop();
    if let Err(reason) = platform::press_return(&target) { set_status(app, format!("Return was not sent: {reason}")); }
}

fn handle_args(app: &AppHandle, args: &[String]) {
    if args.iter().any(|a| a == "--split") {
        // Hyprland's Enter binding: split while listening, otherwise lift the binding and pass Enter on.
        if *state(app).phase.lock() == Phase::Listening { let a = app.clone(); std::thread::spawn(move || split(&a)); }
        else { pass_return(app); }
    }
    else if args.iter().any(|a| a == "--toggle") { toggle(app, None) }
    else if args.iter().any(|a| a == "--cancel") { cancel(app) }
    else if args.iter().any(|a| a == "--paste-last") { paste_last(app) }
    else if !args.iter().any(|a| a == "--background") { show_main(app) }
}

fn show_main(app: &AppHandle) {
    if let Some(main) = window(app, "main") { let _ = main.show(); let _ = main.set_focus(); }
}

#[tauri::command]
fn current_phase(app: AppHandle) -> Phase { *state(&app).phase.lock() }

fn transcribe_files(paths: &[String]) -> i32 {
    let settings: AppSettings = store::load("settings.json");
    let engine = settings.core.engine;
    let mut loaded = match asr::load(engine, &settings.core.whisper_model, &settings.whisper_language) {
        Ok(l) => l,
        Err(e) => { eprintln!("Mouthy: {e}"); return 1 }
    };
    let mut status = 0;
    for path in paths {
        match audio::read_wav(std::path::Path::new(path)) {
            Ok(samples) => println!("{}", asr::transcribe(&mut loaded, &samples)),
            Err(e) => { eprintln!("Mouthy: {path}: {e} (WAV files are supported)"); status = 1 }
        }
    }
    status
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--mcp-bridge") => std::process::exit(agent::bridge()),
        Some("transcribe") => std::process::exit(transcribe_files(&args[2..])),
        Some("mic-test") => {
            // Hardware check: record from the default microphone, then print what was heard.
            let seconds: u64 = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(6).clamp(1, 60);
            let settings: AppSettings = store::load("settings.json");
            let started = Instant::now();
            let recording = match audio::Recording::start(&settings.core.input_device, |_| {}) {
                Ok(r) => r,
                Err(e) => { eprintln!("Mouthy: {e}"); std::process::exit(1) }
            };
            eprintln!("Listening for {seconds} s on {} (ready in {:.2} s)…", recording.device_name, started.elapsed().as_secs_f64());
            std::thread::sleep(Duration::from_secs(seconds));
            let samples = recording.finish(None);
            let stop = Instant::now();
            let mut loaded = match asr::load(settings.core.engine, &settings.core.whisper_model, &settings.whisper_language) {
                Ok(l) => l,
                Err(e) => { eprintln!("Mouthy: {e}"); std::process::exit(1) }
            };
            println!("{}", asr::transcribe(&mut loaded, &samples));
            eprintln!("Transcribed in {:.2} s (including model load).", stop.elapsed().as_secs_f64());
            return;
        }
        Some("download") => {
            let settings: AppSettings = store::load("settings.json");
            if settings.core.local_only { eprintln!("Mouthy: Local Only Mode is on; downloads are disabled."); std::process::exit(1) }
            let (engine, id) = match args.get(2).map(String::as_str) {
                Some("whisper") => (SpeechEngine::Whisper, args.get(3).cloned().unwrap_or_else(|| "base.en".into())),
                _ => (SpeechEngine::Parakeet, String::new()),
            };
            let result = asr::download(engine, &id, |p| eprint!("\r{:>3.0}%", p * 100.0));
            eprintln!();
            match result { Ok(()) => println!("Installed {}", asr::archive_name(engine, &id)), Err(e) => { eprintln!("Mouthy: {e}"); std::process::exit(1) } }
            return;
        }
        Some("--help") | Some("-h") => {
            println!("Mouthy — local dictation\n\n  mouthy                 open settings (starts Mouthy if needed)\n  mouthy --background    start in the tray\n  mouthy --toggle        start/stop dictation (bind this on Wayland)\n  mouthy --cancel        cancel dictation\n  mouthy --paste-last    paste the last result\n  mouthy transcribe F.wav  print a transcript\n  mouthy download [parakeet | whisper MODEL]  install a speech model\n  mouthy mic-test [SECONDS]  record from the microphone and print the transcript\n  mouthy --mcp-bridge    stdio MCP bridge for AI agents");
            return;
        }
        _ => {}
    }
    let settings: AppSettings = store::load("settings.json");
    let history: Vec<HistoryEntry> = store::load("history.json");
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _| handle_args(app, &argv)))
        .plugin(tauri_plugin_global_shortcut::Builder::new()
            .with_handler(|app, shortcut, event| on_shortcut(app, shortcut, event.state() == ShortcutState::Pressed))
            .build())
        .manage(State {
            settings: Mutex::new(settings),
            recording: Mutex::new(None),
            phase: Mutex::new(Phase::Idle),
            session: Mutex::new(Session::default()),
            recognizer: Mutex::new(None),
            history: Mutex::new(history),
            last: Mutex::new(String::new()),
            status: Mutex::new("Ready.".into()),
            agent: Mutex::new(None),
            shortcuts: Mutex::new(Vec::new()),
            generation: AtomicU64::new(0),
            downloading: Mutex::new(None),
            pressed: Mutex::new(None),
            picked_mode: Mutex::new(None),
            splitting: std::sync::atomic::AtomicBool::new(false),
            meeting: Mutex::new(None),
            stats: Mutex::new(store::load("stats.json")),
            segment_start: Mutex::new(Instant::now()),
        })
        .invoke_handler(tauri::generate_handler![snapshot, save_settings, toggle_dictation, cancel_dictation, download_model, clear_history, delete_history, copy_text, meeting_toggle, meeting_list, meeting_transcribe, open_path, current_phase])
        .setup(move |app| {
            let handle = app.handle().clone();
            let menu = tray_menu(&handle)?;
            TrayIconBuilder::with_id("mouthy")
                .icon(app.default_window_icon().cloned().expect("icon"))
                .tooltip("Mouthy")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle(app, None),
                    "paste" => paste_last(app),
                    "open" => show_main(app),
                    "quit" => { cancel(app); if let Some(m) = state(app).meeting.lock().take() { let _ = m.stop(); } app.exit(0) }
                    "mode:auto" => { *state(app).picked_mode.lock() = None; set_status(app, "Next dictation: automatic mode.") }
                    id if id.starts_with("mode:") => {
                        let picked = uuid::Uuid::parse_str(&id[5..]).ok();
                        *state(app).picked_mode.lock() = picked;
                        let name = state(app).settings.lock().core.modes.iter().find(|m| Some(m.id) == picked).map(|m| m.name.clone()).unwrap_or_default();
                        set_status(app, format!("Next dictation: {name}."));
                    }
                    _ => {}
                })
                .build(app)?;
            let problems = register_shortcuts(&handle);
            if !problems.is_empty() {
                set_status(&handle, if cfg!(target_os = "linux") && std::env::var_os("WAYLAND_DISPLAY").is_some() {
                    "On Wayland, bind a key to `mouthy --toggle` in your compositor (Settings shows how).".to_string()
                } else { format!("Some shortcuts are unavailable: {}", problems.join("; ")) });
            }
            // Sync now and every ten minutes (a small file in a folder the machines share).
            let sync_app = handle.clone();
            std::thread::spawn(move || loop { sync_settings(&sync_app); std::thread::sleep(Duration::from_secs(600)); });
            let agent_app = handle.clone();
            let enabled_app = handle.clone();
            if let Err(problem) = agent::serve(move |questions| ask(&agent_app, questions), move || state(&enabled_app).settings.lock().agent_voice) {
                set_status(&handle, problem);
            }
            let args: Vec<String> = std::env::args().collect();
            if args.iter().any(|a| a == "--split") { pass_return(&handle); }
            else if !args.iter().any(|a| a == "--background" || a == "--toggle") { show_main(&handle); }
            if args.iter().any(|a| a == "--toggle") { toggle(&handle, None); }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Mouthy failed to start")
        // Closing the last window keeps Mouthy in the tray; only Quit exits.
        .run(|_, event| if let tauri::RunEvent::ExitRequested { api, code, .. } = event { if code.is_none() { api.prevent_exit(); } });
}
