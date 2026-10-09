//! OS integration: the focused app, paste into it, press Return, and quiet other audio.
//! Windows uses Win32/Core Audio; Linux supports Wayland (Hyprland, wl-clipboard, wtype, PipeWire,
//! MPRIS) with an X11 fallback through enigo.

#[allow(unused_imports)]
use std::time::Duration;

#[derive(Clone, Debug, Default)]
pub struct FocusedApp {
    /// "slack.exe" on Windows, window class on Linux.
    pub app: String,
    pub title: String,
    pub pid: u32,
    /// Native window handle (Windows HWND) for refocusing.
    #[allow(dead_code)]
    pub window: isize,
}

impl FocusedApp {
    pub fn is_self(&self) -> bool {
        self.pid == std::process::id()
    }
    pub fn is_browser(&self) -> bool {
        let a = self.app.to_lowercase();
        ["chrome", "firefox", "msedge", "edge", "brave", "vivaldi", "opera", "chromium", "zen", "librewolf", "arc"].iter().any(|b| a.contains(b))
    }
    #[allow(dead_code)]
    pub fn is_terminal(&self) -> bool {
        let a = self.app.to_lowercase();
        ["terminal", "alacritty", "kitty", "ghostty", "foot", "wezterm", "konsole", "xterm", "windowsterminal", "cmd.exe", "powershell", "pwsh", "conhost"]
            .iter().any(|t| a.contains(t))
    }
    /// Browsers do not expose the page URL here; match a site by its name in the window title
    /// (for "github.com", a title containing "github").
    pub fn page_hint(&self) -> Option<String> {
        self.is_browser().then(|| self.title.clone())
    }
}

/// Resolves a website-matched mode from a browser window title.
pub fn title_matches_site(title: &str, site: &str) -> bool {
    let site = site.trim().trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.");
    let label = site.split('/').next().unwrap_or(site);
    let name = label.split('.').next().unwrap_or(label);
    !name.is_empty() && (title.to_lowercase().contains(&label.to_lowercase()) || title.to_lowercase().contains(&name.to_lowercase()))
}

pub use imp::*;

/// A known target must still be focused immediately before an automatic keystroke.
fn same_target(expected: &FocusedApp, current: Option<&FocusedApp>) -> bool {
    current.is_some_and(|current| expected.pid != 0 && current.pid == expected.pid
        && (expected.window == 0 || current.window == expected.window))
}

#[cfg(any(windows, test))]
fn checked_windows_input(expected: &FocusedApp, current: Option<&FocusedApp>, password: Option<bool>,
                         send: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
    if expected.window == 0 || !same_target(expected, current) { return Err("the focused window changed or could not be verified.".into()); }
    match password {
        Some(false) => send(),
        Some(true) => Err("a password field is focused.".into()),
        None => Err("the focused field's protection could not be verified.".into()),
    }
}

