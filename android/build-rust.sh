#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$SCRIPT_DIR/app/src/main/jniLibs"
KOTLIN_DIR="$SCRIPT_DIR/app/src/main/kotlin"

if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
  NDK="$ANDROID_NDK_HOME"
else
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  NDK="$(find "$SDK/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 || true)"
fi

if [[ -z "${NDK:-}" || ! -d "$NDK" ]]; then
  echo "Android NDK not found. Install Android Studio NDK or set ANDROID_NDK_HOME." >&2
  exit 1
fi

if [[ -d "$NDK/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  HOST_TAG="darwin-arm64"
else
  HOST_TAG="darwin-x86_64"
fi

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
if [[ ! -d "$TOOLCHAIN" ]]; then
  echo "Android NDK toolchain not found at $TOOLCHAIN" >&2
  exit 1
fi

# The current Android CLI may unpack NDK symlinks as tiny text files on macOS.
# Restore those links before invoking the compiler wrappers.
while IFS= read -r LINK_FILE; do
  TARGET_NAME="$(cat "$LINK_FILE")"
  if [[ "$TARGET_NAME" =~ ^[A-Za-z0-9._+-]+$ && -e "$TOOLCHAIN/$TARGET_NAME" ]]; then
    rm -f "$LINK_FILE"
    ln -s "$TARGET_NAME" "$LINK_FILE"
  fi
done < <(find "$TOOLCHAIN" -maxdepth 1 -type f -size -32c)

export PATH="$TOOLCHAIN:$PATH"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
export AR_armv7_linux_androideabi="$TOOLCHAIN/llvm-ar"
export AR_i686_linux_android="$TOOLCHAIN/llvm-ar"
export AR_x86_64_linux_android="$TOOLCHAIN/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android26-clang"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$TOOLCHAIN/armv7a-linux-androideabi26-clang"
export CARGO_TARGET_I686_LINUX_ANDROID_LINKER="$TOOLCHAIN/i686-linux-android26-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$TOOLCHAIN/x86_64-linux-android26-clang"

cargo run --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --features bindgen-cli --bin uniffi-bindgen -- \
  generate "$MOBILE_ROOT/core/src/knotq_mobile_core.udl" \
  --config "$MOBILE_ROOT/core/uniffi.toml" \
  --language kotlin \
  --out-dir "$KOTLIN_DIR" \
  --no-format

ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")
TARGETS=("aarch64-linux-android" "armv7-linux-androideabi" "i686-linux-android" "x86_64-linux-android")

for INDEX in "${!ABIS[@]}"; do
  ABI="${ABIS[$INDEX]}"
  TARGET="${TARGETS[$INDEX]}"
  if [[ "$MODE" == "release" ]]; then
    cargo build --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --target "$TARGET" --release
    PROFILE_DIR="release"
  else
    cargo build --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --target "$TARGET"
    PROFILE_DIR="debug"
  fi
  mkdir -p "$ANDROID_DIR/$ABI"
  cp "$MOBILE_ROOT/target/$TARGET/$PROFILE_DIR/libknotq_mobile_core.so" "$ANDROID_DIR/$ABI/"
done
