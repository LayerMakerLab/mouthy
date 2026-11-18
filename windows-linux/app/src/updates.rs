//! Automatic updates for Windows and Linux.
//!
//! While "Check for updates automatically" is on (the default) and Local Only Mode is off, Mouthy
//! asks the static feed in `tauri.conf.json` (`plugins.updater.endpoints`) a minute after it starts
//! and then once a day whether a newer version exists. A newer archive (the same `.tar.gz` or `.zip`
//! people install by hand) is downloaded in the background and kept only if its signature matches
//! the public key in `tauri.conf.json`. Its executable and libraries are unpacked into a folder next
//! to the running copy and swapped in when Mouthy quits. Any failure (no feed yet, offline, a bad
//! signature, a read-only install) is silent: nothing is shown and the next check waits a day.
//! A downloaded update that is still waiting when updates are turned off is thrown away at quit.
//! Nothing here opens a window or emits an event.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tauri::{AppHandle, Runtime};
use tauri_plugin_updater::UpdaterExt;

use crate::store::AppSettings;

/// Folder next to the executable that holds the next version until Mouthy quits.
const STAGE: &str = ".mouthy-update";
/// Written last into the stage folder; its presence means the stage is complete.
const READY: &str = "version";
const EXE: &str = if cfg!(windows) { "mouthy.exe" } else { "mouthy" };

/// Whether these settings allow contacting the feed at all.
pub fn wanted(settings: &AppSettings) -> bool { settings.check_updates && !settings.core.local_only }

/// Checks a minute after launch, then every 24 hours, reading the settings again before each check.
pub fn schedule<R: Runtime>(app: AppHandle<R>, wanted: impl Fn() -> bool + Send + 'static) {
    let Some(dir) = install_dir() else { return };
    remove_replaced(&dir);
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(60));
        loop {
            tauri::async_runtime::block_on(check(&app, &wanted, &dir));
            std::thread::sleep(Duration::from_secs(24 * 60 * 60));
        }
    });
}

/// One check. Returns the version it staged; `None` when turned off, up to date or anything failed.
pub async fn check<R: Runtime>(app: &AppHandle<R>, wanted: &dyn Fn() -> bool, dir: &Path) -> Option<String> {
    if !wanted() { return None; }
    match fetch_and_stage(app, dir).await {
        Ok(version) => version,
        Err(_) => None, // Silent by design: the feed may not exist yet, or the computer is offline.
    }
}

async fn fetch_and_stage<R: Runtime>(app: &AppHandle<R>, dir: &Path) -> Result<Option<String>, String> {
    let updater = app.updater_builder().timeout(Duration::from_secs(60)).build().map_err(|e| e.to_string())?;
    let Some(mut update) = updater.check().await.map_err(|e| e.to_string())? else { return Ok(None) };
    if std::fs::read_to_string(dir.join(STAGE).join(READY)).ok().as_deref() == Some(update.version.as_str()) { return Ok(None); }
    // A folder that cannot be written (a root-owned install) is found out before the download, not after.
    std::fs::create_dir_all(dir.join(STAGE)).map_err(|e| e.to_string())?;
    // The check's timeout does not cover the download; a stalled one must not block the daily loop for good.
    update.timeout = Some(Duration::from_secs(600));
    // `download` verifies the minisign signature against the configured public key before returning.
    // A failed or rejected download leaves no empty stage folder behind (an older complete stage is untouched).
    let bytes = match update.download(|_, _| {}, || {}).await {
        Ok(bytes) => bytes,
        Err(e) => { let _ = std::fs::remove_dir(dir.join(STAGE)); return Err(e.to_string()) }
    };
    stage(&bytes, &update.version, dir)?;
    Ok(Some(update.version))
}

/// The folder Mouthy runs from. Only the builds `package.sh` makes (`MOUTHY_UPDATES` set at compile time)
/// update themselves: debug builds and copies built from source never check. Resolve it before any swap:
/// after one, Linux reports the running file as "mouthy (deleted)". Not canonicalized, because on Windows
/// that prefixes `\\?\`, which would then reach the Run key and the bridge command.
pub fn install_dir() -> Option<PathBuf> {
    if cfg!(debug_assertions) || option_env!("MOUTHY_UPDATES").is_none() { return None; }
    std::env::current_exe().ok()?.parent().map(Path::to_path_buf)
}

/// Only what the install scripts copy: the executable and its libraries.
fn is_app_file(name: &str) -> bool {
    name == EXE || (cfg!(windows) && name.to_ascii_lowercase().ends_with(".dll")) || (cfg!(unix) && name.contains(".so"))
}

