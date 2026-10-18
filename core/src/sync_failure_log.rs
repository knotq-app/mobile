//! A small, durable record of sync transport failures.
//!
//! A sync failure used to leave two traces: an alert that carried only the outermost
//! error context, and an `eprintln!` that goes to Xcode's console (nowhere in a
//! store build) and to `knotq-sync-debug.log`, which is noisy, truncated whole when
//! it fills, and not reachable from a store install. By the time anyone looked, the
//! reason a pull failed (timeout, truncated gzip, undecodable field) was gone.
//!
//! This file holds one line per failure, bounded by rotation, so the shells can
//! offer it for sharing. It records status, headers, timings and the error chain,
//! never workspace content.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

pub(crate) const SYNC_FAILURE_LOG_FILE: &str = "knotq-sync-failures.log";
/// One rotation keeps the newest ~512 KiB: when the live file passes this it is
/// renamed over `<name>.1`, so a failure loop cannot grow the disk footprint.
const ROTATE_AT_BYTES: u64 = 256 * 1024;
/// A single entry is clipped so one pathological error string cannot fill a file.
const MAX_ENTRY_BYTES: usize = 4 * 1024;

static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();
static WRITE_LOCK: Mutex<()> = Mutex::new(());

/// Point the log at the app directory. First call wins; later calls are ignored.
pub(crate) fn init(app_dir: &Path) {
    let _ = LOG_PATH.set(app_dir.join(SYNC_FAILURE_LOG_FILE));
}

/// Append one entry. Failures are swallowed: diagnostics must never turn a sync
/// failure into a different failure.
pub(crate) fn record(kind: &str, detail: &str) {
    let Some(path) = LOG_PATH.get() else {
        return;
    };
    let _guard = WRITE_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let line = format_entry(kind, detail);
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() >= ROTATE_AT_BYTES) {
        let mut rotated = path.clone().into_os_string();
        rotated.push(".1");
        let _ = std::fs::rename(path, rotated);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = file.write_all(line.as_bytes());
    }
}

fn format_entry(kind: &str, detail: &str) -> String {
    let flattened: String = detail
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let clipped = match flattened.char_indices().nth(MAX_ENTRY_BYTES) {
        Some((cut, _)) => &flattened[..cut],
        None => flattened.as_str(),
    };
    format!(
        "{} core={} {kind}: {clipped}\n",
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        env!("CARGO_PKG_VERSION"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_are_single_line_and_clipped() {
        let entry = format_entry("sync-response", &format!("a\nb\r{}", "x".repeat(10_000)));
        assert_eq!(entry.matches('\n').count(), 1);
        assert!(entry.len() < MAX_ENTRY_BYTES + 128);
        assert!(entry.contains("sync-response: a b "));
    }
}
