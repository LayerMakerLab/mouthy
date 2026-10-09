fn main() {
    // Linux: load the sherpa-onnx/onnxruntime libraries shipped beside the binary (or in ../lib/mouthy).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN:$ORIGIN/../lib/mouthy");
    }
    tauri_build::build()
}