/// Unpacks the executable and libraries of a `.tar.gz` or `.zip` into the stage folder.
pub fn stage(archive: &[u8], version: &str, dir: &Path) -> Result<(), String> {
    let stage = dir.join(STAGE);
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
    let result = unpack(archive, &stage).and_then(|names| {
        if !names.iter().any(|n| n == EXE) { return Err(format!("the archive has no {EXE}")); }
        std::fs::write(stage.join(READY), version).map_err(|e| e.to_string())
    });
    if result.is_err() { let _ = std::fs::remove_dir_all(&stage); }
    result
}

fn unpack(archive: &[u8], stage: &Path) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    let mut keep = |name: &str, data: &mut dyn Read| -> Result<(), String> {
        // Only the last path component is used, so no entry can land outside the stage folder.
        if !is_app_file(name) || names.iter().any(|n| n == name) { return Ok(()); }
        let mut file = std::fs::File::create(stage.join(name)).map_err(|e| e.to_string())?;
        std::io::copy(data, &mut file).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        { use std::os::unix::fs::PermissionsExt; file.set_permissions(std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?; }
        names.push(name.to_string());
        Ok(())
    };
    if archive.starts_with(&[0x1f, 0x8b]) {
        let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
        for entry in tar.entries().map_err(|e| e.to_string())? {
            let mut entry = entry.map_err(|e| e.to_string())?;
            if !entry.header().entry_type().is_file() { continue; }
            let name = entry.path().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
            keep(&name, &mut entry)?;
        }
    } else if archive.starts_with(b"PK\x03\x04") {
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(archive)).map_err(|e| e.to_string())?;
        for i in 0..zip.len() {
            let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
            if !entry.is_file() { continue; }
            let name = entry.enclosed_name().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
            keep(&name, &mut entry)?;
        }
    } else {
        return Err("unknown archive format".into());
    }
    Ok(names)
}

/// Swaps a complete stage into the install folder (at quit, or at the next start), or throws it away when
/// updates were turned off (or Local Only Mode on) after it was downloaded. True when files were swapped.
pub fn apply_staged(dir: &Path, wanted: bool) -> bool { apply(dir, wanted) == Ok(true) }

/// Starts the installed executable with `args` so a just-swapped version takes over (`dir` was resolved
/// before the swap; `current_exe` would name the replaced file).
pub fn relaunch(dir: &Path, args: &[String]) -> bool {
    std::process::Command::new(dir.join(EXE)).args(args).spawn().is_ok()
}

pub fn apply(dir: &Path, wanted: bool) -> Result<bool, String> { apply_over(dir, wanted, env!("CARGO_PKG_VERSION")) }

/// Only a stage newer than the running version lands; one left behind by an install by hand, or a stage
/// of this same version, is thrown away so nothing can go backwards.
fn apply_over(dir: &Path, wanted: bool, current: &str) -> Result<bool, String> {
    let stage = dir.join(STAGE);
    if !wanted { let _ = std::fs::remove_dir_all(&stage); return Ok(false); }
    if !stage.join(READY).is_file() { return Ok(false); }
    let newer = match (std::fs::read_to_string(stage.join(READY)).ok().and_then(|v| v.trim().parse::<semver::Version>().ok()), current.parse::<semver::Version>()) {
        (Some(staged), Ok(running)) => staged > running,
        _ => false,
    };
    if !newer { let _ = std::fs::remove_dir_all(&stage); return Ok(false); }
    let mut names: Vec<String> = std::fs::read_dir(&stage).map_err(|e| e.to_string())?
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .filter(|n| is_app_file(n)).collect();
    names.sort_by_key(|n| n == EXE); // Libraries first, the executable last.
    for name in names {
        let target = dir.join(&name);
        // Windows cannot overwrite a running executable or a loaded library, but can rename it;
        // the renamed copy is removed at the next start. Linux replaces the file in place.
        let old = dir.join(format!("{name}.old"));
        if cfg!(windows) && target.exists() {
            let _ = std::fs::remove_file(&old);
            std::fs::rename(&target, &old).map_err(|e| e.to_string())?;
        }
        if let Err(e) = std::fs::rename(stage.join(&name), &target) {
            if cfg!(windows) { let _ = std::fs::rename(&old, &target); }
            return Err(e.to_string());
        }
    }
    let _ = std::fs::remove_dir_all(&stage);
    Ok(true)
}

