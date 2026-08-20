# Native Android/Termux (aarch64) builds of Obscura + Lightpanda

Cross-compiles two Rust/Zig headless browsers to run **natively on Android
(Termux, arm64)** — dynamically linked against bionic libc, PIE, no glibc, no
wrapper. Patch/script approach follows
[Haris131/opencode-termux](https://github.com/Haris131/opencode-termux)
(NDK r28b, API 24, Zig stdlib awareness, `termux-elf-cleaner`-style fixes).

## What gets built

| Project | Language | V8 | Output |
|---|---|---|---|
| [obscura](https://github.com/h4ckf0r0day/obscura) | Rust (`deno_core` 0.350 → `v8` crate 137.3.0) | 13.7.x (from source) | `obscura`, `obscura-worker` (render / no-render / stealth) |
| [lightpanda](https://github.com/lightpanda-io/browser) | Zig 0.16.0 (zig-v8-fork, V8 14.9.207.35) | 14.9 (from source) | `lightpanda` |

Both binaries: `ELF64 aarch64`, `Type: DYN (PIE)`, `NEEDED libc.so/libdl.so`,
interpreter `/system/bin/linker64`.

## Install on Termux

```bash
curl -LO https://github.com/Mala980/tester/releases/latest/download/lightpanda-aarch64-android.tar.xz
tar xf lightpanda-aarch64-android.tar.xz && chmod +x lightpanda
./lightpanda --version

curl -LO https://github.com/Mala980/tester/releases/latest/download/obscura-aarch64-android.tar.xz
tar xf obscura-aarch64-android.tar.xz && chmod +x obscura obscura-worker
./obscura fetch https://example.com --eval "document.title"
```

- Keep `libc++_shared.so` (bundled in the obscura archives) next to the binary
  or run `pkg install libc++`.
- Needs a modern device: Android 7.0+ (API 24), kernel 5.10+.

## Build it yourself (CI)

Trigger **Build browsers for Android/Termux (aarch64)** (workflow_dispatch) →
releases a tarball per variant.

Pipeline:

```
Job "snapshots" (ubuntu-24.04-arm)
  ├─ obscura snapshot   (obscura-js build.rs, native arm64, prebuilt v8 crate lib)
  └─ lightpanda snapshot (zig snapshot_creator, native arm64, prebuilt v8 archive)
Job "build" (ubuntu-latest, x86_64, 8h)
  ├─ toolchain: Zig 0.16.0, NDK r28b, rust aarch64-linux-android
  ├─ V8 14.9 for android (zig-v8-fork + gn, NDK at third_party/android_toolchain/ndk)
  ├─ lightpanda: zig build -Dtarget=aarch64-linux-android --libc <ndk> + ELF fixes
  ├─ obscura: V8_FROM_SOURCE=1 cargo build --target aarch64-linux-android (×3 variants)
  └─ package + release
```

## Layout

```
scripts/
  env.sh                        # pins (zig, ndk, api, v8 versions) + helpers
  setup-toolchain.sh            # zig 0.16.0 + NDK r28b + rust target + libc file
  build-lightpanda-v8-android.sh# V8 14.9 for android via patched zig-v8-fork
  build-lightpanda-android.sh   # lightpanda zig build (html5ever cross, PIE, ELF fix)
  build-obscura-android.sh      # obscura cargo build (snapshot injection, 3 variants)
  snapshot-arm64.sh             # ARM64 job: arch-correct V8 snapshots
  package.sh                    # tar.xz packages
  elf-fix.py                    # TLS/RELRO/DF_1_* fixes (termux-elf-cleaner equivalent)
patches/
  zig-v8-fork/android.patch     # gn args target_os=android / target_cpu=arm64
  lightpanda/build.zig-android.patch  # PIE+dynamic exe, html5ever cross-compile
  obscura/build-rs-snapshot.patch     # OBSCURA_SNAPSHOT_FILE/OUT injection
.github/workflows/build-android.yml   # full pipeline + release
```

## Key tricks (documented for reuse)

- **Zig 0.16 + bionic**: Zig ships no bionic libc. A `libc.txt` pointing at the
  NDK sysroot (`usr/lib/aarch64-linux-android/24/`) plus `--libc` and
  `exe.linkage = .dynamic; exe.pie = true` produce a proper bionic PIE.
- **V8 for android**: `target_os="android"` gn args; NDK must be symlinked to
  `v8/third_party/android_toolchain/ndk` (V8's DEPS doesn't fetch it).
- **Arch-specific V8 snapshots**: generated natively on an ARM64 runner and
  injected via `OBSCURA_SNAPSHOT_FILE` (obscura) / `-Dsnapshot_path` or
  startup creation (lightpanda).
- **ELF fixes**: `PT_TLS p_align=64`, `PT_GNU_RELRO align=16384`, sanitized
  `DF_1_*` flags — what `termux-elf-cleaner` does on device.