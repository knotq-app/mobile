use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Mutex, MutexGuard};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use knotq_commands::{Command, DateKind, WorkspaceCommandExt};
use knotq_index::query::{SearchHitStatus, SearchOptions, SearchTarget};
use knotq_index::IndexedWorkspace;
use knotq_model::{
    AppSettings, DocumentId, FolderId, ImageAssetFormat, Item, ItemId, ItemKind, ItemMarker,
    ItemMedia, NodeRef, NotificationDefaults, OccurrenceId, OperationId, Recurrence, ReplicaId,
    Scheme, SchemeId, SyncDocumentKind, ThemeMode, TimeFormat, Workspace, WorkspaceId,
    DAILY_QUEUE_COLOR_INDEX,
};
use knotq_notifications::{
    compute_due_notifications_with_lead_times, NotificationLeadTimes, ScheduledNotification,
    DEFAULT_DURABLE_NOTIFICATION_LIMIT,
};
use knotq_state::{daily_queue_scheme_name, make_default_workspace};
use knotq_storage_json::{
    load_app_settings, load_local_sync_state, load_workspace, save_app_settings,
    save_local_sync_state, save_workspace,
};
use knotq_sync::{
    LocalSyncState, PendingCrdtEdit, PullUpdatesResponse, PushUpdatesRequest, PushUpdatesResponse,
    StoredCrdtSnapshot, StoredCrdtUpdate, UpsertDocumentRequest, WorkspaceCrdtChangeSet,
    WorkspaceCrdtDocuments,
};
use sha2::{Digest, Sha256};

const DAILY_QUEUE_MARKER_COLOR: u32 = 0x42a5f5;
const SYNC_BATCH_LIMIT: usize = 50;
const NOTIFICATION_HORIZON_DAYS: i64 = 14;
const ACTION_SNOOZE_10_MINUTES: &str = "knotq.snooze.10m";
const ACTION_SNOOZE_1_HOUR: &str = "knotq.snooze.1h";
const ACTION_MARK_DONE: &str = "knotq.mark_done";
const SYNC_COMPACTED_SNAPSHOT_NOTICE: &str = "This device was far enough behind that the sync server had already compacted older CRDT changes. KnotQ applied the latest compacted snapshot and then continued syncing from there.";
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

    pub fn snapshot(
        &self,
        today: Option<String>,
        week_offset: i32,
    ) -> Result<MobileSnapshot, MobileError> {
        let today = parse_date_or_today(today.as_deref())?;
        self.lock()?
            .snapshot(today, week_offset)
            .map_err(Into::into)
    }

    pub fn search(&self, query: String) -> Result<Vec<MobileSearchHit>, MobileError> {
        self.lock()?.search(&query).map_err(Into::into)
    }

    pub fn create_folder(
        &self,
        parent_id: Option<String>,
        name: String,
        position: Option<i32>,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let parent = parent_id
            .as_deref()
            .map(parse_id)
            .transpose()?
            .unwrap_or(inner.workspace.root);
        inner
            .apply(Command::CreateFolder {
                parent,
                name,
                position: opt_position(position)?,
            })
            .map_err(Into::into)
    }

    pub fn rename_folder(&self, folder_id: String, name: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::RenameFolder {
                id: parse_id(&folder_id)?,
                name,
            })
            .map_err(Into::into)
    }

    pub fn delete_folder(&self, folder_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteFolder {
                id: parse_id(&folder_id)?,
            })
            .map_err(Into::into)
    }

    pub fn create_scheme(
        &self,
        folder_id: Option<String>,
        name: String,
        color_index: Option<i32>,
        position: Option<i32>,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let folder = folder_id
            .as_deref()
            .map(parse_id)
            .transpose()?
            .unwrap_or(inner.workspace.root);
        let color_index = match color_index {
            Some(index) => as_u8(index, "color index")?,
            None => next_color_index(&inner.workspace),
        };
        inner
            .apply(Command::CreateScheme {
                folder,
                name,
                color_index,
                position: opt_position(position)?,
            })
            .map_err(Into::into)
    }

    pub fn rename_scheme(&self, scheme_id: String, name: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::RenameScheme {
                id: parse_id(&scheme_id)?,
                name,
            })
            .map_err(Into::into)
    }

    pub fn set_scheme_color(&self, scheme_id: String, color_index: i32) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetSchemeColor {
                id: parse_id(&scheme_id)?,
                color_index: as_u8(color_index, "color index")?,
            })
            .map_err(Into::into)
    }

    pub fn delete_scheme(&self, scheme_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteScheme {
                id: parse_id(&scheme_id)?,
            })
            .map_err(Into::into)
    }

    pub fn restore_scheme(&self, scheme_id: String) -> Result<(), MobileError> {
        self.lock()?
            .restore_deleted_scheme(parse_id(&scheme_id)?)
            .map_err(Into::into)
    }

    pub fn permanently_delete_scheme(&self, scheme_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::PermanentlyDeleteScheme {
                id: parse_id(&scheme_id)?,
            })
            .map_err(Into::into)
    }

    pub fn empty_archive(&self) -> Result<(), MobileError> {
        self.lock()?.empty_archive().map_err(Into::into)
    }

    pub fn move_node(
        &self,
        kind: String,
        id: String,
        folder_id: String,
        position: i32,
    ) -> Result<(), MobileError> {
        let node = match kind.as_str() {
            "folder" => NodeRef::Folder(parse_id(&id)?),
            "scheme" => NodeRef::Scheme(parse_id(&id)?),
            other => return Err(anyhow!("unknown node kind {other}").into()),
        };
        self.lock()?
            .apply(Command::MoveNode {
                node,
                new_parent: parse_id(&folder_id)?,
                position: position_from_i32(position)?,
            })
            .map_err(Into::into)
    }

    pub fn ensure_daily_queue(&self, date: Option<String>) -> Result<(), MobileError> {
        let date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        inner.ensure_daily_queue(date)?;
        inner.save_workspace().map_err(Into::into)
    }

    pub fn add_item(
        &self,
        scheme_id: String,
        text: String,
        marker: Option<String>,
        position: Option<i32>,
        indent: Option<i32>,
    ) -> Result<(), MobileError> {
        let scheme_id = parse_id(&scheme_id)?;
        let mut inner = self.lock()?;
        let mut item = Item::new(text);
        item.marker = parse_marker(marker.as_deref())?;
        item.indent = as_u8(indent.unwrap_or(0), "indent")?;
        let position = match position {
            Some(position) => position_from_i32(position)?,
            None => inner
                .workspace
                .scheme(scheme_id)
                .map(|scheme| scheme.items.len())
                .unwrap_or(0),
        };
        inner
            .apply(Command::InsertItem {
                scheme: scheme_id,
                position,
                item,
            })
            .map_err(Into::into)
    }

    pub fn add_calendar_item(
        &self,
        scheme_id: Option<String>,
        date: Option<String>,
        text: String,
        kind: String,
        start: Option<String>,
        end: Option<String>,
    ) -> Result<(), MobileError> {
        let date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        let scheme_id = match scheme_id {
            Some(id) => parse_id(&id)?,
            None => inner.ensure_daily_queue(date)?,
        };
        let mut item = Item::new(text);
        item.marker = ItemMarker::Checkbox;
        let start = parse_datetime_opt(start.as_deref())?;
        let end = parse_datetime_opt(end.as_deref())?;
        match kind.as_str() {
            "event" => {
                item.start = start;
                item.end = end;
            }
            "reminder" => item.start = start,
            "assignment" => item.end = end,
            "task" | "procedure" => {}
            other => return Err(anyhow!("unknown calendar item kind {other}").into()),
        }
        let position = inner
            .workspace
            .scheme(scheme_id)
            .map(|scheme| scheme.items.len())
            .unwrap_or(0);
        inner
            .apply(Command::InsertItem {
                scheme: scheme_id,
                position,
                item,
            })
            .map_err(Into::into)
    }

    pub fn update_item_text(
        &self,
        scheme_id: String,
        item_id: String,
        text: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::UpdateItemText {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                text,
            })
            .map_err(Into::into)
    }

    pub fn set_item_marker(
        &self,
        scheme_id: String,
        item_id: String,
        marker: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemMarker {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                marker: parse_marker(Some(&marker))?,
            })
            .map_err(Into::into)
    }

    pub fn set_item_indent(
        &self,
        scheme_id: String,
        item_id: String,
        indent: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemIndent {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                indent: as_u8(indent, "indent")?,
            })
            .map_err(Into::into)
    }

    pub fn set_item_date(
        &self,
        scheme_id: String,
        item_id: String,
        kind: String,
        date: Option<String>,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemDate {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                kind: parse_date_kind(&kind)?,
                date: parse_datetime_opt(date.as_deref())?,
            })
            .map_err(Into::into)
    }

    /// Sets (or clears, when `rrule` is `None`/empty) the item's recurrence.
    /// `rrule` is a bare RRULE body, e.g. `FREQ=WEEKLY;INTERVAL=1` — matching
    /// the format stored in `CalendarRecurrence::rrules` elsewhere.
    pub fn set_item_recurrence(
        &self,
        scheme_id: String,
        item_id: String,
        rrule: Option<String>,
    ) -> Result<(), MobileError> {
        let repeats = match rrule {
            Some(rule) if !rule.trim().is_empty() => Some(Recurrence {
                rrules: vec![rule.trim().to_string()],
                ..Recurrence::default()
            }),
            _ => None,
        };
        self.lock()?
            .apply(Command::SetItemRecurrence {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                repeats,
            })
            .map_err(Into::into)
    }

    pub fn toggle_item(&self, scheme_id: String, item_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::ToggleOccurrence {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                occurrence: OccurrenceId::Single,
            })
            .map_err(Into::into)
    }

    pub fn toggle_occurrence(
        &self,
        scheme_id: String,
        item_id: String,
        occurrence_json: String,
    ) -> Result<(), MobileError> {
        let occurrence = serde_json::from_str(&occurrence_json)
            .with_context(|| "parse occurrence")?;
        self.lock()?
            .apply(Command::ToggleOccurrence {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                occurrence,
            })
            .map_err(Into::into)
    }

    pub fn delete_item(&self, scheme_id: String, item_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteItem {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
            })
            .map_err(Into::into)
    }

    pub fn reorder_item(&self, scheme_id: String, from: i32, to: i32) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::ReorderItem {
                scheme: parse_id(&scheme_id)?,
                from: position_from_i32(from)?,
                to: position_from_i32(to)?,
            })
            .map_err(Into::into)
    }

    pub fn replace_scheme_items(
        &self,
        scheme_id: String,
        items: Vec<MobileItemEdit>,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner
            .replace_scheme_items(parse_id(&scheme_id)?, items)
            .map_err(Into::into)
    }

    pub fn set_theme_mode(&self, theme_mode: String) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.settings.theme_mode = parse_theme_mode(&theme_mode)?;
        inner.save_settings().map_err(Into::into)
    }

    pub fn set_time_format(&self, time_format: String) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.settings.time_format = parse_time_format(&time_format)?;
        inner.save_settings().map_err(Into::into)
    }

    pub fn reset_workspace(&self) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.workspace = make_default_workspace();
        inner.crdt = WorkspaceCrdtDocuments::empty(&inner.workspace);
        let mut changes = WorkspaceCrdtChangeSet::default().workspace();
        for id in inner.workspace.schemes.keys().copied().collect::<Vec<_>>() {
            changes = changes.touch_scheme(id);
        }
        inner.record_crdt_changes(changes)?;
        inner.save_workspace().map_err(Into::into)
    }

    pub fn pending_notifications(
        &self,
        now: Option<String>,
        horizon_days: i32,
    ) -> Result<Vec<MobileNotificationRequest>, MobileError> {
        let now = parse_datetime_opt(now.as_deref())?.unwrap_or_else(Utc::now);
        let horizon_days = if horizon_days <= 0 {
            NOTIFICATION_HORIZON_DAYS
        } else {
            i64::from(horizon_days)
        };
        self.lock()?
            .pending_notifications(now, horizon_days)
            .map_err(Into::into)
    }

    pub fn apply_notification_action(
        &self,
        action_id: String,
        scheme_id: String,
        item_id: String,
        occurrence_json: String,
        trigger_at: String,
    ) -> Result<bool, MobileError> {
        self.lock()?
            .apply_notification_action(
                &action_id,
                parse_id(&scheme_id)?,
                parse_id(&item_id)?,
                serde_json::from_str(&occurrence_json)
                    .with_context(|| "parse notification occurrence")?,
                parse_datetime(&trigger_at)?,
            )
            .map_err(Into::into)
    }

    pub fn sync_once(&self, api_base: String, bearer_token: String) -> Result<bool, MobileError> {
        self.lock()?
            .sync_once(&api_base, &bearer_token)
            .map_err(Into::into)
    }

    pub fn take_sync_notice(&self) -> Result<Option<String>, MobileError> {
        Ok(self.lock()?.sync_notice.take())
    }

    pub fn seed_editor_image_fixture(&self) -> Result<(), MobileError> {
        self.lock()?.seed_editor_image_fixture().map_err(Into::into)
    }

    fn lock(&self) -> Result<MutexGuard<'_, MobileCoreInner>, MobileError> {
        self.inner.lock().map_err(|_| MobileError::Core {
            reason: "mobile core lock was poisoned".to_string(),
        })
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
}

