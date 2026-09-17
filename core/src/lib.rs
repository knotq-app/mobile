use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, NaiveDate, Utc};
use knotq_commands::{
    event_popup_commit_commands, event_popup_delete_command, Command, DateEditScope,
    EventDeleteScope, EventPopupDraft, WorkspaceCommandExt,
};
use knotq_index::query::{SearchHitStatus, SearchOptions, SearchTarget};
use knotq_index::IndexedWorkspace;
use knotq_model::{
    daily_queue_scheme_id, daily_queue_sync_metadata, AppSettings, CalendarProvider, FolderId,
    GoogleOAuthAccount, ImageAssetFormat, ImageInline, Inline, Item, ItemContent, ItemId,
    ItemMarker, NodeRef, NotificationDefaults, OccurrenceId, OperationId, Recurrence, Scheme,
    SchemeId, SchemeSource, Table, UpcomingDisplaySettings, Workspace, DAILY_QUEUE_COLOR_INDEX,
};
use knotq_notifications::{
    completed_notification_keys, compute_due_notifications_with_lead_times,
    expired_event_notification_keys, DEFAULT_DURABLE_NOTIFICATION_LIMIT,
};
use knotq_state::{
    daily_queue_carryover_command, daily_queue_initial_start, daily_queue_scheme_name,
    last_nonempty_daily_queue_day, make_default_workspace, mark_past_event_completion_keys_done,
    past_event_completion_keys, CalendarOccurrenceKey, RetainedCompletedItems,
    DAILY_QUEUE_CARRYOVER_LOOKBACK_DAYS,
};
use knotq_storage_json::{
    crdt_state_dir, crdt_state_path, edit_timing_enabled, load_app_settings, load_crdt_state,
    load_daily_queue_scheme, load_daily_queue_schemes_for_calendar_range, load_local_sync_state,
    load_workspace_with_options, save_app_settings, save_crdt_state, save_crdt_state_incremental,
    save_local_sync_state, save_workspace, save_workspace_incremental, WorkspaceLoadOptions,
};
#[cfg(test)]
use knotq_sync::batch_pull_and_apply;
use knotq_sync::{
    batch_pull_and_apply_with_integrity_check, batch_pull_and_apply_with_integrity_documents,
    batch_pull_and_apply_with_persisted_integrity_vectors, batch_push_pending,
    compact_pending_documents, queue_account_switch_reseed, queue_workspace_bootstrap_updates,
    DevicePlatform, NotificationPermissionState, PendingCrdtEdit, PullOutcome, PushChannel,
    PushEnvironment, RegisterDeviceRequest, WorkspaceCrdtChangeSet, WorkspaceCrdtDocuments,
    MAX_PENDING_PER_DOCUMENT,
};
mod google_calendar;
use google_calendar::{GoogleCalendarImportResult, GoogleOAuthConfig};

mod parsing;
use parsing::*;

mod crdt_changes;
use crdt_changes::{
    mobile_command_may_change_notification_schedule, mobile_command_requires_background_refresh,
    mobile_crdt_change_set_for_command,
};

// Sync internals stay compiled in every configuration; when `accounts` is off
// they are unreferenced (the UDL sync fns stub out), so silence dead-code here.
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
mod media_sync;
use media_sync::{
    mobile_download_missing_media_assets, mobile_media_to_item_media,
    mobile_notification_schedule_snapshot, mobile_upload_local_media_assets_for_documents,
    normalize_sync_api_base, MobileSyncHttpClient,
};

mod conversions;
use conversions::{
    archived_scheme_node, as_u16, as_u8, format_daily_label,
    google_account_matches_calendar_source, mobile_inlines_to_inlines, mobile_notification_id,
    mobile_notification_lead_times, mobile_upcoming, next_color_index, non_empty, offset_to_i32,
    opt_position, position_from_i32, theme_mode_str, time_format_str,
};

mod mobile_core_api;
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
mod mobile_core_cold_start_sync;
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
mod mobile_core_inner_ops;
#[cfg(test)]
use mobile_core_inner_ops::SyncCycleOptions;
mod mobile_core_inner_views;
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
mod ws_sync;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_archive;
#[cfg(test)]
mod tests_calendar;
#[cfg(test)]
mod tests_daily;
#[cfg(test)]
mod tests_more;
#[cfg(test)]
mod tests_notifications;