/// Removes the copies Windows had to rename while they were running.
fn remove_replaced(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.strip_suffix(".old").is_some_and(is_app_file) { let _ = std::fs::remove_file(entry.path()); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tauri::{Listener, Manager};

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mouthy-{name}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The public key and feed settings shipped in tauri.conf.json, with the feed pointed elsewhere.
    fn app(endpoint: &str, extra: serde_json::Value) -> tauri::App<tauri::test::MockRuntime> {
        let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let mut updater = conf["plugins"]["updater"].clone();
        updater["endpoints"] = serde_json::json!([endpoint]);
        updater["dangerousInsecureTransportProtocol"] = true.into();
        for (k, v) in extra.as_object().unwrap() { updater[k] = v.clone(); }
        let mut context = tauri::test::mock_context(tauri::test::noop_assets());
        context.config_mut().plugins.0.insert("updater".into(), updater);
        context.package_info_mut().version = "0.0.1".parse().unwrap(); // older than any release
        tauri::test::mock_builder().plugin(tauri_plugin_updater::Builder::new().build()).build(context).unwrap()
    }

    /// A local feed server that answers every request with `status` and counts requests.
    fn server(status: u16) -> (String, Arc<AtomicUsize>) {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/updates/latest.json", server.server_addr().to_ip().unwrap());
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = hits.clone();
        std::thread::spawn(move || for request in server.incoming_requests() {
            counter.fetch_add(1, Ordering::SeqCst);
            let _ = request.respond(tiny_http::Response::from_string("Not Found").with_status_code(status));
        });
        (url, hits)
    }

    #[test]
    fn settings_allow_checks_only_when_on_and_not_local_only() {
        let mut settings = AppSettings::default();
        assert!(wanted(&settings));
        settings.core.local_only = true;
        assert!(!wanted(&settings));
        settings.core.local_only = false;
        settings.check_updates = false;
        assert!(!wanted(&settings));
    }

    #[test]
    fn off_never_contacts_the_feed() {
        let (url, hits) = server(404);
        let app = app(&url, serde_json::json!({}));
        let dir = temp("updates-off");
        let staged = tauri::async_runtime::block_on(check(app.handle(), &|| false, &dir));
        assert_eq!(staged, None);
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn missing_or_unreachable_feed_is_quiet() {
        let (url, hits) = server(404);
        let app = app(&url, serde_json::json!({}));
        let events = Arc::new(AtomicUsize::new(0));
        let seen = events.clone();
        app.listen_any("status", move |_| { seen.fetch_add(1, Ordering::SeqCst); });
        let dir = temp("updates-404");
        assert_eq!(tauri::async_runtime::block_on(check(app.handle(), &|| true, &dir)), None);
        assert!(hits.load(Ordering::SeqCst) >= 1, "the feed was asked");
        // Nothing listens on a port that was just released.
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let unreachable = app_for(&format!("http://127.0.0.1:{port}/updates/latest.json"));
        assert_eq!(tauri::async_runtime::block_on(check(unreachable.handle(), &|| true, &dir)), None);
        assert_eq!(events.load(Ordering::SeqCst), 0, "no UI event");
        assert!(app.webview_windows().is_empty() && unreachable.webview_windows().is_empty(), "no window");
        assert!(!dir.join(STAGE).exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    fn app_for(url: &str) -> tauri::App<tauri::test::MockRuntime> { app(url, serde_json::json!({})) }

    fn tar_gz(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
        for (path, data) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, path, *data).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn tar_gz_update_replaces_executable_and_libraries_on_quit() {
        let dir = temp("updates-install");
        std::fs::write(dir.join("mouthy"), "old app").unwrap();
        std::fs::write(dir.join("libsherpa-onnx-c-api.so"), "old lib").unwrap();
        std::fs::write(dir.join("settings-unrelated.txt"), "keep").unwrap();
        let archive = tar_gz(&[("mouthy/mouthy", b"new app"), ("mouthy/libsherpa-onnx-c-api.so", b"new lib"),
            ("mouthy/install.sh", b"#!/bin/sh"), ("mouthy/icon.png", b"png")]);
        stage(&archive, "0.2.0", &dir).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("mouthy")).unwrap(), "old app", "nothing changes before quit");
        assert_eq!(apply_over(&dir, true, "0.0.1"), Ok(true));
        assert_eq!(std::fs::read_to_string(dir.join("mouthy")).unwrap(), "new app");
        assert_eq!(std::fs::read_to_string(dir.join("libsherpa-onnx-c-api.so")).unwrap(), "new lib");
        assert_eq!(std::fs::read_to_string(dir.join("settings-unrelated.txt")).unwrap(), "keep");
        assert!(!dir.join("install.sh").exists() && !dir.join("icon.png").exists() && !dir.join(STAGE).exists());
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(dir.join("mouthy")).unwrap().permissions().mode() & 0o777, 0o755);
        assert_eq!(apply_over(&dir, true, "0.0.1"), Ok(false), "nothing left to apply");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_stage_that_is_not_newer_than_the_running_version_is_thrown_away() {
        let dir = temp("updates-older");
        std::fs::write(dir.join(EXE), "running app").unwrap();
        let entry = format!("mouthy/{EXE}");
        for (staged, running) in [("0.1.6", "0.1.6"), ("0.1.5", "0.1.6"), ("garbage", "0.1.6")] {
            stage(&tar_gz(&[(entry.as_str(), b"other app")]), staged, &dir).unwrap();
            assert_eq!(apply_over(&dir, true, running), Ok(false), "{staged} does not replace {running}");
            assert_eq!(std::fs::read_to_string(dir.join(EXE)).unwrap(), "running app");
            assert!(!dir.join(STAGE).exists(), "the {staged} stage is removed");
        }
        stage(&tar_gz(&[(entry.as_str(), b"newer app")]), "0.1.7", &dir).unwrap();
        assert_eq!(apply_over(&dir, true, "0.1.6"), Ok(true));
        assert_eq!(std::fs::read_to_string(dir.join(EXE)).unwrap(), "newer app");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn turning_updates_off_discards_a_waiting_update() {
        let dir = temp("updates-turned-off");
        std::fs::write(dir.join(EXE), "old app").unwrap();
        let entry = format!("mouthy/{EXE}");
        stage(&tar_gz(&[(entry.as_str(), b"new app")]), "0.2.0", &dir).unwrap();
        assert_eq!(apply(&dir, false), Ok(false), "nothing installs once updates are off");
        assert_eq!(std::fs::read_to_string(dir.join(EXE)).unwrap(), "old app");
        assert!(!dir.join(STAGE).exists(), "the waiting update is thrown away");
        assert_eq!(apply_over(&dir, true, "0.0.1"), Ok(false), "and does not come back when they are on again");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn zip_and_bad_archives_stage_only_what_belongs() {
        let dir = temp("updates-zip");
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for (name, data) in [("Mouthy/mouthy", b"app" as &[u8]), ("Mouthy/../../escape.so", b"lib"), ("Mouthy/readme.txt", b"x")] {
            zip.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            std::io::Write::write_all(&mut zip, data).unwrap();
        }
        let bytes = zip.finish().unwrap().into_inner();
        stage(&bytes, "0.2.0", &dir).unwrap();
        assert!(dir.join(STAGE).join("mouthy").exists() && !dir.join(STAGE).join("readme.txt").exists());
        assert!(!dir.parent().unwrap().join("escape.so").exists(), "no entry leaves the stage folder");
        // An archive without the executable, or something that is not an archive, stages nothing.
        assert!(stage(&tar_gz(&[("mouthy/libx.so", b"lib")]), "0.3.0", &dir).is_err());
        assert!(stage(b"not an archive", "0.3.0", &dir).is_err());
        assert!(!dir.join(STAGE).exists());
        assert_eq!(apply_over(&dir, true, "0.0.1"), Ok(false));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Windows can't overwrite a running program or a loaded library, only rename it. A running copy
    /// of this test binary (with the DLLs it loads) stands in for an installed Mouthy.
    #[cfg(windows)]
    #[test]
    fn windows_swap_replaces_a_running_program_and_loaded_libraries() {
        let dir = temp("updates-windows");
        let here = std::env::current_exe().unwrap();
        std::fs::copy(&here, dir.join(EXE)).unwrap();
        for dll in std::fs::read_dir(here.parent().unwrap()).unwrap().flatten() {
            if dll.file_name().to_string_lossy().ends_with(".dll") { std::fs::copy(dll.path(), dir.join(dll.file_name())).unwrap(); }
        }
        let mut running = std::process::Command::new(dir.join(EXE))
            .args(["--ignored", "--exact", "updates::tests::hold_open_for_windows_swap"]).spawn().unwrap();
        std::thread::sleep(Duration::from_secs(2));
        assert!(running.try_wait().unwrap().is_none(), "the stand-in is running");
        assert!(std::fs::write(dir.join(EXE), "x").is_err(), "a running program cannot be overwritten");
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for (name, data) in [("Mouthy/mouthy.exe", b"new app" as &[u8]), ("Mouthy/onnxruntime.dll", b"new lib")] {
            zip.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            std::io::Write::write_all(&mut zip, data).unwrap();
        }
        stage(&zip.finish().unwrap().into_inner(), "0.2.0", &dir).unwrap();
        assert_eq!(apply_over(&dir, true, "0.0.1"), Ok(true));
        assert_eq!(std::fs::read(dir.join(EXE)).unwrap(), b"new app");
        assert_eq!(std::fs::read(dir.join("onnxruntime.dll")).unwrap(), b"new lib");
        assert!(dir.join("mouthy.exe.old").is_file() && !dir.join(STAGE).exists());
        let _ = running.kill();
        let _ = running.wait();
        remove_replaced(&dir);
        assert!(!dir.join("mouthy.exe.old").exists() && !dir.join("onnxruntime.dll.old").exists(), "next start cleans up");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "helper: the running program in windows_swap_replaces_a_running_program_and_loaded_libraries"]
    fn hold_open_for_windows_swap() { std::thread::sleep(Duration::from_secs(30)); }

    /// Release check against real packages: `MOUTHY_TEST_FEED=<dist folder> cargo test -p mouthy-app signed_feed`.
    /// Serves `latest.json` and this platform's archive locally to a copy that thinks it is 0.0.1 and
    /// expects the update to stage; a flipped byte in the archive, or a feed announcing another version
    /// than the one signed, stages nothing. Both platforms' archives are checked against their signatures.
    #[test]
    fn signed_feed_installs_and_tampered_archive_fails() {
        let Some(dist) = std::env::var_os("MOUTHY_TEST_FEED").map(PathBuf::from) else { return };
        let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(dist.join("latest.json")).unwrap()).unwrap();
        let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let pubkey = conf["plugins"]["updater"]["pubkey"].as_str().unwrap();
        let file_of = |platform: &str| dist.join(manifest["platforms"][platform]["url"].as_str().unwrap().rsplit('/').next().unwrap());
        for platform in ["linux-x86_64", "windows-x86_64"] {
            let data = std::fs::read(file_of(platform)).unwrap();
            let signature = manifest["platforms"][platform]["signature"].as_str().unwrap();
            assert!(verify(pubkey, signature, &data), "{platform} signature verifies");
            let mut tampered = data.clone();
            let middle = tampered.len() / 2;
            tampered[middle] ^= 1;
            assert!(!verify(pubkey, signature, &tampered), "{platform} tampered archive fails");
        }
        #[cfg(target_os = "linux")]
        for (tamper, announce) in [(false, None), (true, None), (false, Some("99.0.0"))] {
            let mut archive = std::fs::read(file_of("linux-x86_64")).unwrap();
            if tamper { let middle = archive.len() / 2; archive[middle] ^= 1; }
            let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
            let base = format!("http://{}", server.server_addr().to_ip().unwrap());
            let mut served = manifest.clone();
            if let Some(version) = announce { served["version"] = version.into(); }
            served["platforms"]["linux-x86_64"]["url"] = format!("{base}/archive.tar.gz").into();
            let feed = serde_json::to_vec(&served).unwrap();
            std::thread::spawn(move || for request in server.incoming_requests() {
                let body = if request.url().ends_with("latest.json") { feed.clone() } else { archive.clone() };
                let _ = request.respond(tiny_http::Response::from_data(body));
            });
            let app = app(&format!("{base}/updates/latest.json"), serde_json::json!({}));
            let dir = temp("updates-signed");
            let staged = tauri::async_runtime::block_on(check(app.handle(), &|| true, &dir));
            if tamper || announce.is_some() {
                assert_eq!(staged, None);
                assert!(!dir.join(STAGE).exists());
            } else {
                assert_eq!(staged.as_deref(), manifest["version"].as_str());
                assert!(dir.join(STAGE).join("mouthy").is_file());
            }
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    fn verify(pubkey: &str, signature: &str, data: &[u8]) -> bool {
        use base64::Engine;
        let decode = |s: &str| String::from_utf8(base64::engine::general_purpose::STANDARD.decode(s).unwrap()).unwrap();
        let key = minisign_verify::PublicKey::decode(&decode(pubkey)).unwrap();
        let signature = minisign_verify::Signature::decode(&decode(signature)).unwrap();
        key.verify(data, &signature, true).is_ok()
    }
}