impl MobileCoreInner {
    fn open(app_dir: PathBuf) -> Result<Self> {
        let workspace_dir = app_dir.join("workspace");
        let workspace_path = workspace_dir.join("workspace.json");
        let image_assets_dir = workspace_dir.join("assets/images");
        let settings_path = app_dir.join("settings.json");
        let mut should_reset_workspace_dir = false;
        let mut workspace = match load_workspace(&workspace_path) {
            Ok(Some(workspace)) => workspace,
            Ok(None) => make_default_workspace(),
            Err(_) => {
                should_reset_workspace_dir = true;
                make_default_workspace()
            }
        };
        workspace.normalize_one_level_folders();
        workspace.normalize_item_markers();
        let settings = load_app_settings(&settings_path).unwrap_or_default();
        if should_reset_workspace_dir && workspace_dir.exists() {
            fs::remove_dir_all(&workspace_dir)
                .with_context(|| format!("reset {}", workspace_dir.display()))?;
        }
        save_workspace(&workspace_path, &workspace)?;
        save_app_settings(&settings_path, &settings)?;
        let next_sequence = load_local_sync_state(&workspace_path)
            .unwrap_or_default()
            .pending
            .iter()
            .map(|edit| edit.local_sequence)
            .max()
            .unwrap_or(0)
            + 1;
        let crdt = WorkspaceCrdtDocuments::try_new(&workspace)?;
        Ok(Self {
            workspace_path,
            settings_path,
            image_assets_dir,
            workspace,
            settings,
            crdt,
            next_sequence,
            sync_notice: None,
        })
    }

    fn apply(&mut self, command: Command) -> Result<()> {
        let crdt_changes = mobile_crdt_change_set_for_command(&command);
        self.workspace.apply(command)?;
        self.workspace.normalize_one_level_folders();
        self.workspace.normalize_item_markers();
        self.record_crdt_changes(crdt_changes)?;
        self.save_workspace()
    }