const DAILY_QUEUE_MARKER_COLOR: u32 = 0x42a5f5;
const MOBILE_DAILY_DEFAULT_HISTORY_DAYS: i32 = 3;
const MOBILE_DAILY_MAX_HISTORY_DAYS: i32 = 3650;
const MOBILE_DAILY_LOOKAHEAD_DAYS: i64 = 10;
const MOBILE_UPCOMING_QUERY_LIMIT: usize = 512;
const MOBILE_UPCOMING_MIN_LOOKAHEAD_DAYS: i32 = 1;
const MOBILE_UPCOMING_MAX_LOOKAHEAD_DAYS: i32 = 365;
const MOBILE_UPCOMING_MIN_ITEMS: i32 = 1;
const MOBILE_UPCOMING_MAX_ITEMS: i32 = 100;
const NOTIFICATION_HORIZON_DAYS: i64 = 14;
const ACTION_SNOOZE_1_MINUTE: &str = "knotq.snooze.1m";
const ACTION_SNOOZE_5_MINUTES: &str = "knotq.snooze.5m";
const ACTION_SNOOZE_10_MINUTES: &str = "knotq.snooze.10m";
const ACTION_SNOOZE_15_MINUTES: &str = "knotq.snooze.15m";
const ACTION_SNOOZE_30_MINUTES: &str = "knotq.snooze.30m";
const ACTION_SNOOZE_1_HOUR: &str = "knotq.snooze.1h";
const ACTION_SNOOZE_2_HOURS: &str = "knotq.snooze.2h";
const ACTION_SNOOZE_6_HOURS: &str = "knotq.snooze.6h";
const ACTION_SNOOZE_1_DAY: &str = "knotq.snooze.1d";
const ACTION_SNOOZE_1_WEEK: &str = "knotq.snooze.1w";
const ACTION_SNOOZE_TOMORROW_MORNING: &str = "knotq.snooze.tomorrow_morning";
const ACTION_MARK_DONE: &str = "knotq.mark_done";
const NOTIFICATION_SNOOZE_ACTIONS: &[(&str, i64)] = &[
    (ACTION_SNOOZE_1_MINUTE, 60),
    (ACTION_SNOOZE_5_MINUTES, 5 * 60),
    (ACTION_SNOOZE_10_MINUTES, 10 * 60),
    (ACTION_SNOOZE_15_MINUTES, 15 * 60),
    (ACTION_SNOOZE_30_MINUTES, 30 * 60),
    (ACTION_SNOOZE_1_HOUR, 60 * 60),
    (ACTION_SNOOZE_2_HOURS, 2 * 60 * 60),
    (ACTION_SNOOZE_6_HOURS, 6 * 60 * 60),
    (ACTION_SNOOZE_1_DAY, 24 * 60 * 60),
    (ACTION_SNOOZE_1_WEEK, 7 * 24 * 60 * 60),
];
const EDITOR_IMAGE_FIXTURE_TEXT: &str = "Image layout test";
const MAX_STDERR_CAPTURE_BYTES: u64 = 8 * 1024 * 1024;

fn stderr_capture_would_exceed(current_len: u64, chunk_len: usize) -> bool {
    current_len.saturating_add(chunk_len as u64) > MAX_STDERR_CAPTURE_BYTES
}
const EDITOR_IMAGE_FIXTURE_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0,
    0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31, 0, 3, 3, 2, 0,
    239, 191, 167, 219, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[derive(Debug, Clone, thiserror::Error)]
pub enum MobileError {
    #[error("{reason}")]
    Core { reason: String },
}

impl From<anyhow::Error> for MobileError {
    fn from(error: anyhow::Error) -> Self {
        Self::Core {
            reason: error.to_string(),
        }
    }
}

