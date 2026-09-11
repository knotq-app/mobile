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

# Android CI runs on Linux while local development is commonly macOS. Resolve
# the NDK host directory from the platform and verify it exists instead of
# silently selecting a Darwin toolchain on Ubuntu.
case "$(uname -s)" in
  Darwin)
    case "$(uname -m)" in
      arm64) HOST_CANDIDATES=("darwin-arm64" "darwin-x86_64") ;;
      *) HOST_CANDIDATES=("darwin-x86_64" "darwin-arm64") ;;
    esac
    ;;
  Linux)
    case "$(uname -m)" in
      aarch64|arm64) HOST_CANDIDATES=("linux-aarch64" "linux-x86_64") ;;
      *) HOST_CANDIDATES=("linux-x86_64" "linux-aarch64") ;;
    esac
    ;;
  *)
    echo "Unsupported host platform for Android NDK: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

HOST_TAG=""
for CANDIDATE in "${HOST_CANDIDATES[@]}"; do
  if [[ -d "$NDK/toolchains/llvm/prebuilt/$CANDIDATE" ]]; then
    HOST_TAG="$CANDIDATE"
    break
  fi
done
if [[ -z "$HOST_TAG" ]]; then
  echo "Android NDK LLVM toolchain not found under $NDK/toolchains/llvm/prebuilt" >&2
  exit 1
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
export CC_aarch64_linux_android="$TOOLCHAIN/aarch64-linux-android26-clang"
export CC_armv7_linux_androideabi="$TOOLCHAIN/armv7a-linux-androideabi26-clang"
export CC_i686_linux_android="$TOOLCHAIN/i686-linux-android26-clang"
export CC_x86_64_linux_android="$TOOLCHAIN/x86_64-linux-android26-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android26-clang"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$TOOLCHAIN/armv7a-linux-androideabi26-clang"
export CARGO_TARGET_I686_LINUX_ANDROID_LINKER="$TOOLCHAIN/i686-linux-android26-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$TOOLCHAIN/x86_64-linux-android26-clang"

# Align ELF LOAD segments to 16 KB pages on every ABI so the libs load on
# 16 KB page-size devices (Play requirement), independent of the NDK default.
PAGE_ALIGN="-C link-arg=-Wl,-z,max-page-size=16384"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$PAGE_ALIGN"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_RUSTFLAGS="$PAGE_ALIGN"
export CARGO_TARGET_I686_LINUX_ANDROID_RUSTFLAGS="$PAGE_ALIGN"
export CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS="$PAGE_ALIGN"

cargo run --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --features bindgen-cli --bin uniffi-bindgen -- \
  generate "$MOBILE_ROOT/core/src/knotq_mobile_core.udl" \
  --config "$MOBILE_ROOT/core/uniffi.toml" \
  --language kotlin \
  --out-dir "$KOTLIN_DIR" \
  --no-format

# UniFFI currently emits trailing spaces on a few generated declarations. Keep
# generated sources reproducible across macOS/Linux so a successful build does
# not dirty the worktree or hide a real generated API change in whitespace.
find "$KOTLIN_DIR" -type f -name 'knotq_mobile_core.kt' -exec perl -pi -e 's/[ \t]+$//' {} +

ALL_ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")
ALL_TARGETS=("aarch64-linux-android" "armv7-linux-androideabi" "i686-linux-android" "x86_64-linux-android")

if [[ "$MODE" == "debug" && -n "${KNOTQ_DEBUG_ABIS:-}" ]]; then
  IFS=',' read -r -a REQUESTED_ABIS <<< "$KNOTQ_DEBUG_ABIS"
  ABIS=()
  TARGETS=()
  for REQUESTED_ABI in "${REQUESTED_ABIS[@]}"; do
    REQUESTED_ABI="${REQUESTED_ABI//[[:space:]]/}"
    case "$REQUESTED_ABI" in
      arm64-v8a)
        ABIS+=("arm64-v8a")
        TARGETS+=("aarch64-linux-android")
        ;;
      armeabi-v7a)
        ABIS+=("armeabi-v7a")
        TARGETS+=("armv7-linux-androideabi")
        ;;
      x86)
        ABIS+=("x86")
        TARGETS+=("i686-linux-android")
        ;;
      x86_64)
        ABIS+=("x86_64")
        TARGETS+=("x86_64-linux-android")
        ;;
      *)
        echo "Unknown KNOTQ_DEBUG_ABIS entry: $REQUESTED_ABI" >&2
        exit 1
        ;;
    esac
  done
else
  ABIS=("${ALL_ABIS[@]}")
  TARGETS=("${ALL_TARGETS[@]}")
fi

for INDEX in "${!ABIS[@]}"; do
  ABI="${ABIS[$INDEX]}"
  TARGET="${TARGETS[$INDEX]}"
  if [[ "$MODE" == "release" ]]; then
    # Release ships the same account/sync implementation as development builds.
    cargo build --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --target "$TARGET" --release --features accounts
    PROFILE_DIR="release"
  else
    # Android debug builds also include full sign-in/sync behavior. Use a
    # lightly optimized profile rather than Cargo's unoptimized `dev` profile;
    # the latter makes emulator install/JNA startup needlessly enormous while
    # still retaining assertions and useful symbol names.
    cargo build --manifest-path "$MOBILE_ROOT/Cargo.toml" -p knotq-mobile-core --target "$TARGET" --profile android-debug --features accounts
    PROFILE_DIR="android-debug"
  fi
  mkdir -p "$ANDROID_DIR/$ABI"
  cp "$MOBILE_ROOT/target/$TARGET/$PROFILE_DIR/libknotq_mobile_core.so" "$ANDROID_DIR/$ABI/"
done