    fn save_workspace(&self) -> Result<()> {
        save_workspace(&self.workspace_path, &self.workspace)
    }

    fn save_settings(&self) -> Result<()> {
        save_app_settings(&self.settings_path, &self.settings)
    }

    fn pending_notifications(
        &self,
        now: DateTime<Utc>,
        horizon_days: i64,
    ) -> Result<Vec<MobileNotificationRequest>> {
        let horizon_days = horizon_days.clamp(1, 60);
        Ok(compute_due_notifications_with_lead_times(
            &self.workspace,
            mobile_notification_lead_times(self.settings.notification_defaults),
            now,
            now + Duration::days(horizon_days),
        )
        .into_iter()
        .filter(|notification| notification.fire_at > now)
        .take(DEFAULT_DURABLE_NOTIFICATION_LIMIT)
        .map(MobileNotificationRequest::from_scheduled)
        .collect())
    }

    fn apply_notification_action(
        &mut self,
        action_id: &str,
        scheme_id: SchemeId,
        item_id: ItemId,
        occurrence: OccurrenceId,
        trigger_at: DateTime<Utc>,
    ) -> Result<bool> {
        let item_done = self
            .workspace
            .scheme(scheme_id)
            .and_then(|scheme| scheme.item(item_id))
            .map(|item| item.state_for_occurrence(&occurrence).is_done())
            .unwrap_or(true);
        if item_done {
            return Ok(false);
        }

        let command = match action_id {
            ACTION_MARK_DONE => Command::ToggleOccurrence {
                scheme: scheme_id,
                item: item_id,
                occurrence,
            },
            ACTION_SNOOZE_10_MINUTES => Command::SetOccurrenceNotificationOffset {
                scheme: scheme_id,
                item: item_id,
                occurrence,
                offset_secs: Some(
                    (trigger_at - (Utc::now() + Duration::minutes(10))).num_seconds(),
                ),
            },
            ACTION_SNOOZE_1_HOUR => Command::SetOccurrenceNotificationOffset {
                scheme: scheme_id,
                item: item_id,
                occurrence,
                offset_secs: Some((trigger_at - (Utc::now() + Duration::hours(1))).num_seconds()),
            },
            other => return Err(anyhow!("unknown notification action {other}")),
        };
        self.apply(command)?;
        Ok(true)
    }

    fn record_crdt_changes(&mut self, changeset: WorkspaceCrdtChangeSet) -> Result<()> {
        self.workspace.ensure_sync_metadata();
        let outcome = self.crdt.sync_changes(&self.workspace, &changeset);
        for error in &outcome.errors {
            eprintln!("mobile CRDT update failed: {error}");
        }
        if outcome.updates.is_empty() {
            return Ok(());
        }

        let mut sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
        sync_state.workspace_id = Some(self.workspace.id);
        sync_state.replica_id = Some(self.settings.replica_id);
        let operation_id = OperationId::new();
        let local_sequence = self.next_sequence;
        self.next_sequence += 1;
        for update in outcome.updates {
            sync_state.push_pending(PendingCrdtEdit {
                operation_id,
                workspace_id: self.workspace.id,
                replica_id: self.settings.replica_id,
                local_sequence,
                created_at: Utc::now(),
                document: update.document,
                kind: update.kind,
                update_v1: update.update_v1,
            });
        }
        save_local_sync_state(&self.workspace_path, &sync_state)
    }

    fn sync_once(&mut self, api_base: &str, bearer_token: &str) -> Result<bool> {
        let client = MobileSyncHttpClient {
            api_base: normalize_sync_api_base(api_base)?,
            bearer_token: bearer_token.to_string(),
        };
        self.workspace.ensure_sync_metadata();

        let mut sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
        sync_state.workspace_id = Some(self.workspace.id);
        sync_state.replica_id = Some(self.settings.replica_id);
        sync_state.server_url = Some(client.api_base.clone());
        sync_state.bearer_token = Some(client.bearer_token.clone());

        let mut remote_latest = HashMap::new();
        let mut remote_updates_applied = 0usize;
        let mut pushed_any = false;
        let mut forced_snapshot_applied = false;

        mobile_upsert_documents(
            &client,
            self.workspace.id,
            mobile_sync_documents(&self.workspace),
        )?;

        let workspace_doc = MobileSyncDocumentRef {
            document: self.workspace.sync.id,
            kind: SyncDocumentKind::PersonalWorkspace,
        };
        let workspace_pull = mobile_pull_document(
            &client,
            &sync_state,
            self.workspace.id,
            workspace_doc,
            self.settings.replica_id,
        )?;
        remote_latest.insert(workspace_doc.document, workspace_pull.latest_sequence);
        forced_snapshot_applied |= workspace_pull.forced_snapshot;
        let workspace_updates = workspace_pull.updates;
        if !workspace_updates.is_empty() {
            let outcome = self
                .crdt
                .apply_remote_updates(&self.workspace, &workspace_updates);
            if !outcome.is_ok() {
                return Err(anyhow!("workspace CRDT apply failed: {:?}", outcome.errors));
            }
            remote_updates_applied += outcome.applied;
            self.workspace = outcome.workspace;
        }
        sync_state.mark_pulled(
            workspace_doc.document,
            workspace_doc.kind,
            workspace_pull.latest_sequence,
        );

        mobile_upsert_documents(
            &client,
            self.workspace.id,
            mobile_sync_documents(&self.workspace),
        )?;

        let mut scheme_updates = Vec::new();
        for doc in mobile_scheme_documents(&self.workspace) {
            let pull = mobile_pull_document(
                &client,
                &sync_state,
                self.workspace.id,
                doc,
                self.settings.replica_id,
            )?;
            remote_latest.insert(doc.document, pull.latest_sequence);
            forced_snapshot_applied |= pull.forced_snapshot;
            if !pull.updates.is_empty() {
                scheme_updates.extend(pull.updates);
            }
            sync_state.mark_pulled(doc.document, doc.kind, pull.latest_sequence);
        }
        if !scheme_updates.is_empty() {
            let outcome = self
                .crdt
                .apply_remote_updates(&self.workspace, &scheme_updates);
            if !outcome.is_ok() {
                return Err(anyhow!("scheme CRDT apply failed: {:?}", outcome.errors));
            }
            remote_updates_applied += outcome.applied;
            self.workspace = outcome.workspace;
        }

        mobile_queue_bootstrap_updates(
            &mut sync_state,
            &self.workspace,
            self.settings.replica_id,
            &remote_latest,
        );
        pushed_any |= mobile_push_pending_documents(&client, &mut sync_state, self.workspace.id)?;

        save_local_sync_state(&self.workspace_path, &sync_state)?;
        if remote_updates_applied > 0 {
            self.workspace.normalize_one_level_folders();
            self.workspace.normalize_item_markers();
            self.crdt = WorkspaceCrdtDocuments::try_new(&self.workspace)?;
            self.save_workspace()?;
        }
        if forced_snapshot_applied {
            self.sync_notice = Some(SYNC_COMPACTED_SNAPSHOT_NOTICE.to_string());
        }

        Ok(remote_updates_applied > 0 || pushed_any || forced_snapshot_applied)
    }

    fn ensure_daily_queue(&mut self, date: NaiveDate) -> Result<SchemeId> {
        if let Some(id) = self.workspace.daily_queue_scheme_id(date) {
            if self.workspace.schemes.contains_key(&id) {
                return Ok(id);
            }
        }
        let mut scheme = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
        scheme.items = Vec::new();
        let id = scheme.id;
        self.workspace.daily_queue.insert(date, id);
        self.workspace.schemes.insert(id, scheme);
        self.record_crdt_changes(
            WorkspaceCrdtChangeSet::default()
                .workspace()
                .touch_scheme(id),
        )?;
        Ok(id)
    }

