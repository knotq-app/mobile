# KnotQ Mobile

Native mobile shells backed by the shared Rust workspace logic.

This directory is intentionally its own Git repository. The parent KnotQ repo ignores `mobile/`, while this repo keeps the iOS project, Android project, UniFFI bindings, and mobile Rust workspace together.

## Rust Core

`core` exposes the local KnotQ workspace through Mozilla UniFFI:

- `src/knotq_mobile_core.udl` is the typed mobile API contract.
- `build.rs` generates Rust UniFFI scaffolding for the core crate.
- Xcode and Gradle regenerate Swift/Kotlin bindings during their Rust build steps.

The core reuses the existing Rust crates for model, command application, JSON storage, calendar indexing, and search through path dependencies to the parent checkout.

## iOS

The iOS app is a standard Xcode project at `ios/KnotQMobile.xcodeproj`.
Open it directly in Xcode and run the `KnotQMobile` scheme.

Command-line checks:

```sh
cargo build -p knotq-mobile-core --target aarch64-apple-ios-sim
xcodebuild -project ios/KnotQMobile.xcodeproj \
  -scheme KnotQMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Android

The Android app is a standard Gradle Kotlin/Android project at `android`.

Build:

```sh
cd android
ANDROID_HOME=/path/to/android-sdk ANDROID_SDK_ROOT=/path/to/android-sdk ./gradlew :app:assembleDebug
```

`build-rust.sh` expects an Android NDK under `$ANDROID_NDK_HOME` or `$ANDROID_HOME/ndk/*`, builds all four Android Rust ABIs, and copies the generated `.so` files into `app/src/main/jniLibs`.

The debug APK is written to:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```
