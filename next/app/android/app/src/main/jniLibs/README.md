# Iroh Android Native Library

`arm64-v8a/libiroh_ffi.so` is built from `n0-computer/iroh-ffi` tag `v1.0.0`.
The Maven artifact `computer.iroh:iroh:1.0.0` provides the Kotlin/JVM binding
classes but does not currently package Android ABI libraries, so the app ships
the arm64 library here.

Build provenance for the checked-in binary:

```sh
git clone --depth 1 --branch v1.0.0 https://github.com/n0-computer/iroh-ffi.git /tmp/iroh-ffi
cd /tmp/iroh-ffi

NDK="$ANDROID_HOME/ndk/27.1.12297006"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"

RUSTUP_HOME=/tmp/openvsmobile-rustup \
CARGO_HOME=/tmp/openvsmobile-cargo \
PATH="/tmp/openvsmobile-cargo/bin:$TOOLCHAIN:$PATH" \
CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android24-clang" \
CXX_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android24-clang++" \
AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar" \
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android24-clang" \
cargo build --release --lib --target aarch64-linux-android

APP_JNILIBS=/path/to/openvsmobile/next/app/android/app/src/main/jniLibs
mkdir -p "$APP_JNILIBS/arm64-v8a"
cp target/aarch64-linux-android/release/libiroh_ffi.so \
  "$APP_JNILIBS/arm64-v8a/libiroh_ffi.so"
"$TOOLCHAIN/llvm-strip" "$APP_JNILIBS/arm64-v8a/libiroh_ffi.so"
```

Only arm64 is shipped for now. On other Android ABIs the Flutter app still
starts, but the optional Iroh transport returns `IROH_UNAVAILABLE`.
The release workflow checks that this file is an Android/aarch64 ELF before
building the APK and publishes only the arm64-v8a split while this remains true.