    fn snapshot(&mut self, today: NaiveDate, week_offset: i32) -> Result<MobileSnapshot> {
        self.ensure_daily_queue(today)?;
        let root = self.folder_node(self.workspace.root)?;
        let mut schemes: Vec<MobileScheme> = self
            .workspace
            .iter_schemes()
            .map(|scheme| self.mobile_scheme(scheme))
            .collect();
        schemes.sort_by(|a, b| {
            a.is_daily_queue
                .cmp(&b.is_daily_queue)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        let archived_schemes = self
            .workspace
            .iter_deleted_schemes()
            .map(|scheme| self.mobile_scheme(scheme))
            .collect::<Vec<_>>();

        let daily_start = today - Duration::days(3);
        let daily = (0..14)
            .filter_map(|offset| {
                let date = daily_start + Duration::days(offset);
                self.workspace
                    .daily_queue_scheme_id(date)
                    .and_then(|id| self.workspace.scheme(id))
                    .map(|scheme| MobileDailyEntry {
                        date: date.to_string(),
                        scheme: self.mobile_scheme(scheme),
                    })
            })
            .collect();

        let week_start = today + Duration::days((week_offset as i64) * 7);
        let week_end = week_start + Duration::days(7);
        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: midnight_utc(week_start)?,
            end: midnight_utc(week_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();
        let days = (0..7)
            .map(|offset| {
                let date = week_start + Duration::days(offset);
                let date_string = date.to_string();
                MobileCalendarDay {
                    date: date_string.clone(),
                    occurrences: occurrences
                        .iter()
                        .filter(|occurrence| occurrence.local_date.as_deref() == Some(&date_string))
                        .cloned()
                        .collect(),
                }
            })
            .collect();
        let upcoming = indexed
            .calendar_query()
            .upcoming(Utc::now(), 12)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        let overdue = indexed
            .calendar_query()
            .overdue(Utc::now())
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        Ok(MobileSnapshot {
            root,
            schemes,
            archived_schemes,
            daily,
            calendar: MobileCalendar {
                start_date: week_start.to_string(),
                end_date: (week_end - Duration::days(1)).to_string(),
                days,
                upcoming,
                overdue,
            },
            settings: MobileSettings {
                theme_mode: theme_mode_str(self.settings.theme_mode).to_string(),
                time_format: time_format_str(self.settings.time_format).to_string(),
            },
            workspace_path: self.workspace_path.display().to_string(),
        })
    }

    fn folder_node(&self, id: FolderId) -> Result<MobileNode> {
        let folder = self
            .workspace
            .folder(id)
            .ok_or_else(|| anyhow!("folder {id} is missing"))?;
        Ok(MobileNode {
            kind: "folder".to_string(),
            id: id.to_string(),
            name: folder.name.clone(),
            color_index: None,
            is_daily_queue: false,
            children: folder
                .children
                .iter()
                .filter_map(|child| self.child_node(child).transpose())
                .collect::<Result<Vec<_>>>()?,
        })
    }

    fn child_node(&self, child: &NodeRef) -> Result<Option<MobileNode>> {
        match child {
            NodeRef::Folder(id) => self.folder_node(*id).map(Some),
            NodeRef::Scheme(id) => {
                let Some(scheme) = self.workspace.scheme(*id) else {
                    return Ok(None);
                };
                if self.workspace.is_daily_queue_scheme(scheme.id)
                    || self.workspace.is_scheme_deleted(scheme.id)
                {
                    return Ok(None);
                }
                Ok(Some(MobileNode {
                    kind: "scheme".to_string(),
                    id: scheme.id.to_string(),
                    name: scheme.name.clone(),
                    color_index: Some(i32::from(scheme.color_index)),
                    is_daily_queue: false,
                    children: Vec::new(),
                }))
            }
        }
    }

    fn mobile_scheme(&self, scheme: &Scheme) -> MobileScheme {
        let is_daily_queue = self.workspace.is_daily_queue_scheme(scheme.id);
        let date = self.workspace.daily_queue_date_for_scheme(scheme.id);
        let default_daily_name = date.map(daily_queue_scheme_name);
        let display_name = if is_daily_queue {
            match (date, default_daily_name.as_deref()) {
                (Some(date), Some(default_name)) if scheme.name == default_name => {
                    format_daily_label(date)
                }
                _ => scheme.name.clone(),
            }
        } else {
            scheme.name.clone()
        };
        let items = scheme
            .items
            .iter()
            .map(|item| MobileItem::from_item(item, &self.image_assets_dir))
            .collect::<Vec<_>>();
        MobileScheme {
            id: scheme.id.to_string(),
            name: scheme.name.clone(),
            display_name,
            color_index: i32::from(scheme.color_index),
            is_daily_queue,
            date: date.map(|date| date.to_string()),
            items,
        }
    }

    fn search(&self, query: &str) -> Result<Vec<MobileSearchHit>> {
        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let hits = indexed
            .search_query(
                self.settings.time_format,
                SearchOptions {
                    daily_queue_title: "Daily",
                    daily_queue_marker_color: DAILY_QUEUE_MARKER_COLOR,
                },
            )
            .run(query)
            .into_iter()
            .map(|hit| MobileSearchHit {
                target_kind: match &hit.target {
                    SearchTarget::Calendar => "calendar".to_string(),
                    SearchTarget::DailyQueue { .. } => "daily_queue".to_string(),
                    SearchTarget::Scheme { .. } => "scheme".to_string(),
                },
                scheme_id: match &hit.target {
                    SearchTarget::DailyQueue { scheme_id, .. } => {
                        scheme_id.map(|id| id.to_string())
                    }
                    SearchTarget::Scheme { scheme_id, .. } => Some(scheme_id.to_string()),
                    SearchTarget::Calendar => None,
                },
                item_id: match &hit.target {
                    SearchTarget::DailyQueue { item_id, .. }
                    | SearchTarget::Scheme { item_id, .. } => item_id.map(|id| id.to_string()),
                    SearchTarget::Calendar => None,
                },
                scheme_name: hit.scheme_name,
                color_index: hit.color_index.map(i32::from),
                title: hit.title,
                detail: hit.detail,
                status: match hit.status {
                    SearchHitStatus::None => "none".to_string(),
                    SearchHitStatus::Date { .. } => "date".to_string(),
                    SearchHitStatus::Event { .. } => "event".to_string(),
                    SearchHitStatus::DailyQueue => "daily_queue".to_string(),
                },
            })
            .collect();
        Ok(hits)
    }

    fn restore_deleted_scheme(&mut self, scheme_id: SchemeId) -> Result<()> {
        if !self.workspace.is_scheme_deleted(scheme_id) {
            return Ok(());
        }
        let Some(scheme) = self.workspace.scheme(scheme_id).cloned() else {
            self.workspace.unmark_scheme_deleted(scheme_id);
            self.record_crdt_changes(WorkspaceCrdtChangeSet::default().workspace())?;
            return self.save_workspace();
        };
        let (folder, position) = self.deleted_scheme_restore_target(scheme_id);
        self.apply(Command::RestoreScheme {
            folder,
            position,
            scheme,
        })
    }

    fn empty_archive(&mut self) -> Result<()> {
        let deleted = self.workspace.recently_deleted.clone();
        for id in deleted {
            self.apply(Command::PermanentlyDeleteScheme { id })?;
        }
        Ok(())
    }

    fn deleted_scheme_restore_target(&self, scheme_id: SchemeId) -> (FolderId, usize) {
        if let Some(origin) = self.workspace.deleted_scheme_origin(scheme_id) {
            if self.is_valid_scheme_restore_folder(origin.folder) {
                let len = self
                    .workspace
                    .folder(origin.folder)
                    .map(|folder| folder.children.len())
                    .unwrap_or(0);
                return (origin.folder, origin.position.min(len));
            }
        }

        let root = self.workspace.root;
        let position = self
            .workspace
            .folder(root)
            .map(|folder| folder.children.len())
            .unwrap_or(0);
        (root, position)
    }

    fn is_valid_scheme_restore_folder(&self, folder: FolderId) -> bool {
        self.workspace.folder(folder).is_some()
    }

    fn seed_editor_image_fixture(&mut self) -> Result<()> {
        if self.workspace.iter_schemes().any(|scheme| {
            scheme
                .items
                .iter()
                .any(|item| item.text == EDITOR_IMAGE_FIXTURE_TEXT && !item.media.is_empty())
        }) {
            return Ok(());
        }

        if self
            .workspace
            .iter_schemes()
            .all(|scheme| self.workspace.is_daily_queue_scheme(scheme.id))
        {
            self.apply(Command::CreateScheme {
                folder: self.workspace.root,
                name: "Editor Layout Test".to_string(),
                color_index: next_color_index(&self.workspace),
                position: None,
            })?;
        }

        let target_id = self
            .workspace
            .iter_schemes()
            .find(|scheme| !self.workspace.is_daily_queue_scheme(scheme.id))
            .map(|scheme| scheme.id)
            .ok_or_else(|| anyhow!("no writable scheme available for image fixture"))?;

        fs::create_dir_all(&self.image_assets_dir)
            .with_context(|| format!("create {}", self.image_assets_dir.display()))?;
        let asset = uuid::Uuid::new_v4();
        let asset_path = self.image_assets_dir.join(format!("{asset}.png"));
        fs::write(&asset_path, EDITOR_IMAGE_FIXTURE_PNG)
            .with_context(|| format!("write {}", asset_path.display()))?;

        let mut item = Item::new(EDITOR_IMAGE_FIXTURE_TEXT);
        item.media.push(ItemMedia::Image {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(320),
            height: Some(180),
        });

        let scheme = self
            .workspace
            .scheme_mut(target_id)
            .ok_or_else(|| anyhow!("scheme {target_id} is missing"))?;
        scheme.items.push(item);
        self.record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(target_id))?;
        self.save_workspace()
    }

    fn replace_scheme_items(
        &mut self,
        scheme_id: SchemeId,
        drafts: Vec<MobileItemEdit>,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let existing = self
            .workspace
            .scheme(scheme_id)
            .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?
            .items
            .clone();
        let mut used_ids = Vec::<ItemId>::new();
        let mut next_items = Vec::with_capacity(drafts.len());

        for draft in drafts {
            let existing_id = draft.id.as_deref().map(parse_id::<ItemId>).transpose()?;
            let mut item = existing_id
                .and_then(|id| {
                    if used_ids.contains(&id) {
                        return None;
                    }
                    existing.iter().find(|item| item.id == id).cloned()
                })
                .unwrap_or_else(|| Item::new(""));

            used_ids.push(item.id);
            item.text = draft.text;
            item.marker = parse_marker(Some(&draft.marker))?;
            item.indent = as_u8(draft.indent, "indent")?.min(8);
            item.enforce_marker_constraints();
            if item.marker == ItemMarker::Checkbox {
                item.state_for_occurrence_mut(OccurrenceId::Single).progress =
                    if draft.done { -1 } else { 0 };
                item.normalize_state();
            }
            next_items.push(item);
        }

        let scheme = self
            .workspace
            .scheme_mut(scheme_id)
            .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?;
        scheme.items = next_items;
        self.workspace.normalize_item_markers();
        self.record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(scheme_id))?;
        self.save_workspace()
    }
}

#[derive(Clone, Copy)]
struct MobileSyncDocumentRef {
    document: DocumentId,
    kind: SyncDocumentKind,
}

struct MobileSyncHttpClient {
    api_base: String,
    bearer_token: String,
}

fn mobile_sync_documents(workspace: &Workspace) -> Vec<MobileSyncDocumentRef> {
    let mut docs = vec![MobileSyncDocumentRef {
        document: workspace.sync.id,
        kind: SyncDocumentKind::PersonalWorkspace,
    }];
    docs.extend(mobile_scheme_documents(workspace));
    docs
}

fn mobile_scheme_documents(workspace: &Workspace) -> Vec<MobileSyncDocumentRef> {
    workspace
        .scheme_sync
        .values()
        .filter(|meta| meta.kind == SyncDocumentKind::Scheme)
        .map(|meta| MobileSyncDocumentRef {
            document: meta.id,
            kind: SyncDocumentKind::Scheme,
        })
        .collect()
}

fn mobile_upsert_documents(
    client: &MobileSyncHttpClient,
    workspace_id: WorkspaceId,
    docs: Vec<MobileSyncDocumentRef>,
) -> Result<()> {
    let mut seen = HashSet::new();
    for doc in docs {
        if seen.insert(doc.document) {
            client.upsert_document(workspace_id, doc)?;
        }
    }
    Ok(())
}

struct MobileAccumulatedPull {
    updates: Vec<StoredCrdtUpdate>,
    latest_sequence: u64,
    forced_snapshot: bool,
}

/// Pull a document one bounded page at a time, following the server's `has_more`
/// flag until caught up. Without this loop a far-behind replica would receive
/// only the first server page yet advance its cursor to `latest_sequence`,
/// silently skipping every update beyond that page.
fn mobile_pull_document(
    client: &MobileSyncHttpClient,
    sync_state: &LocalSyncState,
    workspace_id: WorkspaceId,
    doc: MobileSyncDocumentRef,
    replica_id: ReplicaId,
) -> Result<MobileAccumulatedPull> {
    let mut after = sync_state
        .document_cursors
        .get(&doc.document)
        .map(|cursor| cursor.last_pulled_sequence)
        .unwrap_or(0);
    let mut updates = Vec::new();
    let mut latest_sequence;
    let mut forced_snapshot = false;
    loop {
        let response = client.pull_updates(workspace_id, doc.document, after, replica_id)?;
        latest_sequence = response.latest_sequence;
        forced_snapshot |= response.forced_snapshot;
        let page = mobile_pull_response_updates(&response);
        let page_max = page.iter().map(|update| update.sequence).max();
        updates.extend(page);
        match page_max {
            Some(max) if response.has_more && max > after => after = max,
            _ => break,
        }
    }
    Ok(MobileAccumulatedPull {
        updates,
        latest_sequence,
        forced_snapshot,
    })
}

fn mobile_pull_response_updates(response: &PullUpdatesResponse) -> Vec<StoredCrdtUpdate> {
    let mut updates = Vec::new();
    if let Some(snapshot) = &response.snapshot {
        updates.push(mobile_snapshot_as_update(snapshot));
    }
    updates.extend(response.updates.iter().cloned());
    updates
}

fn mobile_snapshot_as_update(snapshot: &StoredCrdtSnapshot) -> StoredCrdtUpdate {
    StoredCrdtUpdate {
        workspace_id: snapshot.workspace_id,
        document: snapshot.document,
        kind: snapshot.kind,
        replica_id: ReplicaId::new(),
        sequence: snapshot.sequence,
        received_at: snapshot.compacted_at,
        update_v1: snapshot.update_v1.clone(),
    }
}

fn mobile_queue_bootstrap_updates(
    sync_state: &mut LocalSyncState,
    workspace: &Workspace,
    replica_id: ReplicaId,
    remote_latest: &HashMap<DocumentId, u64>,
) {
    let mut next_sequence = sync_state
        .pending
        .iter()
        .map(|edit| edit.local_sequence)
        .max()
        .unwrap_or(0)
        + 1;
    for update in WorkspaceCrdtDocuments::snapshot_updates(workspace).updates {
        if remote_latest.get(&update.document).copied().unwrap_or(0) != 0 {
            continue;
        }
        if sync_state
            .pending
            .iter()
            .any(|pending| pending.document == update.document)
        {
            continue;
        }
        if sync_state
            .document_cursors
            .get(&update.document)
            .is_some_and(|cursor| cursor.last_pushed_sequence > 0)
        {
            continue;
        }
        sync_state.push_pending(PendingCrdtEdit {
            operation_id: OperationId::new(),
            workspace_id: workspace.id,
            replica_id,
            local_sequence: next_sequence,
            created_at: Utc::now(),
            document: update.document,
            kind: update.kind,
            update_v1: update.update_v1,
        });
        next_sequence += 1;
    }
}

fn mobile_push_pending_documents(
    client: &MobileSyncHttpClient,
    sync_state: &mut LocalSyncState,
    workspace_id: WorkspaceId,
) -> Result<bool> {
    let mut pushed_any = false;
    loop {
        let Some(document) = sync_state.pending.front().map(|edit| edit.document) else {
            return Ok(pushed_any);
        };
        let pending = sync_state.pending_for_document(document, SYNC_BATCH_LIMIT);
        if pending.is_empty() {
            return Ok(pushed_any);
        }
        let kind = pending[0].kind;
        client.upsert_document(workspace_id, MobileSyncDocumentRef { document, kind })?;
        let request = sync_state
            .next_push_request(document, SYNC_BATCH_LIMIT)
            .ok_or_else(|| anyhow!("missing push request for pending document"))?;
        let through_local_sequence = pending
            .iter()
            .map(|edit| edit.local_sequence)
            .max()
            .unwrap_or(0);
        let response = client.push_updates(workspace_id, document, &request)?;
        if response.accepted != request.updates.len() {
            return Err(anyhow!(
                "sync backend accepted {}/{} updates for {}",
                response.accepted,
                request.updates.len(),
                document
            ));
        }
        sync_state.mark_pushed(document, through_local_sequence);
        pushed_any = true;
    }
}

impl MobileSyncHttpClient {
    fn upsert_document(&self, workspace_id: WorkspaceId, doc: MobileSyncDocumentRef) -> Result<()> {
        let url = format!(
            "{}/v1/workspaces/{}/documents/{}",
            self.api_base, workspace_id, doc.document
        );
        self.put_json::<_, knotq_sync::DocumentResponse>(
            &url,
            &UpsertDocumentRequest { kind: doc.kind },
        )
        .map(|_| ())
    }

