//! Enter while dictating sends what was said so far and keeps listening (the Mac app's behavior).
//! Windows: a low-level keyboard hook, installed only while listening, takes plain Enter once speech
//! was heard; injected (synthetic) Enters pass through. Hyprland: Enter is bound to `mouthy --split`
//! only while listening, through the Lua config API (or the legacy keyword API).

use std::sync::atomic::AtomicBool;

/// Set by the recorder once speech-level audio arrives; cleared at each split.
pub static HEARD: AtomicBool = AtomicBool::new(false);

pub use imp::{start, stop};

#[cfg(windows)]
mod imp {
    use super::*;
    use std::sync::atomic::Ordering;
    use parking_lot::Mutex;
    use std::sync::OnceLock;
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RETURN, VK_RWIN, VK_SHIFT};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, GetMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG,
        WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT,
    };

    static CALLBACK: OnceLock<Mutex<Option<Box<dyn Fn() + Send>>>> = OnceLock::new();
    static THREAD: Mutex<Option<u32>> = parking_lot::const_mutex(None);
    static SWALLOW_UP: AtomicBool = AtomicBool::new(false);

    unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            if info.vkCode == VK_RETURN.0 as u32 && (info.flags.0 & LLKHF_INJECTED.0) == 0 {
                let message = wparam.0 as u32;
                if message == WM_KEYDOWN {
                    let modified = [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN].iter().any(|k| GetAsyncKeyState(k.0 as i32) < 0);
                    if !modified && HEARD.load(Ordering::SeqCst) {
                        SWALLOW_UP.store(true, Ordering::SeqCst);
                        if let Some(callback) = CALLBACK.get() { if let Some(f) = callback.lock().as_ref() { f(); } }
                        return LRESULT(1);
                    }
                } else if message == WM_KEYUP && SWALLOW_UP.swap(false, Ordering::SeqCst) {
                    return LRESULT(1);
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    pub fn start(on_enter: impl Fn() + Send + 'static) {
        *CALLBACK.get_or_init(|| Mutex::new(None)).lock() = Some(Box::new(on_enter));
        if THREAD.lock().is_some() { return; }
        std::thread::spawn(|| unsafe {
            let module = GetModuleHandleW(None).unwrap_or_default();
            let Ok(handle) = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), module, 0) else { return };
            *THREAD.lock() = Some(GetCurrentThreadId());
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {}
            let _ = UnhookWindowsHookEx(handle);
        });
    }

    pub fn stop() {
        if let Some(thread) = THREAD.lock().take() { unsafe { let _ = PostThreadMessageW(thread, WM_QUIT, WPARAM(0), LPARAM(0)); } }
        SWALLOW_UP.store(false, Ordering::SeqCst);
    }
}

/// The shell command Hyprland runs for Enter: the executable single-quoted, so spaces and shell
/// characters in its path stay literal. None for paths a bind line cannot carry (commas, newlines).
#[allow(dead_code)]
fn split_command(exe: &str) -> Option<String> {
    if exe.contains([',', '\n', '\r', '\0']) { return None; }
    Some(format!("'{}' --split", exe.replace('\'', "'\\''")))
}

/// A Lua string literal.
#[allow(dead_code)]
fn lua_string(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(target_os = "linux")]
mod imp {
    use std::process::{Command, Stdio};

    fn hyprctl(args: &[&str]) -> bool {
        Command::new("hyprctl").args(args).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
    }

    /// Binds plain Enter to `mouthy --split` while listening (Hyprland only).
    pub fn start(_on_enter: impl Fn() + Send + 'static) {
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() { return; }
        let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "mouthy".into());
        let Some(command) = super::split_command(&exe) else { return };
        if !hyprctl(&["eval", &format!("hl.bind(\"Return\", hl.dsp.exec_cmd({}))", super::lua_string(&command))]) {
            hyprctl(&["keyword", "bind", &format!(",Return,exec,{command}")]);
        }
    }

    pub fn stop() {
        if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() { return; }
        if !hyprctl(&["eval", "hl.unbind(\"Return\")"]) { hyprctl(&["keyword", "unbind", ",Return"]); }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    pub fn start(_on_enter: impl Fn() + Send + 'static) {}
    pub fn stop() {}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn enter_binding_keeps_the_path_literal() {
        assert_eq!(split_command("/opt/My Apps/mouthy").unwrap(), "'/opt/My Apps/mouthy' --split");
        assert_eq!(split_command("/tmp/$(touch x)/it's").unwrap(), "'/tmp/$(touch x)/it'\\''s' --split");
        assert!(split_command("/tmp/a,b/mouthy").is_none());
        assert_eq!(lua_string(r#"'a "b" \c' --split"#), r#""'a \"b\" \\c' --split""#);
    }
}