#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
pub struct MobileCore {
    inner: Mutex<MobileCoreInner>,
    // Shared handle to inner.ws_changed, read lock-free by `ws_pending_changed` so
    // the shell's nudge poll is never blocked by an in-flight `sync_once` that
    // holds the core mutex across its network round trip.
    ws_changed: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

/// Debug aid: tee the process's stderr (every `eprintln!` in the core and the
/// shared `knotq-sync` engine — including the `knotq sync:` trace lines) into
/// `<app_dir>/knotq-sync-debug.log`, while still forwarding it to the real
/// stderr (Xcode console on iOS, dropped on Android). Android has no other way
/// to see the native lib's stderr, and a sync wedge leaves nothing in logcat.
/// Idempotent; failures are swallowed — this must never affect startup.
fn install_stderr_capture(app_dir: &Path) {
    use std::os::unix::io::FromRawFd;
    static ONCE: std::sync::Once = std::sync::Once::new();
    let log_path = app_dir.join("knotq-sync-debug.log");
    ONCE.call_once(move || {
        // Cap the file so a spinning loop cannot fill the disk.
        if let Ok(meta) = std::fs::metadata(&log_path) {
            if meta.len() > MAX_STDERR_CAPTURE_BYTES {
                let _ = std::fs::remove_file(&log_path);
            }
        }
        unsafe {
            let mut fds = [0i32; 2];
            if libc::pipe(fds.as_mut_ptr()) != 0 {
                return;
            }
            let (read_fd, write_fd) = (fds[0], fds[1]);
            let real_stderr = libc::dup(2);
            if libc::dup2(write_fd, 2) < 0 {
                libc::close(read_fd);
                libc::close(write_fd);
                return;
            }
            libc::close(write_fd);
            let _ = std::thread::Builder::new()
                .name("knotq-stderr-tee".into())
                .spawn(move || {
                    use std::io::{Read, Write};
                    let mut reader = std::fs::File::from_raw_fd(read_fd);
                    let mut file = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&log_path)
                        .ok();
                    let mut buf = [0u8; 8192];
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if real_stderr >= 0 {
                                    libc::write(
                                        real_stderr,
                                        buf.as_ptr() as *const libc::c_void,
                                        n,
                                    );
                                }
                                if let Some(f) = file.as_mut() {
                                    // Keep the diagnostic breadcrumb bounded even
                                    // while the process remains alive. A tight
                                    // retry loop must not turn logging into a
                                    // disk-exhaustion failure mode.
                                    let would_exceed = f
                                        .metadata()
                                        .map(|meta| stderr_capture_would_exceed(meta.len(), n))
                                        .unwrap_or(false);
                                    if would_exceed {
                                        let _ = f.set_len(0);
                                    }
                                    let _ = f.write_all(&buf[..n]);
                                    let _ = f.flush();
                                }
                            }
                        }
                    }
                });
        }
    });
}