    fn pull_updates(
        &self,
        workspace_id: WorkspaceId,
        document: DocumentId,
        after: u64,
        replica_id: ReplicaId,
    ) -> Result<PullUpdatesResponse> {
        let url = format!(
            "{}/v1/workspaces/{}/documents/{}/updates?after={}&exclude_replica={}",
            self.api_base, workspace_id, document, after, replica_id
        );
        self.get_json(&url)
    }

    fn push_updates(
        &self,
        workspace_id: WorkspaceId,
        document: DocumentId,
        request: &PushUpdatesRequest,
    ) -> Result<PushUpdatesResponse> {
        let url = format!(
            "{}/v1/workspaces/{}/documents/{}/updates",
            self.api_base, workspace_id, document
        );
        self.post_json(&url, request)
    }

    fn get_json<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T> {
        self.authorized(ureq::get(url))
            .call()
            .map_err(mobile_sync_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }

    fn post_json<T, R>(&self, url: &str, body: &T) -> Result<R>
    where
        T: serde::Serialize,
        R: serde::de::DeserializeOwned,
    {
        self.authorized(ureq::post(url))
            .send_json(serde_json::to_value(body)?)
            .map_err(mobile_sync_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }

    fn put_json<T, R>(&self, url: &str, body: &T) -> Result<R>
    where
        T: serde::Serialize,
        R: serde::de::DeserializeOwned,
    {
        self.authorized(ureq::put(url))
            .send_json(serde_json::to_value(body)?)
            .map_err(mobile_sync_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }

    fn authorized(&self, request: ureq::Request) -> ureq::Request {
        request
            .timeout(std::time::Duration::from_secs(30))
            .set("authorization", &format!("Bearer {}", self.bearer_token))
    }
}

fn mobile_sync_http_error(error: ureq::Error) -> anyhow::Error {
    match error {
        ureq::Error::Status(status, response) => {
            let code = response
                .into_json::<knotq_sync::ErrorResponse>()
                .map(|error| error.code)
                .unwrap_or_else(|_| status.to_string());
            anyhow!("sync backend rejected request: {code}")
        }
        error => anyhow!("sync backend request failed: {error}"),
    }
}

fn normalize_sync_api_base(raw: &str) -> Result<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err(anyhow!("sync API URL is empty"));
    }
    // The bearer token and all workspace contents travel over this URL. Refuse
    // plaintext HTTP to anything other than a loopback dev server so a misconfig
    // can't silently leak credentials in the clear.
    if !mobile_is_secure_api_base(trimmed) {
        return Err(anyhow!("sync API URL must use https:// (got {trimmed})"));
    }
    Ok(trimmed.to_string())
}

fn mobile_is_secure_api_base(url: &str) -> bool {
    if let Some(host) = url.strip_prefix("https://") {
        return !host.is_empty();
    }
    if let Some(rest) = url.strip_prefix("http://") {
        let host = rest
            .split(['/', ':'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        return matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]" | "::1");
    }
    false
}

#[cfg(test)]
mod sync_api_base_tests {
    use super::normalize_sync_api_base;

    #[test]
    fn https_is_accepted_http_loopback_only() {
        assert_eq!(
            normalize_sync_api_base("https://sync.example.com/").unwrap(),
            "https://sync.example.com"
        );
        assert!(normalize_sync_api_base("http://127.0.0.1:8787").is_ok());
        assert!(normalize_sync_api_base("http://sync.example.com").is_err());
        assert!(normalize_sync_api_base("").is_err());
    }
}

fn mobile_crdt_change_set_for_command(command: &Command) -> WorkspaceCrdtChangeSet {
    let mut changes = WorkspaceCrdtChangeSet::default();
    mobile_collect_crdt_changes(command, &mut changes);
    changes
}

fn mobile_collect_crdt_changes(command: &Command, out: &mut WorkspaceCrdtChangeSet) {
    match command {
        Command::CreateFolder { .. }
        | Command::RestoreFolder { .. }
        | Command::RenameFolder { .. }
        | Command::SetFolderExpanded { .. }
        | Command::DeleteFolder { .. }
        | Command::CreateScheme { .. }
        | Command::RenameScheme { .. }
        | Command::SetSchemeColor { .. }
        | Command::SetSchemeGsync { .. }
        | Command::SetSchemeSource { .. }
        | Command::DeleteScheme { .. }
        | Command::PermanentlyDeleteScheme { .. }
        | Command::MoveNode { .. } => {
            out.workspace = true;
        }
        Command::RestoreScheme { scheme, .. } | Command::RestoreDeletedScheme { scheme, .. } => {
            out.workspace = true;
            out.schemes.insert(scheme.id);
        }
        Command::InsertItem { scheme, .. }
        | Command::UpdateItemText { scheme, .. }
        | Command::ReplaceItem { scheme, .. }
        | Command::SetItemIndent { scheme, .. }
        | Command::SetItemMarker { scheme, .. }
        | Command::SetItemDate { scheme, .. }
        | Command::SetItemRecurrence { scheme, .. }
        | Command::SetItemPriority { scheme, .. }
        | Command::SetOccurrenceNotificationOffset { scheme, .. }
        | Command::ToggleOccurrence { scheme, .. }
        | Command::DeleteItem { scheme, .. }
        | Command::ReorderItem { scheme, .. } => {
            out.schemes.insert(*scheme);
        }
        Command::Batch(commands) => {
            for command in commands {
                mobile_collect_crdt_changes(command, out);
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct MobileSnapshot {
    pub root: MobileNode,
    pub schemes: Vec<MobileScheme>,
    pub archived_schemes: Vec<MobileScheme>,
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
    pub children: Vec<MobileNode>,
}

#[derive(Clone, Debug)]
pub struct MobileScheme {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub color_index: i32,
    pub is_daily_queue: bool,
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
    pub repeat_rule: Option<String>,
    pub media: Vec<MobileItemMedia>,
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
pub struct MobileItemEdit {
    pub id: Option<String>,
    pub text: String,
    pub marker: String,
    pub indent: i32,
    pub done: bool,
}

impl MobileItem {
    fn from_item(item: &Item, image_assets_dir: &Path) -> Self {
        Self {
            id: item.id.to_string(),
            text: item.text.clone(),
            marker: marker_str(item.marker).to_string(),
            indent: i32::from(item.indent),
            kind: item_kind_str(item.kind()).to_string(),
            done: item.single_state().is_done(),
            start: item.start.map(format_datetime),
            end: item.end.map(format_datetime),
            repeat_rule: recurrence_rule(item.repeats.as_ref()),
            media: item
                .media
                .iter()
                .filter_map(|media| MobileItemMedia::from_media(media, image_assets_dir))
                .collect(),
        }
    }
}

/// Extracts the first RRULE body from a recurrence for display on the client.
fn recurrence_rule(repeats: Option<&Recurrence>) -> Option<String> {
    repeats.and_then(|r| r.rrules.first().cloned())
}

impl MobileItemMedia {
    fn from_media(media: &ItemMedia, image_assets_dir: &Path) -> Option<Self> {
        let ItemMedia::Image {
            asset,
            format,
            width,
            height,
        } = media;
        Some(Self {
            kind: "image".to_string(),
            path: Some(
                image_assets_dir
                    .join(format!("{asset}.{}", format.extension()))
                    .display()
                    .to_string(),
            ),
            format: image_format_str(*format).to_string(),
            width: width.and_then(|value| i32::try_from(value).ok()),
            height: height.and_then(|value| i32::try_from(value).ok()),
        })
    }
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
    pub scheme_name: String,
    pub color_index: i32,
    pub title: String,
    pub kind: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub local_date: Option<String>,
    pub repeat_rule: Option<String>,
}

impl MobileOccurrence {
    fn from_context(
        workspace: &Workspace,
        context: knotq_index::calendar::OccurrenceWithContext,
    ) -> Self {
        let item = workspace
            .scheme(context.scheme_id)
            .and_then(|scheme| scheme.item(context.item_id));
        let title = item.map(|item| item.text.clone()).unwrap_or_default();
        let repeat_rule = item.and_then(|item| recurrence_rule(item.repeats.as_ref()));
        let local_date = context
            .occurrence
            .start
            .or(context.occurrence.end)
            .map(|dt| dt.date_naive().to_string());
        let occurrence_json = serde_json::to_string(&context.occurrence.id).unwrap_or_default();
        Self {
            scheme_id: context.scheme_id.to_string(),
            item_id: context.item_id.to_string(),
            occurrence_json,
            scheme_name: context.scheme_name,
            color_index: i32::from(context.color_index),
            title,
            kind: item_kind_str(context.occurrence.kind).to_string(),
            done: context.occurrence.state.is_done(),
            start: context.occurrence.start.map(format_datetime),
            end: context.occurrence.end.map(format_datetime),
            local_date,
            repeat_rule,
        }
    }
}

#[derive(Clone, Debug)]
pub struct MobileSettings {
    pub theme_mode: String,
    pub time_format: String,
}

#[derive(Clone, Debug)]
pub struct MobileNotificationRequest {
    pub id: String,
    pub notification_key: String,
    pub fire_at: String,
    pub expires_at: Option<String>,
    pub title: String,
    pub body: String,
    pub kind: String,
    pub scheme_id: String,
    pub item_id: String,
    pub occurrence_json: String,
    pub trigger_at: String,
}

impl MobileNotificationRequest {
    fn from_scheduled(notification: ScheduledNotification) -> Self {
        let occurrence_json = serde_json::to_string(&notification.occurrence).unwrap_or_default();
        let notification_key = notification.key;
        Self {
            id: mobile_notification_id(&notification_key),
            notification_key,
            fire_at: format_datetime(notification.fire_at),
            expires_at: notification.expires_at.map(format_datetime),
            title: notification.title,
            body: notification.body,
            kind: match notification.kind {
                knotq_notifications::NotificationKind::Reminder => "reminder",
                knotq_notifications::NotificationKind::Event => "event",
                knotq_notifications::NotificationKind::Assignment => "assignment",
            }
            .to_string(),
            scheme_id: notification.scheme_id.to_string(),
            item_id: notification.item_id.to_string(),
            occurrence_json,
            trigger_at: format_datetime(notification.trigger_at),
        }
    }
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

fn parse_id<T>(raw: &str) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    raw.parse::<T>().with_context(|| format!("parse id {raw}"))
}

fn parse_marker(raw: Option<&str>) -> Result<ItemMarker> {
    Ok(match raw.unwrap_or("blank") {
        "blank" => ItemMarker::Blank,
        "bullet" => ItemMarker::Bullet,
        "numbered" => ItemMarker::Numbered,
        "checkbox" => ItemMarker::Checkbox,
        other => return Err(anyhow!("unknown marker {other}")),
    })
}

fn parse_date_kind(raw: &str) -> Result<DateKind> {
    Ok(match raw {
        "start" => DateKind::Start,
        "end" => DateKind::End,
        other => return Err(anyhow!("unknown date kind {other}")),
    })
}

fn parse_theme_mode(raw: &str) -> Result<ThemeMode> {
    Ok(match raw {
        "system" => ThemeMode::System,
        "dark" => ThemeMode::Dark,
        "light" => ThemeMode::Light,
        other => return Err(anyhow!("unknown theme mode {other}")),
    })
}

fn parse_time_format(raw: &str) -> Result<TimeFormat> {
    Ok(match raw {
        "twelve_hour" => TimeFormat::TwelveHour,
        "twenty_four_hour" => TimeFormat::TwentyFourHour,
        other => return Err(anyhow!("unknown time format {other}")),
    })
}

fn parse_date_or_today(raw: Option<&str>) -> Result<NaiveDate> {
    match raw {
        Some(raw) if !raw.is_empty() => Ok(NaiveDate::parse_from_str(raw, "%Y-%m-%d")?),
        _ => Ok(default_today()),
    }
}

fn parse_datetime_opt(raw: Option<&str>) -> Result<Option<DateTime<Utc>>> {
    match raw {
        Some(raw) if !raw.is_empty() => Ok(Some(parse_datetime(raw)?)),
        _ => Ok(None),
    }
}

fn parse_datetime(raw: &str) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(raw)?.with_timezone(&Utc))
}

fn default_today() -> NaiveDate {
    Utc::now().date_naive()
}

fn midnight_utc(date: NaiveDate) -> Result<DateTime<Utc>> {
    let naive = date
        .and_hms_opt(0, 0, 0)
        .ok_or_else(|| anyhow!("invalid midnight for {date}"))?;
    Ok(Utc.from_utc_datetime(&naive))
}

fn format_datetime(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn format_daily_label(date: NaiveDate) -> String {
    date.format("%a, %b %-d").to_string()
}

fn marker_str(marker: ItemMarker) -> &'static str {
    match marker {
        ItemMarker::Blank => "blank",
        ItemMarker::Bullet => "bullet",
        ItemMarker::Numbered => "numbered",
        ItemMarker::Checkbox => "checkbox",
    }
}

fn item_kind_str(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Reminder => "reminder",
        ItemKind::Assignment => "assignment",
        ItemKind::Event => "event",
        ItemKind::Procedure => "procedure",
    }
}

fn image_format_str(format: ImageAssetFormat) -> &'static str {
    match format {
        ImageAssetFormat::Png => "png",
        ImageAssetFormat::Jpeg => "jpeg",
        ImageAssetFormat::Webp => "webp",
        ImageAssetFormat::Gif => "gif",
        ImageAssetFormat::Svg => "svg",
        ImageAssetFormat::Bmp => "bmp",
        ImageAssetFormat::Tiff => "tiff",
    }
}

fn theme_mode_str(theme_mode: ThemeMode) -> &'static str {
    match theme_mode {
        ThemeMode::System => "system",
        ThemeMode::Dark => "dark",
        ThemeMode::Light => "light",
    }
}

fn time_format_str(time_format: TimeFormat) -> &'static str {
    match time_format {
        TimeFormat::TwelveHour => "twelve_hour",
        TimeFormat::TwentyFourHour => "twenty_four_hour",
    }
}

fn mobile_notification_lead_times(defaults: NotificationDefaults) -> NotificationLeadTimes {
    NotificationLeadTimes {
        reminder_offset_secs: 0,
        event_offset_secs: defaults.event_offset_secs,
        assignment_offset_secs: defaults.assignment_offset_secs,
    }
}

fn mobile_notification_id(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    format!(
        "knotq-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7]
    )
}

fn next_color_index(workspace: &Workspace) -> u8 {
    let count = workspace
        .iter_schemes()
        .filter(|scheme| !workspace.is_daily_queue_scheme(scheme.id))
        .count();
    (count % 10) as u8
}

fn opt_position(position: Option<i32>) -> Result<Option<usize>> {
    position.map(position_from_i32).transpose()
}

fn position_from_i32(position: i32) -> Result<usize> {
    usize::try_from(position).map_err(|_| anyhow!("position cannot be negative: {position}"))
}

fn as_u8(value: i32, label: &str) -> Result<u8> {
    u8::try_from(value).map_err(|_| anyhow!("{label} must be between 0 and 255: {value}"))
}

uniffi::include_scaffolding!("knotq_mobile_core");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mobile_core_flow_creates_edits_and_searches() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        assert!(!snapshot.schemes.is_empty());

