#!/usr/bin/env bash
#
# Connected Android startup/navigation smoke test.
#
# This lives in a file, not in the workflow's `script:` input, because
# `reactivecircus/android-emulator-runner` splits that input on newlines and
# runs every line as its own `/usr/bin/sh -c '<line>'`. On Ubuntu /usr/bin/sh
# is dash, so a multi-line script loses all shell state between lines and
# `set -o pipefail` dies with "Illegal option -o pipefail". The workflow
# therefore invokes this file as a single line, and bash reads the whole thing.
#
# Run from the workspace root (the directory that holds `app/`).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

check_frame_budget() {
  local app_pid skipped davey
  # The connected test runner may tear the target process down before this
  # post-test check. Reinstall and launch the already built debug APK so the
  # check has an authoritative KnotQ PID; otherwise system UI/launcher frame
  # warnings can be mistaken for an app regression.
  adb install -r android/app/build/outputs/apk/debug/app-debug.apk >/dev/null
  adb shell pm grant com.enigmadux.knotq android.permission.POST_NOTIFICATIONS 2>/dev/null || true
  adb logcat -c
  adb shell am start -S -W -n com.enigmadux.knotq/.MainActivity >/dev/null
  # Let the first native/JIT render settle before collecting the steady-state
  # UI-thread signal. Cold-start latency is gated separately below; mixing
  # startup compilation into this check makes the result depend on the
  # emulator's software renderer.
  sleep 10
  adb logcat -c
  sleep 2
  app_pid="$(adb shell pidof com.enigmadux.knotq | tr -d '\r' | awk '{print $1}')"
  test -n "$app_pid"
  skipped="$(adb logcat -d -v threadtime | awk -v pid="$app_pid" '$3 == pid && / Choreographer: Skipped [0-9]+ frames/ { print }')"
  davey="$(adb logcat -d -v threadtime | awk -v pid="$app_pid" '$3 == pid && / HWUI.*Davey!/ { print }')"
  if test -n "$skipped"; then
    echo "KnotQ skipped frames on the main thread (pid=$app_pid):"
    echo "$skipped"
    return 1
  fi
  # HWUI's Davey line includes GPU/driver upload time and is especially noisy
  # on software-rendered CI emulators during the first JIT/native-library
  # frame. Keep it visible for diagnosis, while the PID-filtered Choreographer
  # signal remains the hard regression gate for app work on the UI thread.
  if test -n "$davey"; then
    echo "::warning::KnotQ HWUI frame telemetry on pid=$app_pid:"
    echo "$davey"
  fi
}

check_cold_start_budget() {
  local total_ms
  total_ms="$(adb shell am start -S -W -n com.enigmadux.knotq/.MainActivity | awk -F': ' '/TotalTime/ {print $2}' | tr -d '\r')"
  test -n "$total_ms"
  test "$total_ms" -le 15000
}

restore_motion() {
  adb shell settings put global animator_duration_scale 1
  adb shell settings put global transition_animation_scale 1
  adb shell settings put global window_animation_scale 1
}

# Exercise both the ordinary snap/slide path and Android's reduced-motion path.
# Restore the emulator setting even when the second run fails so later workflow
# steps are not contaminated.
adb shell settings put global animator_duration_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global window_animation_scale 1
trap restore_motion EXIT

adb logcat -c
./android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon --console=plain
check_frame_budget
check_cold_start_budget

adb logcat -c
adb shell settings put global animator_duration_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global window_animation_scale 0
./android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon --console=plain
check_frame_budget
check_cold_start_budget