impl MobileCore {
    pub fn new(app_dir: String) -> Result<Self, MobileError> {
        install_stderr_capture(Path::new(&app_dir));
        let inner = MobileCoreInner::open(Path::new(&app_dir).to_path_buf())?;
        let ws_changed = std::sync::Arc::clone(&inner.ws_changed);
        Ok(Self {
            inner: Mutex::new(inner),
            ws_changed,
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, MobileCoreInner>, MobileError> {
        // A panic while the lock is held poisons the mutex. Without recovery,
        // every later call — and every resync — would fail forever with "lock
        // was poisoned" until the app is killed, which is exactly the wedge users
        // hit. The workspace state is still readable, and any partial mutation is
        // reconciled from disk/CRDT on the next save or sync, so recover the guard
        // and carry on rather than stay stuck.
        Ok(self.inner.lock().unwrap_or_else(|poisoned| {
            eprintln!("knotq: recovered mobile core lock after a poisoning panic");
            poisoned.into_inner()
        }))
    }
}

#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
struct MobileCoreInner {
    workspace_path: PathBuf,
    settings_path: PathBuf,
    image_assets_dir: PathBuf,
    workspace: Workspace,
    /// Reused across consecutive read-only snapshot/month/search requests.
    /// Every workspace write and lazy daily-queue hydration invalidates it, so
    /// it can never outlive the materialized workspace it indexes.
    indexed_workspace: Option<IndexedWorkspace>,
    settings: AppSettings,
    crdt: WorkspaceCrdtDocuments,
    next_sequence: u64,
    /// The last `sync-state.json` this core wrote, kept so an edit does not have
    /// to re-parse it. It is only ever populated by the edit path and taken (not
    /// borrowed) on use, so any other writer — or a failure part-way — simply
    /// leaves it empty and the next edit reloads from disk.
    sync_state_cache: Option<knotq_sync::LocalSyncState>,
    /// Schemes edited since the last successful save. A full save rewrites every
    /// scheme file — 170 of them on a real workspace, ~55 ms — on every
    /// keystroke pause; an edit touches one. Empty means "save everything",
    /// which is what the paths that can change any scheme (a sync pull, a
    /// migration) want.
    dirty_schemes: std::collections::HashSet<knotq_model::SchemeId>,
    /// Scheme CRDT documents changed by ordinary item edits. Structure changes
    /// leave this empty and take the full, pruning CRDT save path.
    dirty_crdt_schemes: std::collections::HashSet<knotq_model::SchemeId>,
    crdt_state_requires_full_save: bool,
    /// A lazy daily failed to parse and was hydrated from durable CRDT state;
    /// the next sync must persist the repaired materialization even when the
    /// server returns no changed documents.
    daily_recovery_pending: bool,
    /// Complete remote states retained for lazy off-window dailies. Their old
    /// plain files remain cheap to read, but the authoritative CRDT is hydrated
    /// when that daily enters a visible range.
    deferred_materialization_pending: std::collections::HashSet<knotq_model::DocumentId>,
    sync_notice: Option<String>,
    // Push registration handed in from the platform (e.g. an FCM token from
    // Firebase). Registered with the backend during sync_once; `registered_push_token`
    // dedupes so we only re-register when the token changes within a session.
    push_token: Option<String>,
    push_environment: Option<PushEnvironment>,
    registered_push_token: Option<String>,
    registered_push_environment: Option<PushEnvironment>,
    // Occurrences completed this session, kept on the upcoming panel (faded, in
    // place) until they're un-completed, their retention TTL elapses, or the app
    // reloads — mirroring desktop's retained-completed set.
    retained_completed: RetainedCompletedItems,
    // A completion can change Upcoming/widgets even when the notification hash
    // remains stable; carry that intent through the next sync push.
    background_refresh_required: bool,
    /// Cached notification schedule metadata for the current in-memory workspace.
    /// The push protocol needs only its hash/window/count, but deriving those
    /// values expands every scheduled item. Keep it across ordinary prose edits
    /// and invalidate it only when a schedule-affecting change lands.
    notification_schedule_cache: Option<knotq_sync::NotificationScheduleSnapshot>,
    // Monotonic time of the last remote sync that actually ran. Used to coalesce
    // wake-storms (silent-push/poll triggers that arrive in bursts) so a device
    // can't barrage the backend — see `sync_once`.
    last_remote_sync_at: Option<std::time::Instant>,
    /// Run the one-shot recovery integrity proof after an interrupted sync.
    /// Persisted state vectors keep cold/deferred documents out of the decode
    /// path; subsequent websocket wakes rely on per-document cursors, and a
    /// post-push proof is still requested for the documents just accepted.
    startup_integrity_check_pending: bool,
    // Persistent WebSocket sync client (online, poll-free). `None` until the shell
    // calls `start_ws_sync`. When connected, `sync_once` pull/push ride it.
    ws_client: Option<std::sync::Arc<knotq_sync::ws::WsClient>>,
    // Latest bearer token for the ws client's reconnect handshakes (re-read on
    // every reconnect, so token refreshes apply).
    ws_token: std::sync::Arc<std::sync::Mutex<String>>,
    // Set by the ws `changed` callback; forces the next `sync_once` to run (not
    // coalesce) and signals the shell (via `ws_pending_changed`) to sync promptly.
    ws_changed: std::sync::Arc<std::sync::atomic::AtomicBool>,
    // The api_base the current ws client was built for, so an account switch
    // rebuilds it.
    ws_api_base: Option<String>,
    // The account-status endpoint is needed to discover the canonical workspace
    // id, but it is not needed before every ordinary edit/pull. Cache it only
    // in memory, keyed by the exact bearer token, so a token/account change
    // cannot reuse another session's identity.
    account_workspace_cache: Option<CachedAccountWorkspace>,
    /// Shared HTTP connection pool for mobile sync and auxiliary calls.
    http_agent: ureq::Agent,
}

struct CachedAccountWorkspace {
    api_base: String,
    bearer_token: String,
    workspace_id: knotq_model::WorkspaceId,
    fetched_at: std::time::Instant,
}

impl CachedAccountWorkspace {
    fn new(api_base: String, bearer_token: String, workspace_id: knotq_model::WorkspaceId) -> Self {
        Self {
            api_base,
            bearer_token,
            workspace_id,
            fetched_at: std::time::Instant::now(),
        }
    }
}

/// Minimum spacing between remote syncs that have nothing local to push. Silent
/// pushes wake every device on each push, so two devices that each re-push on every
/// sync (e.g. a stale build whose normalization keeps re-canonicalizing the other's
/// workspace) form a feedback loop that hammers the backend. Coalescing
/// nothing-to-push syncs to this interval breaks that loop. Kept well under the
/// shells' poll interval (~30s) so the periodic pull is unaffected, and bypassed
/// whenever there are local edits queued so user changes never wait on it.
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
const MIN_REMOTE_SYNC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

/// Refreshing the canonical workspace id more often than this adds a network
/// round trip to every keystroke without improving normal sync correctness. The
/// pull/push endpoints still authorize every request, and a new bearer token or
/// API base invalidates this cache immediately.
#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
const ACCOUNT_WORKSPACE_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(30);

#[cfg_attr(not(feature = "accounts"), allow(dead_code))]
const MEDIA_RECONCILIATION_INTERVAL: std::time::Duration = std::time::Duration::from_secs(30);

struct GoogleCalendarApplyResult {
    content_changed: bool,
    created_count: i32,
    changes: WorkspaceCrdtChangeSet,
}

#[derive(Clone, Debug)]
pub struct MobileSnapshot {
    pub root: MobileNode,
    pub schemes: Vec<MobileScheme>,
    pub archived_schemes: Vec<MobileScheme>,
    pub archived_nodes: Vec<MobileNode>,
    pub daily: Vec<MobileDailyEntry>,
    pub calendar: MobileCalendar,
    pub settings: MobileSettings,
    pub workspace_path: String,
}

#[derive(Clone, Debug)]
pub struct MobileNode {
    pub kind: String,
    pub id: String,
    pub name: String,
    pub color_index: Option<i32>,
    pub is_daily_queue: bool,
    pub is_read_only: bool,
    pub children: Vec<MobileNode>,
}

#[derive(Clone, Debug)]
pub struct MobileScheme {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub color_index: i32,
    pub is_daily_queue: bool,
    pub is_read_only: bool,
    pub date: Option<String>,
    pub items: Vec<MobileItem>,
}

#[derive(Clone, Debug)]
pub struct MobileItem {
    pub id: String,
    pub text: String,
    pub marker: String,
    pub indent: i32,
    pub kind: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub notification_offset_secs: Option<i32>,
    pub repeat_rule: Option<String>,
    pub media: Vec<MobileItemMedia>,
    pub tables: Vec<MobileTable>,
    pub content: Vec<MobileInline>,
}

/// One piece of a line's content, in document order. Mirrors `knotq_model::Inline`.
#[derive(Clone, Debug)]
pub enum MobileInline {
    Text { text: String },
    Image { media: MobileItemMedia },
    Table { table: MobileTable },
}

#[derive(Clone, Debug)]
pub struct MobileItemMedia {
    pub kind: String,
    pub path: Option<String>,
    pub format: String,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct MobileTable {
    pub columns: Vec<MobileTableColumn>,
    pub rows: Vec<MobileTableRow>,
}

#[derive(Clone, Debug)]
pub struct MobileTableColumn {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct MobileTableRow {
    pub id: String,
    pub cells: Vec<MobileTableCell>,
}

#[derive(Clone, Debug)]
pub struct MobileTableCell {
    pub text: String,
    pub lines: Vec<MobileCellLine>,
}

/// A single line within a table cell. Flat / non-recursive: it does not embed
/// `MobileItem`/`MobileInline` (those would make UniFFI records recursive).
#[derive(Clone, Debug)]
pub struct MobileCellLine {
    pub id: String,
    pub text: String,
    pub marker: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub media: Vec<MobileItemMedia>,
}

#[derive(Clone, Debug)]
pub struct MobileItemEdit {
    pub id: Option<String>,
    pub text: String,
    pub marker: String,
    pub indent: i32,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub notification_offset_secs: Option<i32>,
    pub repeat_rule: Option<String>,
    pub media: Vec<MobileItemMedia>,
    pub content: Vec<MobileInline>,
}

#[derive(Clone, Debug)]
pub struct MobileDailyEntry {
    pub date: String,
    pub scheme: MobileScheme,
}

#[derive(Clone, Debug)]
pub struct MobileCalendar {
    pub start_date: String,
    pub end_date: String,
    pub days: Vec<MobileCalendarDay>,
    pub upcoming: Vec<MobileOccurrence>,
    pub overdue: Vec<MobileOccurrence>,
}

#[derive(Clone, Debug)]
pub struct MobileCalendarDay {
    pub date: String,
    pub occurrences: Vec<MobileOccurrence>,
}

#[derive(Clone, Debug)]
pub struct MobileOccurrence {
    pub scheme_id: String,
    pub item_id: String,
    pub occurrence_json: String,
    pub occurrence_index: i32,
    pub is_recurring: bool,
    pub can_delete_future: bool,
    pub scheme_name: String,
    pub color_index: i32,
    pub is_read_only: bool,
    pub title: String,
    pub kind: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub notification_offset_secs: Option<i32>,
    pub local_date: Option<String>,
    pub repeat_rule: Option<String>,
}

#[derive(Clone, Debug)]
pub struct MobileSettings {
    pub theme_mode: String,
    pub time_format: String,
    pub event_notification_offset_secs: i32,
    pub assignment_notification_offset_secs: i32,
    pub event_lookahead_days: i32,
    pub reminder_lookahead_days: i32,
    pub assignment_lookahead_days: i32,
    pub maximum_upcoming_items: i32,
    pub show_overdue: bool,
    pub show_completed: bool,
    pub google_account_count: i32,
    pub google_accounts: Vec<MobileGoogleAccount>,
}

#[derive(Clone, Debug)]
pub struct MobileGoogleAccount {
    pub id: String,
    pub title: String,
    pub detail: String,
    /// Address the shell needs to re-request authorization for this specific
    /// account (Android pins `AuthorizationRequest` to it). Empty when the
    /// account was linked before an email was recorded.
    pub email: String,
    /// The stored authorization no longer works and the user has to grant it
    /// again; the shell should surface a reconnect affordance.
    pub needs_reauth: bool,
}

/// An access token minted by a platform identity service (Android's Google
/// Identity `AuthorizationClient`) rather than by the core's own OAuth
/// exchange.
///
/// Google blocks the loopback OAuth flow on Android, and the supported
/// replacement never yields a refresh token — the shell must obtain a fresh
/// access token before each sync and hand it over through this record. `email`
/// is a hint only; the authoritative identity is resolved from the token.
#[derive(Clone, Debug)]
pub struct MobileGoogleIdentityAccount {
    /// The stored account this token belongs to. `None` when linking a new
    /// account, where the identity is not known until the token is resolved.
    pub account_id: Option<String>,
    pub client_id: String,
    pub access_token: String,
    pub email: Option<String>,
    pub scope: Option<String>,
    pub expires_in_secs: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct MobileGoogleAuthRequest {
    pub auth_url: String,
    pub state: String,
    pub code_verifier: String,
    pub redirect_uri: String,
    pub scope: String,
    pub client_id: String,
}

#[derive(Clone, Debug)]
pub struct MobileGoogleSyncResult {
    pub imported_count: i32,
    pub synced_count: i32,
    pub failure_count: i32,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct MobileNotificationRequest {
    pub id: String,
    pub notification_key: String,
    pub fire_at: String,
    pub expires_at: Option<String>,
    pub end_at: Option<String>,
    pub title: String,
    pub body: String,
    pub kind: String,
    pub scheme_id: String,
    pub item_id: String,
    pub occurrence_json: String,
    pub trigger_at: String,
}

#[derive(Clone, Debug)]
pub struct MobileSearchHit {
    pub target_kind: String,
    pub scheme_id: Option<String>,
    pub item_id: Option<String>,
    pub scheme_name: String,
    pub color_index: Option<i32>,
    pub title: String,
    pub detail: String,
    pub status: String,
}

/// Applies the shell's UI locale to core-produced strings (sync status
/// messages, daily labels). Unknown tags fall back to English.
pub fn set_locale(tag: String) {
    knotq_l10n::set_locale(&tag);
}

uniffi::include_scaffolding!("knotq_mobile_core");