        core.create_scheme(None, "Mobile Smoke".to_string(), Some(1), None)
            .expect("create scheme");
        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot after create");
        let scheme = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.display_name == "Mobile Smoke")
            .expect("created scheme");

        core.add_item(
            scheme.id.clone(),
            "Check mobile bridge".to_string(),
            Some("checkbox".to_string()),
            None,
            None,
        )
        .expect("add item");

        let hits = core.search("bridge".to_string()).expect("search");
        assert!(hits.iter().any(|hit| hit.title == "Check mobile bridge"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn replace_scheme_items_preserves_existing_metadata() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Editor".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Editor")
            .expect("created scheme")
            .id;

        core.add_item(
            scheme_id.clone(),
            "Keep my date".to_string(),
            Some("checkbox".to_string()),
            None,
            None,
        )
        .expect("add item");
        let item_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_date(
            scheme_id.clone(),
            item_id.clone(),
            "start".to_string(),
            Some("2026-05-27T12:00:00Z".to_string()),
        )
        .expect("set date");

        core.replace_scheme_items(
            scheme_id.clone(),
            vec![
                MobileItemEdit {
                    id: Some(item_id.clone()),
                    text: "Keep my edited date".to_string(),
                    marker: "checkbox".to_string(),
                    indent: 1,
                    done: true,
                },
                MobileItemEdit {
                    id: None,
                    text: "New child".to_string(),
                    marker: "bullet".to_string(),
                    indent: 2,
                    done: false,
                },
            ],
        )
        .expect("replace items");

        let scheme = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme");
        assert_eq!(scheme.items.len(), 2);
        assert_eq!(scheme.items[0].id, item_id);
        assert_eq!(scheme.items[0].text, "Keep my edited date");
        assert_eq!(scheme.items[0].indent, 1);
        assert!(scheme.items[0].done);
        assert_eq!(
            scheme.items[0].start.as_deref(),
            Some("2026-05-27T12:00:00Z")
        );
        assert_eq!(scheme.items[1].marker, "bullet");
        assert_eq!(scheme.items[1].indent, 2);

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn replace_scheme_items_clears_calendar_metadata_for_plain_text() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Editor".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Editor")
            .expect("created scheme")
            .id;

