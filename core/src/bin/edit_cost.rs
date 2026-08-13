//! Times the phases of one local edit against a real app directory.
//!
//! Every keystroke pause turns into a core write, and the UI cannot show the
//! result until it finishes, so this is the number that decides whether the
//! editor feels instant. Run it against a copy of a real workspace — the costs
//! that matter here scale with accumulated state (a never-drained pending sync
//! queue, the number of scheme files), not with the size of the edit.
//!
//!     cargo run --bin edit-cost -- <app-dir> [iterations]
//!
//! `<app-dir>` is the directory holding `workspace/`, `sync-state.json` and
//! `sync-crdt-state.json` (the app's Application Support/KnotQMobile).

use std::path::PathBuf;
use std::time::Instant;

use knotq_mobile_core::MobileCore;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(app_dir) = args.next() else {
        eprintln!("usage: edit-cost <app-dir> [iterations]");
        std::process::exit(2);
    };
    let iterations: usize = args.next().and_then(|v| v.parse().ok()).unwrap_or(5);

    let dir = PathBuf::from(&app_dir);
    let sync_state = dir.join("sync-state.json");
    let queued = std::fs::read(&sync_state)
        .ok()
        .map(|bytes| bytes.len())
        .unwrap_or(0);
    println!(
        "app dir: {}\nsync-state.json: {} KB",
        dir.display(),
        queued / 1024
    );

    let opened = Instant::now();
    let core = match MobileCore::new(app_dir) {
        Ok(core) => core,
        Err(error) => {
            eprintln!("could not open the core: {error:?}");
            std::process::exit(1);
        }
    };
    println!("open: {} ms", opened.elapsed().as_millis());

    let today = chrono::Local::now().date_naive().to_string();
    let snapshot = match core.snapshot(Some(today.clone()), 0) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!("could not read a snapshot: {error:?}");
            std::process::exit(1);
        }
    };
    let Some(scheme) = snapshot.schemes.first() else {
        eprintln!("workspace has no schemes to edit");
        std::process::exit(1);
    };
    println!("editing scheme: {}", scheme.name);

    let mut timings = Vec::new();
    for i in 0..iterations {
        let started = Instant::now();
        if let Err(error) = core.add_item(
            scheme.id.clone(),
            format!("edit-cost probe {i}"),
            Some("blank".to_string()),
            None,
            None,
        ) {
            eprintln!("edit failed: {error:?}");
            std::process::exit(1);
        }
        timings.push(started.elapsed().as_secs_f64() * 1000.0);
    }

    timings.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = timings[timings.len() / 2];
    println!(
        "edit: median {:.0} ms  (min {:.0}, max {:.0}, n={})",
        median,
        timings[0],
        timings[timings.len() - 1],
        timings.len()
    );
    let after = std::fs::read(&sync_state)
        .ok()
        .map(|bytes| bytes.len())
        .unwrap_or(0);
    println!(
        "sync-state.json after: {} KB (grew {} KB over {} edits)",
        after / 1024,
        (after.saturating_sub(queued)) / 1024,
        iterations
    );
}
