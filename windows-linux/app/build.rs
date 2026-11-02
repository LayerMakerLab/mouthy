fn main() {
    // Linux: load the sherpa-onnx/onnxruntime libraries shipped beside the binary (or in ../lib/mouthy).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN:$ORIGIN/../lib/mouthy");
    }
    // Updates are compiled in only by package.sh (see updates::install_dir).
    println!("cargo:rerun-if-env-changed=MOUTHY_UPDATES");
    tauri_build::build()
}