        core.add_item(
            scheme_id.clone(),
            "Drop my date".to_string(),
            Some("checkbox".to_string()),
            None,
            None,
        )
        .expect("add item");
        let item_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_date(
            scheme_id.clone(),
            item_id.clone(),
            "start".to_string(),
            Some("2026-05-27T12:00:00Z".to_string()),
        )
        .expect("set start");
        core.set_item_date(
            scheme_id.clone(),
            item_id.clone(),
            "end".to_string(),
            Some("2026-05-27T13:00:00Z".to_string()),
        )
        .expect("set end");
        core.set_item_recurrence(
            scheme_id.clone(),
            item_id.clone(),
            Some("FREQ=WEEKLY;INTERVAL=1".to_string()),
        )
        .expect("set recurrence");

        core.replace_scheme_items(
            scheme_id.clone(),
            vec![MobileItemEdit {
                id: Some(item_id.clone()),
                text: "Plain text now".to_string(),
                marker: "blank".to_string(),
                indent: 0,
                done: false,
            }],
        )
        .expect("replace items");

        let item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| item.id == item_id)
            .expect("item");
        assert_eq!(item.marker, "blank");
        assert_eq!(item.kind, "procedure");
        assert_eq!(item.start, None);
        assert_eq!(item.end, None);
        assert_eq!(item.repeat_rule, None);

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn pending_notifications_use_stable_mobile_ids_and_actions() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.add_calendar_item(
            None,
            Some("2026-05-27".to_string()),
            "Send deck".to_string(),
            "reminder".to_string(),
            Some("2026-05-27T15:00:00Z".to_string()),
            None,
        )
        .expect("add reminder");

        let requests = core
            .pending_notifications(Some("2026-05-27T12:00:00Z".to_string()), 14)
            .expect("pending notifications");
        let request = requests
            .iter()
            .find(|request| request.title == "Send deck")
            .expect("new reminder notification");
        assert!(request.id.starts_with("knotq-"));
        assert_eq!(request.kind, "reminder");

        let changed = core
            .apply_notification_action(
                ACTION_MARK_DONE.to_string(),
                request.scheme_id.clone(),
                request.item_id.clone(),
                request.occurrence_json.clone(),
                request.trigger_at.clone(),
            )
            .expect("mark done");
        assert!(changed);

        let requests = core
            .pending_notifications(Some("2026-05-27T12:00:00Z".to_string()), 14)
            .expect("pending notifications after action");
        assert!(!requests.iter().any(|request| request.title == "Send deck"));

        let _ = std::fs::remove_dir_all(dir);
    }
}
