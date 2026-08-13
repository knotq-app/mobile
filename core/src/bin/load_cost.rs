//! Times cold launch against a real app directory: opening the core and
//! building the first snapshot.
//!
//! Nothing renders until both finish — `AppModel.init` opens the core on the
//! main actor and `ContentView` shows its loading state until the first
//! snapshot publishes — so this is the number behind "the app takes seconds to
//! start". Set `KNOTQ_LOAD_TIMING=1` for the per-phase split inside `open`.
//!
//!     cargo run --release --bin load-cost -- <app-dir> [iterations]
//!
//! Run it against a *copy* of a real app directory: opening the core writes
//! (a startup save, a history snapshot), and the costs that matter here scale
//! with accumulated state rather than with anything the run does.

use std::path::PathBuf;
use std::time::Instant;

use knotq_mobile_core::MobileCore;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(app_dir) = args.next() else {
        eprintln!("usage: load-cost <app-dir> [iterations]");
        std::process::exit(2);
    };
    let iterations: usize = args.next().and_then(|v| v.parse().ok()).unwrap_or(3);

    let dir = PathBuf::from(&app_dir);
    println!("app dir: {}", dir.display());
    report_size(&dir);

    let today = chrono::Local::now().date_naive().to_string();
    let mut opens = Vec::new();
    let mut snapshots = Vec::new();
    let mut pendings = Vec::new();
    let mut delivereds = Vec::new();

    for _ in 0..iterations {
        let started = Instant::now();
        let core = match MobileCore::new(app_dir.clone()) {
            Ok(core) => core,
            Err(error) => {
                eprintln!("could not open the core: {error:?}");
                std::process::exit(1);
            }
        };
        opens.push(started.elapsed().as_secs_f64() * 1000.0);

        let started = Instant::now();
        let snapshot = match core.snapshot_with_daily_history(Some(today.clone()), 0, 7) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                eprintln!("could not read a snapshot: {error:?}");
                std::process::exit(1);
            }
        };
        snapshots.push(started.elapsed().as_secs_f64() * 1000.0);

        // The rest of the first `AppModel.refresh()` — the UI waits on all three.
        let started = Instant::now();
        let pending = core.pending_notifications(None, 14).unwrap_or_default();
        pendings.push(started.elapsed().as_secs_f64() * 1000.0);
        let started = Instant::now();
        let _ = core.delivered_notifications_to_clear(None);
        delivereds.push(started.elapsed().as_secs_f64() * 1000.0);

        if opens.len() == 1 {
            println!(
                "schemes={} daily entries={} upcoming={} pending notifications={}",
                snapshot.schemes.len(),
                snapshot.daily.len(),
                snapshot.calendar.upcoming.len(),
                pending.len()
            );
        }
    }

    summarize("open", &mut opens);
    summarize("snapshot", &mut snapshots);
    summarize("pendingNotifications", &mut pendings);
    summarize("deliveredToClear", &mut delivereds);
    let total = median(&mut opens.clone())
        + median(&mut snapshots.clone())
        + median(&mut pendings.clone())
        + median(&mut delivereds.clone());
    println!("{:<22} {:>8.0} ms", "TOTAL (median)", total);
}

fn summarize(label: &str, timings: &mut [f64]) {
    let median = median(timings);
    println!(
        "{label:<22} {median:>8.0} ms  (min {:.0}, max {:.0}, n={})",
        timings[0],
        timings[timings.len() - 1],
        timings.len()
    );
}

fn median(timings: &mut [f64]) -> f64 {
    timings.sort_by(|a, b| a.partial_cmp(b).unwrap());
    timings[timings.len() / 2]
}

fn report_size(dir: &std::path::Path) {
    let mut files = 0u64;
    let mut bytes = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(path) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&path) else {
            continue;
        };
        for entry in entries.flatten() {
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => stack.push(entry.path()),
                Ok(_) => {
                    files += 1;
                    bytes += entry.metadata().map(|m| m.len()).unwrap_or(0);
                }
                Err(_) => {}
            }
        }
    }
    println!("{files} files, {} KB on disk", bytes / 1024);
}
