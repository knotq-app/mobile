import Foundation
import os

/// Timing for the three phases of a core write, so a laggy editor can be
/// attributed instead of guessed at.
///
/// Every local edit goes through `AppModel.mutate`, which applies the edit,
/// rebuilds the snapshot, and recomputes notifications — all on the bridge
/// queue, all before the UI sees anything. When that round trip gets slow the
/// symptom is generic ("it feels like it's polling"), and the three phases have
/// completely different causes, so measure them separately.
///
/// Logging only, and only over a threshold: writes are frequent (one per typing
/// pause) and a log line per keystroke would itself distort what it measures.
enum CoreTiming {
    private static let log = Logger(subsystem: "com.enigmadux.knotq", category: "core-timing")

    /// Anything slower than this is in the range a user notices on a screen
    /// transition, which is what makes it worth a line in the log.
    private static let threshold: TimeInterval = 0.05

    /// How long an editor pane rendered empty waiting for an in-flight write.
    static func deferredEditorLoad(seconds: TimeInterval) {
        log.info("deferred editor load \(Int(seconds * 1000))ms")
    }

    /// Cold-launch phases. Nothing is on screen until the first snapshot
    /// publishes — opening the core blocks the main actor and `ContentView`
    /// shows its loading state until then — so "the app takes seconds to open"
    /// has to be attributed across process start, the core open, and the first
    /// snapshot separately. Unlike `record`, these always log: a launch happens
    /// once, so the lines can't distort what they measure.
    ///
    /// `KNOTQ_LOAD_TIMING=1` in the environment adds the Rust-side split within
    /// the core open (stderr, so use `simctl launch --console`).
    static func launch(_ label: String, since: TimeInterval) {
        log.info("launch \(label) \(Int(since * 1000))ms")
    }

    /// Wall-clock seconds since `exec`, for launch marks. Read from the kernel
    /// rather than from a `static let` so it covers dyld, framework load and
    /// everything else that runs before any of our code does — which is exactly
    /// the part a "static start time" measurement hides.
    static func sinceProcessStart() -> TimeInterval {
        Date().timeIntervalSince1970 - processStartEpoch
    }

    private static let processStartEpoch: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else {
            return Date().timeIntervalSince1970
        }
        let started = info.kp_proc.p_starttime
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }()

    static func record(edit: TimeInterval, snapshot: TimeInterval, notifications: TimeInterval) {
        let total = edit + snapshot + notifications
        guard total >= threshold else { return }
        log.info("""
            core write \(Int(total * 1000))ms \
            (edit \(Int(edit * 1000))ms, \
            snapshot \(Int(snapshot * 1000))ms, \
            notifications \(Int(notifications * 1000))ms)
            """)
    }
}
