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

# `sys.boot_completed` — the only thing the emulator action waits for — flips
# long before the device is usable. Play services then spends another minute
# staging modules while the package manager thrashes; the run that first got
# this far recorded 18-second Looper dispatches, `Long monitor contention ...
# waiters=12` and the system ANR-killing its own background apps. Instrumenting
# into that storm gets the app process killed before a single test is
# enumerated, which Gradle reports only as "Starting 0 tests ... Instrumentation
# run failed due to Process crashed".
#
# The device's own load average is the honest signal for "the boot storm is
# over". Bounded, because a runner that never settles should still run the test
# and report a real result rather than hang.
wait_for_device_idle() {
  local deadline=$((SECONDS + 420)) load
  adb wait-for-device
  while [ "$SECONDS" -lt "$deadline" ]; do
    load="$(adb shell cat /proc/loadavg 2>/dev/null | tr -d '\r' | awk '{print int($1)}')"
    if [ -n "$load" ] && [ "$load" -le 2 ]; then
      echo "Device settled (load average ${load})."
      return 0
    fi
    sleep 10
  done
  echo "::warning::Emulator never went idle (load average ${load:-unknown}); running the smoke test anyway."
}

# Gradle reports an instrumentation failure as "Process crashed" and a path to
# an HTML report that never leaves the runner, which says nothing about why the
# app died. The device log does, so print it here rather than losing it with
# the emulator.
run_connected_tests() {
  if ./android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon --console=plain; then
    return 0
  fi
  echo "::group::logcat crash buffer"
  adb logcat -d -b crash || true
  echo "::endgroup::"
  echo "::group::logcat, last 400 lines"
  adb logcat -d -v threadtime | tail -400 || true
  echo "::endgroup::"
  return 1
}

# The AVD comes out of `actions/cache` with a boot snapshot, and that snapshot is
# taken AFTER a smoke run — so it still has KnotQ installed, signed with the
# debug keystore of whichever runner saved it. Every runner generates its own
# `~/.android/debug.keystore`, so installing over that copy fails with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE ("signatures do not match") before a single
# test runs. The run that seeds the cache passes and every run that restores it
# fails, which is exactly the pattern the scheduled runs showed. Start from a
# device with no KnotQ on it; a missing package is not an error.
remove_previous_installs() {
  local package
  for package in com.enigmadux.knotq com.enigmadux.knotq.test; do
    adb uninstall "$package" >/dev/null 2>&1 || true
  done
}

wait_for_device_idle
remove_previous_installs

# Exercise both the ordinary snap/slide path and Android's reduced-motion path.
# Restore the emulator setting even when the second run fails so later workflow
# steps are not contaminated.
adb shell settings put global animator_duration_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global window_animation_scale 1
trap restore_motion EXIT

adb logcat -c
run_connected_tests
check_frame_budget
check_cold_start_budget

adb logcat -c
adb shell settings put global animator_duration_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global window_animation_scale 0
run_connected_tests
check_frame_budget
check_cold_start_budget