/// What the clipboard held before a paste, restored afterwards (including "nothing", so a
/// dictation never lingers on the clipboard).
#[allow(dead_code)]
enum Saved { Text(String), Image(arboard::ImageData<'static>), Empty }

#[allow(dead_code)]
impl Saved {
    fn take(clipboard: &mut arboard::Clipboard) -> Self {
        if let Ok(text) = clipboard.get_text() { return Self::Text(text); }
        if let Ok(image) = clipboard.get_image() { return Self::Image(image.to_owned_img()); }
        Self::Empty
    }
    /// Restores only while the clipboard still holds our text, so a later copy by the person wins.
    fn restore(self, clipboard: &mut arboard::Clipboard, ours: &str) {
        if clipboard.get_text().ok().as_deref() != Some(ours) { return; }
        let _ = match self {
            Self::Text(text) => clipboard.set_text(text),
            Self::Image(image) => clipboard.set_image(image),
            Self::Empty => clipboard.clear(),
        };
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};
    use windows::core::PWSTR;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::Media::Audio::Endpoints::{IAudioEndpointVolume, IAudioMeterInformation};
    use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId};

    pub fn focused() -> Option<FocusedApp> {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.0.is_null() { return None; }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            let mut title = [0u16; 512];
            let n = GetWindowTextW(hwnd, &mut title);
            let mut app = String::new();
            if let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
                let mut buffer = [0u16; 1024];
                let mut len = buffer.len() as u32;
                if QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut len).is_ok() {
                    let path = String::from_utf16_lossy(&buffer[..len as usize]);
                    app = path.rsplit('\\').next().unwrap_or(&path).to_string();
                }
                let _ = CloseHandle(handle);
            }
            Some(FocusedApp { app, title: String::from_utf16_lossy(&title[..n as usize]), pid, window: hwnd.0 as isize })
        }
    }

    fn chord(modifier: Key, key: Key) -> bool {
        let Ok(mut enigo) = Enigo::new(&Settings::default()) else { return false };
        enigo.key(modifier, Direction::Press).is_ok()
            && enigo.key(key, Direction::Click).is_ok()
            && enigo.key(modifier, Direction::Release).is_ok()
    }

    /// None when UI Automation cannot establish the focused control's protection.
    fn focused_is_password() -> Option<bool> {
        use windows::Win32::System::Com::CLSCTX_INPROC_SERVER;
        use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation};
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation = CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            automation.GetFocusedElement().and_then(|e| e.CurrentIsPassword()).map(|b| b.as_bool()).ok()
        }
    }

    fn checked_focused_input(app: &FocusedApp, send: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
        let password = focused_is_password();
        checked_windows_input(app, focused().as_ref(), password, send)
    }

    /// Pastes into `app`, checking right before the keystroke that it is still focused and not a password field.
    pub fn paste(text: &str, app: &FocusedApp) -> Result<(), String> {
        checked_focused_input(app, || Ok(()))
            .map_err(|reason| format!("Not pasted: {reason}"))?;
        let mut clipboard = arboard::Clipboard::new().map_err(|e| e.to_string())?;
        let previous = Saved::take(&mut clipboard);
        clipboard.set_text(text.to_string()).map_err(|e| e.to_string())?;
        std::thread::sleep(Duration::from_millis(40));
        let sent = checked_focused_input(app, || {
            if chord(Key::Control, Key::Unicode('v')) { Ok(()) } else { Err("the paste keystroke could not be sent.".into()) }
        });
        if sent.is_ok() { std::thread::sleep(Duration::from_millis(300)); }
        previous.restore(&mut clipboard, text);
        sent.map_err(|reason| format!("Not pasted: {reason}"))
    }

    pub fn press_return(app: &FocusedApp) -> Result<(), String> {
        let mut enigo = Enigo::new(&Settings::default()).map_err(|_| "the keyboard is unavailable.".to_string())?;
        checked_focused_input(app, || {
            enigo.key(Key::Return, Direction::Click).map_err(|_| "the Return keystroke could not be sent.".to_string())
        })
    }

    pub fn place_overlay(_: i32, _: i32, _: f64) {}

    /// Text just before and after the cursor in the focused field (UI Automation text pattern),
    /// for fitting spacing and capitals. None when the app does not expose its text.
    pub fn cursor_context() -> Option<(String, String)> {
        use windows::Win32::System::Com::CLSCTX_INPROC_SERVER;
        use windows::Win32::UI::Accessibility::{
            CUIAutomation, IUIAutomation, IUIAutomationTextPattern, TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start,
            TextUnit_Character, UIA_TextPatternId,
        };
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            let element = automation.GetFocusedElement().ok()?;
            let pattern: IUIAutomationTextPattern = element.GetCurrentPatternAs(UIA_TextPatternId).ok()?;
            let selection = pattern.GetSelection().ok()?;
            if selection.Length().ok()? < 1 { return None; }
            let caret = selection.GetElement(0).ok()?;
            let before = caret.Clone().ok()?;
            before.MoveEndpointByRange(TextPatternRangeEndpoint_End, &caret, TextPatternRangeEndpoint_Start).ok()?;
            before.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -200).ok()?;
            let after = caret.Clone().ok()?;
            after.MoveEndpointByRange(TextPatternRangeEndpoint_Start, &caret, TextPatternRangeEndpoint_End).ok()?;
            after.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 100).ok()?;
            Some((before.GetText(200).ok()?.to_string(), after.GetText(100).ok()?.to_string()))
        }
    }

    /// Returns keyboard focus to the window that was active when recording started.
    pub fn focus(app: &FocusedApp) {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
        if app.window != 0 { unsafe { let _ = SetForegroundWindow(HWND(app.window as *mut _)); } }
        std::thread::sleep(Duration::from_millis(80));
    }

    fn endpoint() -> Option<windows::Win32::Media::Audio::IMMDevice> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
            enumerator.GetDefaultAudioEndpoint(eRender, eConsole).ok()
        }
    }
    pub fn output_muted() -> Option<bool> {
        unsafe {
            let volume: IAudioEndpointVolume = endpoint()?.Activate(CLSCTX_ALL, None).ok()?;
            volume.GetMute().ok().map(|b| b.as_bool())
        }
    }
    pub fn set_output_muted(muted: bool) -> bool {
        unsafe {
            let Some(device) = endpoint() else { return false };
            let Ok(volume) = device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None) else { return false };
            volume.SetMute(muted, std::ptr::null()).is_ok()
        }
    }
    /// Something is audibly playing on the default output.
    fn playing() -> bool {
        unsafe {
            let Some(device) = endpoint() else { return false };
            let Ok(meter) = device.Activate::<IAudioMeterInformation>(CLSCTX_ALL, None) else { return false };
            (0..4).any(|_| { let peak = meter.GetPeakValue().unwrap_or(0.0); std::thread::sleep(Duration::from_millis(25)); peak > 0.001 })
        }
    }
    pub fn pause_media() -> Vec<String> {
        if playing() && chord_media() { vec!["system".into()] } else { vec![] }
    }
    pub fn resume_media(paused: &[String]) {
        if !paused.is_empty() && !playing() { chord_media(); }
    }
    fn chord_media() -> bool {
        Enigo::new(&Settings::default()).map(|mut e| e.key(Key::MediaPlayPause, Direction::Click).is_ok()).unwrap_or(false)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::*;
    use std::io::Write;
    use std::process::{Command, Stdio};

    fn wayland() -> bool {
        std::env::var_os("WAYLAND_DISPLAY").is_some()
    }
    fn run(program: &str, args: &[&str]) -> Option<String> {
        let out = Command::new(program).args(args).stderr(Stdio::null()).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }

    pub fn focused() -> Option<FocusedApp> {
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() {
            let json: serde_json::Value = serde_json::from_str(&run("hyprctl", &["activewindow", "-j"])?).ok()?;
            return Some(FocusedApp {
                app: json["class"].as_str().unwrap_or_default().to_string(),
                title: json["title"].as_str().unwrap_or_default().to_string(),
                pid: json["pid"].as_u64().unwrap_or(0) as u32,
                window: json["address"].as_str().and_then(|s| isize::from_str_radix(s.trim_start_matches("0x"), 16).ok()).unwrap_or(0),
            });
        }
        // Other desktops: the app is unknown; insertion still targets the focused window.
        Some(FocusedApp::default())
    }

    fn set_clipboard(text: &str) -> bool {
        if wayland() {
            let Ok(mut child) = Command::new("wl-copy").stdin(Stdio::piped()).spawn() else { return false };
            if let Some(mut stdin) = child.stdin.take() { let _ = stdin.write_all(text.as_bytes()); }
            child.wait().map(|s| s.success()).unwrap_or(false)
        } else {
            arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())).is_ok()
        }
    }
    fn get_clipboard() -> Option<String> {
        if wayland() { run("wl-paste", &["-n"]) } else { arboard::Clipboard::new().ok()?.get_text().ok() }
    }

    /// Wayland clipboard contents as (MIME type, bytes); None when empty.
    fn take_wayland() -> Option<(String, Vec<u8>)> {
        let types = run("wl-paste", &["--list-types"])?;
        let types: Vec<&str> = types.lines().collect();
        let mime = types.iter().find(|t| t.starts_with("text/plain")).or(types.first())?.to_string();
        let out = Command::new("wl-paste").args(["-n", "-t", &mime]).stderr(Stdio::null()).output().ok()?;
        out.status.success().then_some((mime, out.stdout))
    }
    fn restore_wayland(previous: Option<(String, Vec<u8>)>, ours: &str) {
        if get_clipboard().as_deref() != Some(ours) { return; }
        match previous {
            Some((mime, bytes)) => {
                let Ok(mut child) = Command::new("wl-copy").args(["-t", &mime]).stdin(Stdio::piped()).spawn() else { return };
                if let Some(mut stdin) = child.stdin.take() { let _ = stdin.write_all(&bytes); }
                let _ = child.wait();
            }
            None => { let _ = Command::new("wl-copy").arg("--clear").status(); }
        }
    }

    /// Pastes into `app`, checking right before the keystroke that it is still focused (where the
    /// desktop reports it). Linux offers no portable password-field check.
    pub fn paste(text: &str, app: &FocusedApp) -> Result<(), String> {
        if !wayland() {
            let mut clipboard = arboard::Clipboard::new().map_err(|_| "The clipboard is not available.".to_string())?;
            let previous = Saved::take(&mut clipboard);
            clipboard.set_text(text.to_string()).map_err(|e| e.to_string())?;
            std::thread::sleep(Duration::from_millis(60));
            let sent = x11_chord(app.is_terminal());
            if sent { std::thread::sleep(Duration::from_millis(300)); }
            previous.restore(&mut clipboard, text);
            return if sent { Ok(()) } else { Err("The paste keystroke could not be sent.".into()) };
        }
        let previous = take_wayland();
        if !set_clipboard(text) { return Err("The clipboard is not available (install wl-clipboard).".into()); }
        std::thread::sleep(Duration::from_millis(60));
        if app.pid != 0 && !same_target(app, focused().as_ref()) {
            restore_wayland(previous, text);
            return Err("Not pasted: focus changed before pasting.".into());
        }
        // Terminals paste with Ctrl+Shift+V (bracketed paste, so newlines do not run commands).
        let args: &[&str] = if app.is_terminal() { &["-M", "ctrl", "-M", "shift", "v", "-m", "shift", "-m", "ctrl"] } else { &["-M", "ctrl", "v", "-m", "ctrl"] };
        let sent = Command::new("wtype").args(args).status().map(|s| s.success()).unwrap_or(false);
        if sent { std::thread::sleep(Duration::from_millis(300)); }
        restore_wayland(previous, text);
        if sent { Ok(()) } else { Err("The paste keystroke could not be sent (install wtype).".into()) }
    }

    fn x11_chord(shift: bool) -> bool {
        use enigo::{Direction, Enigo, Key, Keyboard, Settings};
        let Ok(mut e) = Enigo::new(&Settings::default()) else { return false };
        let _ = e.key(Key::Control, Direction::Press);
        if shift { let _ = e.key(Key::Shift, Direction::Press); }
        let ok = e.key(Key::Unicode('v'), Direction::Click).is_ok();
        if shift { let _ = e.key(Key::Shift, Direction::Release); }
        let _ = e.key(Key::Control, Direction::Release);
        ok
    }

    pub fn press_return(app: &FocusedApp) -> Result<(), String> {
        if !same_target(app, focused().as_ref()) { return Err("the focused window changed or could not be verified.".into()); }
        if wayland() {
            if Command::new("wtype").args(["-k", "Return"]).status().is_ok_and(|s| s.success()) { Ok(()) }
            else { Err("the Return keystroke could not be sent.".into()) }
        } else {
            use enigo::{Direction, Enigo, Key, Keyboard, Settings};
            let mut e = Enigo::new(&Settings::default()).map_err(|_| "the keyboard is unavailable.".to_string())?;
            e.key(Key::Return, Direction::Click).map_err(|_| "the Return keystroke could not be sent.".to_string())
        }
    }

    pub fn focus(app: &FocusedApp) {
        if app.pid != 0 && std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() {
            let _ = Command::new("hyprctl").args(["dispatch", "focuswindow", &format!("pid:{}", app.pid)]).status();
            std::thread::sleep(Duration::from_millis(80));
        }
    }

    /// Wayland clients cannot position themselves; ask Hyprland to float, pin and place the island.
    pub fn place_overlay(x: i32, y: i32, scale: f64) {
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() { return; }
        let (lx, ly) = ((x as f64 / scale) as i32, (y as f64 / scale) as i32);
        let w = "title:^(Mouthy recording)$";
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            let batch = format!("dispatch setfloating {w} ; dispatch pin {w} ; dispatch movewindowpixel exact {lx} {ly},{w}");
            let _ = Command::new("hyprctl").args(["--batch", &batch]).status();
        });
    }

    /// Wayland offers no portable way to read another app's text around the cursor.
    pub fn cursor_context() -> Option<(String, String)> { None }

    pub fn output_muted() -> Option<bool> {
        run("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"]).map(|s| s.contains("MUTED"))
    }
    pub fn set_output_muted(muted: bool) -> bool {
        Command::new("wpctl").args(["set-mute", "@DEFAULT_AUDIO_SINK@", if muted { "1" } else { "0" }]).status().map(|s| s.success()).unwrap_or(false)
    }

    fn players() -> Vec<String> {
        run("busctl", &["--user", "--list", "--no-legend", "--no-pager", "list"]).unwrap_or_default()
            .lines().filter_map(|l| l.split_whitespace().next()).filter(|n| n.starts_with("org.mpris.MediaPlayer2.")).map(String::from).collect()
    }
    fn status(player: &str) -> String {
        run("busctl", &["--user", "get-property", player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"]).unwrap_or_default()
    }
    fn call(player: &str, method: &str) {
        let _ = Command::new("busctl").args(["--user", "call", player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", method]).status();
    }
    /// Pauses MPRIS players that are actually playing and returns them for resuming.
    pub fn pause_media() -> Vec<String> {
        players().into_iter().filter(|p| status(p).contains("Playing")).inspect(|p| call(p, "Pause")).collect()
    }
    pub fn resume_media(paused: &[String]) {
        for player in paused { if status(player).contains("Paused") { call(player, "Play"); } }
    }
}

/// Development builds on macOS compile the app but use the native Swift app for real dictation.
#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    pub fn focused() -> Option<FocusedApp> { Some(FocusedApp::default()) }
    pub fn paste(text: &str, _app: &FocusedApp) -> Result<(), String> {
        arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())).map_err(|e| e.to_string())?;
        Err("Copied. Use the native Mac app for automatic insertion.".into())
    }
    pub fn press_return(_: &FocusedApp) -> Result<(), String> { Err("use the native Mac app for automatic insertion.".into()) }
    pub fn focus(_: &FocusedApp) {}
    pub fn place_overlay(_: i32, _: i32, _: f64) {}
    pub fn cursor_context() -> Option<(String, String)> { None }
    pub fn output_muted() -> Option<bool> { None }
    pub fn set_output_muted(_: bool) -> bool { false }
    pub fn pause_media() -> Vec<String> { vec![] }
    pub fn resume_media(_: &[String]) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn site_titles_match() {
        assert!(title_matches_site("Pull requests · GitHub — Mozilla Firefox", "github.com"));
        assert!(title_matches_site("Inbox - mail.google.com - Chrome", "mail.google.com"));
        assert!(!title_matches_site("Notes - Chrome", "github.com"));
    }

    #[test]
    fn automatic_keys_require_the_same_known_target_and_a_readable_unprotected_field() {
        let target = FocusedApp { pid: 42, window: 100, ..Default::default() };
        let changed_window = FocusedApp { pid: 42, window: 101, ..Default::default() };
        let changed_process = FocusedApp { pid: 43, window: 100, ..Default::default() };
        for current in [None, Some(&changed_window), Some(&changed_process)] {
            let mut sent = false;
            assert!(checked_windows_input(&target, current, Some(false), || { sent = true; Ok(()) }).is_err());
            assert!(!sent);
        }
        for password in [None, Some(true)] {
            let mut sent = false;
            assert!(checked_windows_input(&target, Some(&target), password, || { sent = true; Ok(()) }).is_err());
            assert!(!sent);
        }
        let mut sent = false;
        assert!(checked_windows_input(&target, Some(&target), Some(false), || { sent = true; Ok(()) }).is_ok());
        assert!(sent);
        assert!(!same_target(&FocusedApp::default(), Some(&FocusedApp::default())));
    }
}
