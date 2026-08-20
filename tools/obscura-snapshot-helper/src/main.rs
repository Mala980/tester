//! Generates the architecture-correct V8 startup snapshot for Obscura.
//!
//! Obscura's own build.rs bakes a snapshot with the *build host's* V8, which
//! is architecture-specific and crashes on the aarch64 device. This helper is
//! compiled for aarch64-unknown-linux-gnu (the v8 crate downloads its PREBUILT
//! linux-arm64 library — no V8 source compile) and executed under
//! qemu-aarch64 on the x86_64 CI runner, reproducing exactly what obscura's
//! build.rs does (bootstrap.js executed into a fresh runtime, serialized).
//!
//! usage: obscura-snapshot-helper <bootstrap.js> <output.bin>

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: obscura-snapshot-helper <bootstrap.js> <output.bin>");
        std::process::exit(1);
    }
    let bootstrap = fs::read_to_string(&args[1]).expect("read bootstrap.js");
    let out = PathBuf::from(&args[2]);

    let bootstrap_for_cb = bootstrap.clone();
    let output = deno_core::snapshot::create_snapshot(
        deno_core::snapshot::CreateSnapshotOptions {
            cargo_manifest_dir: env!("CARGO_MANIFEST_DIR"),
            startup_snapshot: None,
            skip_op_registration: true,
            extensions: vec![],
            extension_transpiler: None,
            with_runtime_cb: Some(Box::new(move |runtime| {
                runtime
                    .execute_script("<obscura:bootstrap>", bootstrap_for_cb.clone())
                    .expect("bootstrap.js should not fail during snapshot creation");
            })),
        },
        None,
    )
    .expect("Failed to create V8 snapshot");

    fs::write(&out, &*output.output).expect("write snapshot");
    eprintln!(
        "snapshot helper: wrote {} bytes to {}",
        output.output.len(),
        out.display()
    );
    eprintln!("snapshot helper: files loaded: {:?}", output.files_loaded_during_snapshot);
}