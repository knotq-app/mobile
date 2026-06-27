use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, NaiveDate, Utc};
use knotq_commands::{
    event_popup_commit_commands, event_popup_delete_command, Command, DateEditScope,
    EventDeleteScope, EventPopupDraft, WorkspaceCommandExt,
};
use knotq_date_util::UPCOMING_LIMIT;
use knotq_index::query::{SearchHitStatus, SearchOptions, SearchTarget};
use knotq_index::IndexedWorkspace;
use knotq_model::{
    daily_queue_scheme_id, daily_queue_sync_metadata, AppSettings, CalendarProvider, FolderId,
    GoogleOAuthAccount, ImageAssetFormat, ImageInline, Inline, Item, ItemContent, ItemId,
    ItemMarker, NodeRef, NotificationDefaults, OccurrenceId, OperationId, Recurrence, Scheme,
    SchemeId, SchemeSource, Table, Workspace, DAILY_QUEUE_COLOR_INDEX,
};
use knotq_notifications::{
    compute_due_notifications_with_lead_times, DEFAULT_DURABLE_NOTIFICATION_LIMIT,
};
use knotq_state::{
    daily_queue_initial_start, daily_queue_scheme_name, make_default_workspace,
    mark_past_event_completion_keys_done, past_event_completion_keys, CalendarOccurrenceKey,
    RetainedCompletedItems,
};
use knotq_storage_json::{
    load_app_settings, load_crdt_state, load_daily_queue_scheme,
    load_daily_queue_schemes_for_calendar_range, load_local_sync_state,
    load_workspace_with_options, save_app_settings, save_crdt_state, save_local_sync_state,
    save_workspace, WorkspaceLoadOptions,
};
use knotq_sync::{
    batch_pull_and_apply, batch_push_pending, queue_account_switch_reseed,
    queue_workspace_bootstrap_updates, DevicePlatform, NotificationPermissionState, PendingCrdtEdit,
    PushChannel, PushEnvironment, RegisterDeviceRequest, WorkspaceCrdtChangeSet,
    WorkspaceCrdtDocuments,
};
mod google_calendar;
use google_calendar::{GoogleCalendarImportResult, GoogleOAuthConfig};

mod parsing;
use parsing::*;

mod crdt_changes;
use crdt_changes::mobile_crdt_change_set_for_command;

mod media_sync;
use media_sync::{
    mobile_download_missing_media_assets, mobile_media_to_item_media,
    mobile_notification_schedule_snapshot, mobile_upload_local_media_assets, normalize_sync_api_base,
    MobileSyncHttpClient,
};

mod conversions;
use conversions::{
    archived_scheme_node, as_u8, format_daily_label, google_account_matches_calendar_source,
    mobile_inlines_to_inlines, mobile_notification_lead_times, mobile_upcoming, next_color_index,
    non_empty, offset_to_i32, opt_position, position_from_i32, theme_mode_str, time_format_str,
};

mod mobile_core_api;
mod mobile_core_inner_ops;
mod mobile_core_inner_views;
mod ws_sync;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_more;

const DAILY_QUEUE_MARKER_COLOR: u32 = 0x42a5f5;
const MOBILE_DAILY_DEFAULT_HISTORY_DAYS: i32 = 3;
const MOBILE_DAILY_MAX_HISTORY_DAYS: i32 = 3650;
const MOBILE_DAILY_LOOKAHEAD_DAYS: i64 = 10;
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

pub struct MobileCore {
    inner: Mutex<MobileCoreInner>,
}

impl MobileCore {
    pub fn new(app_dir: String) -> Result<Self, MobileError> {
        Ok(Self {
            inner: Mutex::new(MobileCoreInner::open(Path::new(&app_dir).to_path_buf())?),
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

struct MobileCoreInner {
    workspace_path: PathBuf,
    settings_path: PathBuf,
    image_assets_dir: PathBuf,
    workspace: Workspace,
    settings: AppSettings,
    crdt: WorkspaceCrdtDocuments,
    next_sequence: u64,
    sync_notice: Option<String>,
    // Push registration handed in from the platform (e.g. an FCM token from
    // Firebase). Registered with the backend during sync_once; `registered_push_token`
    // dedupes so we only re-register when the token changes within a session.
    push_token: Option<String>,
    push_environment: Option<PushEnvironment>,
    registered_push_token: Option<String>,
    // Occurrences completed this session, kept on the upcoming panel (faded, in
    // place) until they're un-completed or the app reloads — mirroring desktop's
    // `retained_completed_calendar_items`.
    retained_completed: RetainedCompletedItems,
    // Monotonic time of the last remote sync that actually ran. Used to coalesce
    // wake-storms (silent-push/poll triggers that arrive in bursts) so a device
    // can't barrage the backend — see `sync_once`.
    last_remote_sync_at: Option<std::time::Instant>,
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
}

/// Minimum spacing between remote syncs that have nothing local to push. Silent
/// pushes wake every device on each push, so two devices that each re-push on every
/// sync (e.g. a stale build whose normalization keeps re-canonicalizing the other's
/// workspace) form a feedback loop that hammers the backend. Coalescing
/// nothing-to-push syncs to this interval breaks that loop. Kept well under the
/// shells' poll interval (~30s) so the periodic pull is unaffected, and bypassed
/// whenever there are local edits queued so user changes never wait on it.
const MIN_REMOTE_SYNC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);


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
    pub google_account_count: i32,
    pub google_accounts: Vec<MobileGoogleAccount>,
}

#[derive(Clone, Debug)]
pub struct MobileGoogleAccount {
    pub id: String,
    pub title: String,
    pub detail: String,
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

uniffi::include_scaffolding!("knotq_mobile_core");

