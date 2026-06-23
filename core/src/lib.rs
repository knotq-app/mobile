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
    batch_pull_and_apply, batch_push_pending, queue_workspace_bootstrap_updates, DevicePlatform,
    NotificationPermissionState, PendingCrdtEdit, PushChannel, PushEnvironment,
    RegisterDeviceRequest, WorkspaceCrdtChangeSet, WorkspaceCrdtDocuments,
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

    pub fn snapshot(
        &self,
        today: Option<String>,
        week_offset: i32,
    ) -> Result<MobileSnapshot, MobileError> {
        self.snapshot_with_daily_history(today, week_offset, MOBILE_DAILY_DEFAULT_HISTORY_DAYS)
    }

    pub fn snapshot_with_daily_history(
        &self,
        today: Option<String>,
        week_offset: i32,
        daily_history_days: i32,
    ) -> Result<MobileSnapshot, MobileError> {
        let today = parse_date_or_today(today.as_deref())?;
        let daily_history_days = normalize_daily_history_days(daily_history_days);
        self.lock()?
            .snapshot(today, week_offset, daily_history_days)
            .map_err(Into::into)
    }

    pub fn month_days(&self, year: i32, month: u32) -> Result<Vec<MobileCalendarDay>, MobileError> {
        let mut inner = self.lock()?;
        inner.month_days(year, month).map_err(Into::into)
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

    pub fn restore_folder(&self, folder_id: String) -> Result<(), MobileError> {
        self.lock()?
            .restore_deleted_folder(parse_id(&folder_id)?)
            .map_err(Into::into)
    }

    pub fn permanently_delete_folder(&self, folder_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::PermanentlyDeleteFolder {
                id: parse_id(&folder_id)?,
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

    pub fn google_auth_request(
        &self,
        client_id: String,
        redirect_uri: String,
    ) -> Result<MobileGoogleAuthRequest, MobileError> {
        let client_id = non_empty(client_id, "Google client id")?;
        let redirect_uri = non_empty(redirect_uri, "Google redirect URI")?;
        Ok(google_calendar::google_auth_request(
            client_id,
            redirect_uri,
        ))
    }

    pub fn complete_google_calendar_import(
        &self,
        client_id: String,
        redirect_uri: String,
        state: String,
        code_verifier: String,
        callback_url: String,
        parent_id: Option<String>,
    ) -> Result<MobileGoogleSyncResult, MobileError> {
        let config = GoogleOAuthConfig {
            client_id: non_empty(client_id, "Google client id")?,
        };
        let mut inner = self.lock()?;
        let parent = parent_id
            .as_deref()
            .map(parse_id)
            .transpose()?
            .unwrap_or(inner.workspace.root);
        inner
            .complete_google_calendar_import(
                config,
                non_empty(redirect_uri, "Google redirect URI")?,
                non_empty(state, "Google OAuth state")?,
                non_empty(code_verifier, "Google OAuth code verifier")?,
                non_empty(callback_url, "Google OAuth callback URL")?,
                parent,
            )
            .map_err(Into::into)
    }

    pub fn sync_google_calendars(&self) -> Result<MobileGoogleSyncResult, MobileError> {
        self.lock()?.sync_google_calendars().map_err(Into::into)
    }

    pub fn unlink_google_account(&self, account_id: String) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner
            .unlink_google_account(&non_empty(account_id, "Google account id")?)
            .map_err(Into::into)
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

    pub fn add_today_daily_item(
        &self,
        today: String,
        text: String,
        marker: Option<String>,
        indent: Option<i32>,
    ) -> Result<(), MobileError> {
        let today = parse_date_or_today(Some(&today))?;
        let mut inner = self.lock()?;
        let scheme_id = inner.ensure_daily_queue(today)?;
        let mut item = Item::new(text);
        item.marker = parse_marker(marker.as_deref())?;
        item.indent = as_u8(indent.unwrap_or(0), "indent")?;
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

    pub fn add_calendar_item(
        &self,
        scheme_id: Option<String>,
        date: Option<String>,
        text: String,
        kind: String,
        start: Option<String>,
        end: Option<String>,
    ) -> Result<(), MobileError> {
        let _date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        let scheme_id = match scheme_id {
            Some(id) => parse_id(&id)?,
            None => inner.ensure_daily_queue(default_today())?,
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

    pub fn insert_table(
        &self,
        scheme_id: String,
        after_item_id: Option<String>,
        item_id: String,
    ) -> Result<(), MobileError> {
        let scheme_id = parse_id(&scheme_id)?;
        let after_item_id = after_item_id
            .as_deref()
            .map(parse_id::<ItemId>)
            .transpose()?;
        let item_id = parse_id::<ItemId>(&item_id)?;
        self.lock()?
            .insert_table(scheme_id, after_item_id, item_id)
            .map_err(Into::into)
    }

    pub fn set_table_cell_text(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
        column: i32,
        text: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let row = position_from_i32(row)?;
                let column = position_from_i32(column)?;
                let cell = table
                    .cell_mut(row, column)
                    .ok_or_else(|| anyhow!("table cell {row},{column} is missing"))?;
                let mut lines = text.split('\n');
                let mut items = Vec::new();
                if let Some(first_text) = lines.next() {
                    let mut first = cell.items.first().cloned().unwrap_or_else(|| Item::new(""));
                    first.set_text(first_text.to_string());
                    items.push(first);
                }
                for line in lines {
                    items.push(Item::new(line.to_string()));
                }
                cell.items = items;
                Ok(())
            })
            .map_err(Into::into)
    }

    pub fn set_table_column_name(
        &self,
        scheme_id: String,
        item_id: String,
        column: i32,
        name: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let column = position_from_i32(column)?;
                let table_column = table
                    .columns
                    .get_mut(column)
                    .ok_or_else(|| anyhow!("table column {column} is missing"))?;
                table_column.name = name;
                Ok(())
            })
            .map_err(Into::into)
    }

    /// Set the text of a single line within a cell (the cell sub-document line at
    /// `line_index`). Preserves the line's marker, dates, completion, and images.
    pub fn set_table_cell_line_text(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
        column: i32,
        line_index: i32,
        text: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let row = position_from_i32(row)?;
                let column = position_from_i32(column)?;
                let line_index = position_from_i32(line_index)?;
                let cell = table
                    .cell_mut(row, column)
                    .ok_or_else(|| anyhow!("table cell {row},{column} is missing"))?;
                let line = cell
                    .items
                    .get_mut(line_index)
                    .ok_or_else(|| anyhow!("cell line {line_index} is missing"))?;
                line.set_text(text);
                Ok(())
            })
            .map_err(Into::into)
    }

    /// Insert a new blank line into a cell at `line_index` (clamped to the cell's
    /// length), seeded with `text`. Used for Enter-within-a-cell / multi-line cells.
    pub fn add_table_cell_line(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
        column: i32,
        line_index: i32,
        text: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let row = position_from_i32(row)?;
                let column = position_from_i32(column)?;
                let line_index = position_from_i32(line_index)?;
                let cell = table
                    .cell_mut(row, column)
                    .ok_or_else(|| anyhow!("table cell {row},{column} is missing"))?;
                let at = line_index.min(cell.items.len());
                cell.items.insert(at, Item::new(text));
                Ok(())
            })
            .map_err(Into::into)
    }

    /// Remove the line at `line_index` from a cell. A no-op floor is enforced by
    /// `Table::normalize` (a cell always keeps at least one line), so removing the
    /// last line leaves a single empty line.
    pub fn remove_table_cell_line(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
        column: i32,
        line_index: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let row = position_from_i32(row)?;
                let column = position_from_i32(column)?;
                let line_index = position_from_i32(line_index)?;
                let cell = table
                    .cell_mut(row, column)
                    .ok_or_else(|| anyhow!("table cell {row},{column} is missing"))?;
                if line_index < cell.items.len() {
                    cell.items.remove(line_index);
                }
                Ok(())
            })
            .map_err(Into::into)
    }

    pub fn insert_table_row(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let row = position_from_i32(row)?;
                table.insert_row(row.min(table.row_count()));
                Ok(())
            })
            .map_err(Into::into)
    }

    pub fn delete_table_row(
        &self,
        scheme_id: String,
        item_id: String,
        row: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                table.remove_row(position_from_i32(row)?);
                Ok(())
            })
            .map_err(Into::into)
    }

    pub fn insert_table_column(
        &self,
        scheme_id: String,
        item_id: String,
        column: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                let column = position_from_i32(column)?;
                let at = column.min(table.column_count());
                table.insert_column(at, format!("Column {}", at + 1));
                Ok(())
            })
            .map_err(Into::into)
    }

    pub fn delete_table_column(
        &self,
        scheme_id: String,
        item_id: String,
        column: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .mutate_table(parse_id(&scheme_id)?, parse_id(&item_id)?, |table| {
                table.remove_column(position_from_i32(column)?);
                Ok(())
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
        let repeats = recurrence_from_rrule(rrule);
        self.lock()?
            .apply(Command::SetItemRecurrence {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                repeats,
            })
            .map_err(Into::into)
    }

    pub fn set_occurrence_notification_offset(
        &self,
        scheme_id: String,
        item_id: String,
        occurrence_json: Option<String>,
        offset_secs: Option<i32>,
    ) -> Result<(), MobileError> {
        let occurrence = occurrence_json
            .as_deref()
            .filter(|raw| !raw.trim().is_empty())
            .map(parse_occurrence_json)
            .transpose()?
            .unwrap_or(OccurrenceId::Single);
        self.lock()?
            .apply(Command::SetOccurrenceNotificationOffset {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                occurrence,
                offset_secs: offset_secs.map(i64::from),
            })
            .map_err(Into::into)
    }

    pub fn commit_event_edit(
        &self,
        scheme_id: String,
        item_id: String,
        occurrence_json: String,
        occurrence_index: i32,
        title: String,
        occurrence_start: Option<String>,
        occurrence_end: Option<String>,
        start: Option<String>,
        end: Option<String>,
        rrule: Option<String>,
        notification_offset_secs: Option<i32>,
        notification_dirty: bool,
        done: bool,
        scope: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .commit_event_edit(
                parse_id(&scheme_id)?,
                parse_id(&item_id)?,
                parse_occurrence_json(&occurrence_json)?,
                position_from_i32(occurrence_index)?,
                title,
                parse_datetime_opt(occurrence_start.as_deref())?,
                parse_datetime_opt(occurrence_end.as_deref())?,
                parse_datetime_opt(start.as_deref())?,
                parse_datetime_opt(end.as_deref())?,
                recurrence_from_rrule(rrule),
                notification_offset_secs.map(i64::from),
                notification_dirty,
                done,
                parse_date_edit_scope(&scope)?,
            )
            .map_err(Into::into)
    }

    /// `commit_event_edit` with all arguments in one JSON payload. Android's
    /// JNA bridge mis-marshals the trailing booleans of the 14-argument form,
    /// so its bridge routes through this variant.
    pub fn commit_event_edit_payload(&self, payload: String) -> Result<(), MobileError> {
        #[derive(serde::Deserialize)]
        struct Payload {
            scheme_id: String,
            item_id: String,
            occurrence_json: String,
            #[serde(default)]
            occurrence_index: i32,
            #[serde(default)]
            title: String,
            occurrence_start: Option<String>,
            occurrence_end: Option<String>,
            start: Option<String>,
            end: Option<String>,
            rrule: Option<String>,
            notification_offset_secs: Option<i32>,
            #[serde(default)]
            notification_dirty: bool,
            #[serde(default)]
            done: bool,
            scope: String,
        }
        let payload: Payload = serde_json::from_str(&payload)
            .map_err(|error| anyhow!("invalid commit_event_edit payload: {error}"))?;
        self.commit_event_edit(
            payload.scheme_id,
            payload.item_id,
            payload.occurrence_json,
            payload.occurrence_index,
            payload.title,
            payload.occurrence_start,
            payload.occurrence_end,
            payload.start,
            payload.end,
            payload.rrule,
            payload.notification_offset_secs,
            payload.notification_dirty,
            payload.done,
            payload.scope,
        )
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
        let occurrence: OccurrenceId =
            serde_json::from_str(&occurrence_json).with_context(|| "parse occurrence")?;
        let scheme = parse_id(&scheme_id)?;
        let item = parse_id(&item_id)?;
        let mut inner = self.lock()?;
        inner.apply(Command::ToggleOccurrence {
            scheme,
            item,
            occurrence: occurrence.clone(),
        })?;
        // Retain it on the upcoming panel while it's completed, so checking it off
        // fades the row in place instead of dropping it until the next reload.
        inner.sync_retained_completed(scheme, item, occurrence);
        Ok(())
    }

    pub fn delete_item(&self, scheme_id: String, item_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteItem {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
            })
            .map_err(Into::into)
    }

    /// Transfer an item to a different scheme, preserving its identity and every
    /// attribute (text, dates, recurrence, completion, media). Mirrors the
    /// desktop event popup's scheme switch: delete from the source and re-insert
    /// the same item at the end of the target. A no-op when the two ids match.
    pub fn move_item_to_scheme(
        &self,
        source_scheme_id: String,
        target_scheme_id: String,
        item_id: String,
    ) -> Result<(), MobileError> {
        let source: SchemeId = parse_id(&source_scheme_id)?;
        let target: SchemeId = parse_id(&target_scheme_id)?;
        let item_id: ItemId = parse_id(&item_id)?;
        let mut inner = self.lock()?;
        if source == target {
            return Ok(());
        }
        if inner.workspace.is_scheme_read_only(source)
            || inner.workspace.is_scheme_read_only(target)
        {
            return Err(anyhow!("cannot move items to or from a read-only scheme").into());
        }
        let Some(item) = inner
            .workspace
            .scheme(source)
            .and_then(|scheme| scheme.item(item_id))
            .cloned()
        else {
            return Err(anyhow!("item not found in source scheme").into());
        };
        let position = inner
            .workspace
            .scheme(target)
            .map(|scheme| scheme.items.len())
            .ok_or_else(|| anyhow!("target scheme not found"))?;
        inner
            .apply(Command::Batch(vec![
                Command::DeleteItem {
                    scheme: source,
                    item: item_id,
                },
                Command::InsertItem {
                    scheme: target,
                    position,
                    item,
                },
            ]))
            .map_err(Into::into)
    }

    pub fn delete_event_occurrence(
        &self,
        scheme_id: String,
        item_id: String,
        occurrence_json: String,
        occurrence_index: i32,
        scope: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .delete_event_occurrence(
                parse_id(&scheme_id)?,
                parse_id(&item_id)?,
                parse_occurrence_json(&occurrence_json)?,
                position_from_i32(occurrence_index)?,
                parse_event_delete_scope(&scope)?,
            )
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

    pub fn set_notification_defaults(
        &self,
        event_offset_secs: i32,
        assignment_offset_secs: i32,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let defaults = NotificationDefaults {
            event_offset_secs: i64::from(event_offset_secs),
            assignment_offset_secs: i64::from(assignment_offset_secs),
        };
        if inner.settings.notification_defaults == defaults {
            return Ok(());
        }
        inner.settings.notification_defaults = defaults;
        inner.save_settings().map_err(Into::into)
    }

    pub fn reset_workspace(&self) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.workspace = make_default_workspace();
        inner.crdt =
            WorkspaceCrdtDocuments::empty_for_replica(&inner.workspace, inner.settings.replica_id);
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

    /// Hand the core a push token (e.g. an FCM registration token) so the next
    /// sync registers this device for silent background wake-ups. An empty token
    /// clears the registration. Channel is FCM; environment is "sandbox"/"production".
    pub fn set_push_registration(
        &self,
        token: String,
        environment: String,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let token = token.trim().to_string();
        if token.is_empty() {
            inner.push_token = None;
            inner.push_environment = None;
            return Ok(());
        }
        if inner.push_token.as_deref() != Some(token.as_str()) {
            // Token changed: force a re-register on the next sync.
            inner.registered_push_token = None;
        }
        inner.push_environment = Some(match environment.as_str() {
            "production" => PushEnvironment::Production,
            _ => PushEnvironment::Sandbox,
        });
        inner.push_token = Some(token);
        Ok(())
    }

    pub fn seed_editor_image_fixture(&self) -> Result<(), MobileError> {
        self.lock()?.seed_editor_image_fixture().map_err(Into::into)
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
}

/// Minimum spacing between remote syncs that have nothing local to push. Silent
/// pushes wake every device on each push, so two devices that each re-push on every
/// sync (e.g. a stale build whose normalization keeps re-canonicalizing the other's
/// workspace) form a feedback loop that hammers the backend. Coalescing
/// nothing-to-push syncs to this interval breaks that loop. Kept well under the
/// shells' poll interval (~30s) so the periodic pull is unaffected, and bypassed
/// whenever there are local edits queued so user changes never wait on it.
const MIN_REMOTE_SYNC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

impl MobileCoreInner {
    fn open(app_dir: PathBuf) -> Result<Self> {
        let workspace_dir = app_dir.join("workspace");
        let workspace_path = workspace_dir.join("workspace.json");
        let image_assets_dir = workspace_dir.join("assets/images");
        let settings_path = app_dir.join("settings.json");
        let mut should_reset_workspace_dir = false;
        let today = default_today();
        let load_options =
            WorkspaceLoadOptions::daily_queue_range(daily_queue_initial_start(today), today);
        let mut workspace = match load_workspace_with_options(&workspace_path, load_options) {
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
            // Preserve the unreadable workspace for recovery instead of
            // deleting it. If even the rename fails, keep going — the save
            // below overwrites workspace.json in place.
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|elapsed| elapsed.as_secs())
                .unwrap_or(0);
            let backup_dir = app_dir.join(format!("workspace-corrupt-{timestamp}"));
            if let Err(error) = fs::rename(&workspace_dir, &backup_dir) {
                eprintln!(
                    "knotq: could not set aside unreadable workspace ({error:#}); continuing in place"
                );
            }
        }
        // Best-effort: a transient write failure (e.g. disk pressure) must not
        // prevent startup. The loaded workspace lives in memory and every
        // subsequent edit retries the save.
        if let Err(error) = save_workspace(&workspace_path, &workspace) {
            eprintln!("knotq: deferring workspace save at startup: {error:#}");
        }
        if let Err(error) = save_app_settings(&settings_path, &settings) {
            eprintln!("knotq: deferring settings save at startup: {error:#}");
        }
        let next_sequence = load_local_sync_state(&workspace_path)
            .unwrap_or_default()
            .pending
            .iter()
            .map(|edit| edit.local_sequence)
            .max()
            .unwrap_or(0)
            + 1;
        // Restore the long-lived CRDT documents from disk with this replica's stable
        // deterministic clientID, so their Yjs identity survives restarts instead of
        // being rebuilt from plain data with a throwaway identity.
        let crdt_states = load_crdt_state(&workspace_path).unwrap_or_default();
        let crdt =
            WorkspaceCrdtDocuments::from_states(&workspace, settings.replica_id, &crdt_states)?;
        Ok(Self {
            workspace_path,
            settings_path,
            image_assets_dir,
            workspace,
            settings,
            crdt,
            next_sequence,
            sync_notice: None,
            push_token: None,
            push_environment: None,
            registered_push_token: None,
            retained_completed: RetainedCompletedItems::default(),
            last_remote_sync_at: None,
        })
    }

    /// Insert/remove a toggled occurrence from the retained-completed set based on
    /// its resulting done state — mirroring desktop's
    /// `sync_retained_completed_calendar_items`.
    fn sync_retained_completed(
        &mut self,
        scheme: SchemeId,
        item: ItemId,
        occurrence: OccurrenceId,
    ) {
        let is_done = self
            .workspace
            .scheme(scheme)
            .and_then(|scheme| scheme.item(item))
            .map(|item| item.state_for_occurrence(&occurrence).is_done())
            .unwrap_or(false);
        let key = CalendarOccurrenceKey {
            scheme_id: scheme,
            item_id: item,
            occurrence,
        };
        if is_done {
            self.retained_completed.insert(key);
        } else {
            self.retained_completed.remove(&key);
        }
    }

    fn apply(&mut self, command: Command) -> Result<()> {
        let crdt_changes = mobile_crdt_change_set_for_command(&command);
        self.workspace.apply(command)?;
        self.workspace.normalize_one_level_folders();
        self.workspace.normalize_item_markers();
        self.record_crdt_changes(crdt_changes)?;
        self.save_workspace()
    }

    /// Mark elapsed event occurrences complete in the background, mirroring the
    /// desktop's periodic sweep (`complete_past_event_occurrences`). Records CRDT
    /// changes for the touched schemes so the completion converges across
    /// devices, then persists. Returns the number of occurrences completed.
    fn complete_past_events(&mut self, now: DateTime<Utc>) -> Result<usize> {
        let keys = past_event_completion_keys(&self.workspace, now);
        if keys.is_empty() {
            return Ok(0);
        }
        let changed = mark_past_event_completion_keys_done(&mut self.workspace, &keys, now);
        if changed == 0 {
            return Ok(0);
        }
        let mut changeset = WorkspaceCrdtChangeSet::default();
        for key in &keys {
            changeset.schemes.insert(key.scheme_id);
        }
        self.record_crdt_changes(changeset)?;
        self.save_workspace()?;
        Ok(changed)
    }

    fn save_workspace(&self) -> Result<()> {
        save_workspace(&self.workspace_path, &self.workspace)?;
        // Persist the CRDT documents' state in lockstep with the workspace so a
        // restart restores them consistently (and with their stable identity).
        save_crdt_state(&self.workspace_path, &self.crdt.document_states())
    }

    fn load_daily_queue_scheme_if_needed(&mut self, date: NaiveDate) -> Result<Option<SchemeId>> {
        let Some(expected_id) = self.workspace.daily_queue_scheme_id(date) else {
            return Ok(None);
        };
        if self.workspace.schemes.contains_key(&expected_id) {
            return Ok(Some(expected_id));
        }

        match load_daily_queue_scheme(&self.workspace_path, date)? {
            Some(scheme) if scheme.id == expected_id => {
                self.workspace.schemes.insert(expected_id, scheme);
                Ok(Some(expected_id))
            }
            Some(scheme) => Err(anyhow!(
                "daily queue {} loaded with unexpected id {}, expected {}",
                date,
                scheme.id,
                expected_id
            )),
            None => {
                self.workspace.daily_queue.remove(&date);
                Ok(None)
            }
        }
    }

    fn load_daily_queue_date_range(&mut self, start: NaiveDate, end: NaiveDate) -> Result<()> {
        let first = start.min(end);
        let last = start.max(end);
        let dates = self
            .workspace
            .daily_queue
            .range(first..=last)
            .map(|(date, _)| *date)
            .collect::<Vec<_>>();
        let mut pruned_missing_entries = false;
        for date in dates {
            let had_entry = self.workspace.daily_queue_scheme_id(date).is_some();
            let loaded = self.load_daily_queue_scheme_if_needed(date)?;
            if had_entry && loaded.is_none() {
                pruned_missing_entries = true;
            }
        }
        if pruned_missing_entries {
            self.save_workspace()?;
        }
        Ok(())
    }

    fn load_daily_queue_calendar_range(&mut self, start: NaiveDate, end: NaiveDate) -> Result<()> {
        for (date, scheme) in
            load_daily_queue_schemes_for_calendar_range(&self.workspace_path, start, end)?
        {
            let Some(expected_id) = self.workspace.daily_queue_scheme_id(date) else {
                continue;
            };
            if scheme.id != expected_id {
                return Err(anyhow!(
                    "daily queue {} loaded with unexpected id {}, expected {}",
                    date,
                    scheme.id,
                    expected_id
                ));
            }
            self.workspace.schemes.entry(scheme.id).or_insert(scheme);
        }
        Ok(())
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

        let command = if action_id == ACTION_MARK_DONE {
            Command::ToggleOccurrence {
                scheme: scheme_id,
                item: item_id,
                occurrence,
            }
        } else if action_id == ACTION_SNOOZE_TOMORROW_MORNING {
            Command::SetOccurrenceNotificationOffset {
                scheme: scheme_id,
                item: item_id,
                occurrence,
                offset_secs: Some((trigger_at - notification_tomorrow_morning_utc()).num_seconds()),
            }
        } else if let Some((_, delay_secs)) = NOTIFICATION_SNOOZE_ACTIONS
            .iter()
            .find(|(candidate, _)| *candidate == action_id)
        {
            Command::SetOccurrenceNotificationOffset {
                scheme: scheme_id,
                item: item_id,
                occurrence,
                offset_secs: Some(
                    (trigger_at - (Utc::now() + Duration::seconds(*delay_secs))).num_seconds(),
                ),
            }
        } else {
            return Err(anyhow!("unknown notification action {action_id}"));
        };
        self.apply(command)?;
        Ok(true)
    }

    fn commit_event_edit(
        &mut self,
        scheme_id: SchemeId,
        item_id: ItemId,
        occurrence: OccurrenceId,
        occurrence_index: usize,
        title: String,
        occurrence_start: Option<DateTime<Utc>>,
        occurrence_end: Option<DateTime<Utc>>,
        draft_start: Option<DateTime<Utc>>,
        draft_end: Option<DateTime<Utc>>,
        draft_repeats: Option<Recurrence>,
        draft_notification_offset_secs: Option<i64>,
        notification_dirty: bool,
        draft_done: bool,
        scope: DateEditScope,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }
        let item = self
            .workspace
            .scheme(scheme_id)
            .and_then(|scheme| scheme.item(item_id))
            .cloned()
            .ok_or_else(|| anyhow!("item {item_id} missing in scheme {scheme_id}"))?;

        let mut commands = Vec::new();
        if item.text() != title {
            commands.push(Command::UpdateItemText {
                scheme: scheme_id,
                item: item_id,
                text: title,
            });
        }

        let occurrence_state = item.state_for_occurrence(&occurrence);
        let draft = EventPopupDraft {
            scheme_id,
            item_id,
            occurrence,
            occurrence_index,
            draft_start,
            draft_end,
            draft_repeats: draft_repeats.clone(),
            draft_notification_offset_secs,
            draft_done,
            start_dirty: occurrence_start != draft_start,
            end_dirty: occurrence_end != draft_end,
            repeats_dirty: item.repeats != draft_repeats,
            notification_dirty,
            done_dirty: occurrence_state.is_done() != draft_done,
        };
        commands.extend(event_popup_commit_commands(&item, &draft, scope));

        if let Some(command) = Command::from_vec(commands) {
            self.apply(command)?;
        }
        Ok(())
    }

    fn delete_event_occurrence(
        &mut self,
        scheme_id: SchemeId,
        item_id: ItemId,
        occurrence: OccurrenceId,
        occurrence_index: usize,
        scope: EventDeleteScope,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }
        let item = self
            .workspace
            .scheme(scheme_id)
            .and_then(|scheme| scheme.item(item_id))
            .cloned()
            .ok_or_else(|| anyhow!("item {item_id} missing in scheme {scheme_id}"))?;
        if let Some(command) = event_popup_delete_command(
            &item,
            scheme_id,
            item_id,
            occurrence,
            occurrence_index,
            scope,
        ) {
            self.apply(command)?;
        }
        Ok(())
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

    fn register_push_device(&mut self, client: &MobileSyncHttpClient) {
        let Some(token) = self.push_token.clone() else {
            return;
        };
        if self.registered_push_token.as_deref() == Some(token.as_str()) {
            return;
        }
        // The core is cross-compiled per platform, so the build target tells us
        // which shell we're running in — no need to thread the platform through
        // the FFI surface. (Host builds, e.g. cargo test, fall through to Ios.)
        let platform = if cfg!(target_os = "android") {
            DevicePlatform::Android
        } else {
            DevicePlatform::Ios
        };
        let request = RegisterDeviceRequest {
            replica_id: self.settings.replica_id,
            display_name: None,
            platform,
            app_version: None,
            push_channel: Some(PushChannel::Fcm),
            push_token: Some(token.clone()),
            push_environment: Some(self.push_environment.unwrap_or(PushEnvironment::Production)),
            notification_permission: NotificationPermissionState::default(),
            local_scheduler_supported: Some(true),
        };
        match client.register_device(&request) {
            Ok(_) => self.registered_push_token = Some(token),
            // Best effort: leave the marker unset so the next sync retries.
            Err(_) => {}
        }
    }

    /// Whether to coalesce (skip) a remote sync that was just triggered. We skip
    /// only when there is nothing local to push AND we synced within
    /// `MIN_REMOTE_SYNC_INTERVAL`, so wake-storms are throttled while user edits
    /// (non-empty pending queue) and the periodic poll (interval > the throttle)
    /// are never held back.
    fn should_coalesce_idle_sync(&self, has_local_pending: bool) -> bool {
        if has_local_pending {
            return false;
        }
        self.last_remote_sync_at
            .is_some_and(|last| last.elapsed() < MIN_REMOTE_SYNC_INTERVAL)
    }

    fn sync_once(&mut self, api_base: &str, bearer_token: &str) -> Result<bool> {
        // Coalesce wake-storms: a silent push wakes every device on each push, so two
        // devices that re-push on every sync form a feedback loop that barrages the
        // backend. Skip the round-trip when nothing local is queued and we synced
        // moments ago — see `should_coalesce_idle_sync`.
        let has_local_pending = load_local_sync_state(&self.workspace_path)
            .map(|state| !state.pending.is_empty())
            .unwrap_or(false);
        if self.should_coalesce_idle_sync(has_local_pending) {
            return Ok(false);
        }
        self.last_remote_sync_at = Some(std::time::Instant::now());

        let client = MobileSyncHttpClient {
            api_base: normalize_sync_api_base(api_base)?,
            bearer_token: bearer_token.to_string(),
        };
        // The account this bearer token belongs to owns the one canonical
        // personal-workspace document id; always adopt it. The previous shortcut
        // ("if sync.id == id we're already canonicalized, reuse it") only proved
        // the workspace was bound to *some* account — signing into a different one
        // (e.g. prod -> sandbox) left the old id in place and wedged every pull
        // with a document-id mismatch.
        let server_workspace_id = client.account_status()?.workspace_id;
        let local_workspace_changed = self
            .workspace
            .canonicalize_personal_sync_identity(server_workspace_id);
        self.workspace.ensure_sync_metadata();
        // Adopt that identity on the long-lived CRDT too. `self.crdt` was loaded
        // with the id this device last synced under; if it differs, re-label the
        // workspace document to the server's id *preserving its content*. The pull
        // below then merges the local and server workspace histories (union) over
        // the shared id instead of failing to apply or dropping local schemes. The
        // returned snapshot is queued for push (below) so the server — which keeps
        // its own base under this id — unions the local content in as well.
        let reidentified_workspace = self
            .crdt
            .reidentify_workspace_document(self.workspace.sync.id)?;

        let mut sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
        // One-time recovery: clear stale pull cursors so this sync re-pulls and
        // re-merges every document, repairing any workspace left diverged by the
        // earlier push-failure desync.
        sync_state.heal_for_recovery_version();
        // Signing into a different account/server than the persisted cursors were
        // built against must not reuse the previous account's pull/push cursors: a
        // stale cursor silently skips pulling the new account's lower document
        // sequences and makes the bootstrap push a bare delta the new server has no
        // base for (crdt_schema_invalid). Reset them so the next sync re-pulls from
        // zero and re-seeds full snapshots (idempotent in Yjs).
        sync_state.reset_for_account_change(self.workspace.id, &client.api_base);
        sync_state.workspace_id = Some(self.workspace.id);
        sync_state.replica_id = Some(self.settings.replica_id);
        sync_state.server_url = Some(client.api_base.clone());

        // If the workspace document was just re-identified to a new account's id,
        // queue its content for push. `queue_workspace_bootstrap_updates` only
        // force-snapshots documents the server has no base for, so a workspace the
        // server already holds (a prior account's seq > 0) would otherwise never
        // receive the local content. Pushing the relabeled document's full state is
        // an idempotent Yjs merge on the server, so it unions the local schemes in.
        if let Some(update) = reidentified_workspace {
            let operation_id = OperationId::new();
            let local_sequence = self.next_sequence;
            self.next_sequence += 1;
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

        // Register this device (with its push token, if any) so the backend can
        // wake it via silent push. Best effort — never block sync on it.
        self.register_push_device(&client);

        // One batched pull syncs the whole workspace: the server returns the current
        // merged state of every document past our cursor (and any document created
        // on another device). Applying merged state is idempotent in Yjs.
        let workspace = self.workspace.clone();
        let pull = batch_pull_and_apply(
            &client,
            &mut self.crdt,
            &mut sync_state,
            workspace,
            self.settings.replica_id,
        )?;
        // Log skipped documents (per-document errors that did not block the pull).
        for skipped in &pull.skipped {
            if !skipped.unknown_scheme_document {
                eprintln!(
                    "sync: skipped document {}: {}",
                    skipped.document, skipped.reason
                );
            }
        }
        let remote_updates_applied = pull.remote_updates_applied;
        self.workspace = pull.workspace;
        let mut repaired_workspace_changed = self
            .workspace
            .canonicalize_personal_sync_identity(server_workspace_id);
        repaired_workspace_changed |= self.workspace.normalize_one_level_folders();
        repaired_workspace_changed |= self.workspace.normalize_item_markers();
        if repaired_workspace_changed {
            let outcome = self.crdt.sync_changes(
                &self.workspace,
                &WorkspaceCrdtChangeSet::default().workspace(),
            );
            for error in &outcome.errors {
                // A repair-encoding error for one document must not wedge the entire
                // sync. Log it and queue whatever updates did encode; the pull
                // cursors below still persist, so the device keeps converging and
                // retries the repair next sync rather than failing every sync.
                eprintln!("mobile sync: CRDT repair update skipped: {error}");
            }
            if !outcome.updates.is_empty() {
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
            }
        }

        mobile_upload_local_media_assets(
            &client,
            &mut sync_state,
            &self.workspace,
            &self.image_assets_dir,
            &pull.remote_latest,
        )?;
        let mut media_downloaded =
            mobile_download_missing_media_assets(&client, &self.workspace, &self.image_assets_dir)?;

        // Persist the merged workspace BEFORE pushing. The durable pull cursors are
        // saved after the push regardless of its outcome, so the workspace must be
        // on disk first — otherwise a push failure would advance the cursor while
        // discarding the just-pulled remote schemes and archive (recently_deleted)
        // state, and the next sync (cursor already advanced) would never re-pull
        // them. That desync silently drops other devices' schemes and re-activates
        // archived ones. `self.crdt` is the long-lived document set that
        // `batch_pull_and_apply` merged remote state into in place — it is NOT
        // rebuilt (which would mint a throwaway identity); `save_workspace` persists
        // its merged state alongside the workspace.
        //
        // The server's per-document seq (our advanced pull cursor) tells the
        // bootstrap which documents the server already has a base for; the rest get a
        // full snapshot from the persistent CRDT (so the re-seed shares identity with
        // this device's diffs) queued before their deltas. The bootstrap also repairs
        // schema-less documents (a scheme added outside the command path) by
        // repopulating them from the workspace before snapshotting — run it before
        // the save so the healed state is persisted alongside the workspace.
        let healed_documents = queue_workspace_bootstrap_updates(
            &mut sync_state,
            &mut self.crdt,
            &self.workspace,
            self.settings.replica_id,
            &pull.remote_latest,
        );
        for document in &healed_documents {
            eprintln!("mobile sync: repopulated schema-less CRDT document {document}");
        }
        if remote_updates_applied > 0
            || local_workspace_changed
            || repaired_workspace_changed
            || !healed_documents.is_empty()
        {
            self.save_workspace()?;
        }
        let notification_schedule = mobile_notification_schedule_snapshot(
            &self.workspace,
            self.settings.notification_defaults,
            Utc::now(),
            0,
        )?;
        // Persist pull cursors, dropped orphans, and per-document push acks even
        // if the push below fails partway, so a transient push error never forces
        // the next sync to re-download every document from sequence zero. The merged
        // workspace above is already durable, so the cursor never runs ahead of it.
        let mut pushed = Vec::new();
        let push_result = batch_push_pending(
            &client,
            &mut sync_state,
            self.settings.replica_id,
            &notification_schedule,
            &mut pushed,
            &mut self.crdt,
            &self.workspace,
        );
        save_local_sync_state(&self.workspace_path, &sync_state)?;
        push_result?;

        // Retry media after the CRDT push using a head map that treats newly
        // pushed documents as present, so successful pre-push uploads are not
        // re-sent but skipped or changed local assets still get uploaded.
        let mut media_remote_latest = pull.remote_latest;
        for pushed_document in &pushed {
            media_remote_latest
                .entry(pushed_document.document)
                .or_insert(1);
        }
        mobile_upload_local_media_assets(
            &client,
            &mut sync_state,
            &self.workspace,
            &self.image_assets_dir,
            &media_remote_latest,
        )?;
        save_local_sync_state(&self.workspace_path, &sync_state)?;
        media_downloaded |=
            mobile_download_missing_media_assets(&client, &self.workspace, &self.image_assets_dir)?;

        Ok(remote_updates_applied > 0
            || repaired_workspace_changed
            || !pushed.is_empty()
            || media_downloaded)
    }

    fn ensure_daily_queue(&mut self, date: NaiveDate) -> Result<SchemeId> {
        if let Some(id) = self.load_daily_queue_scheme_if_needed(date)? {
            return Ok(id);
        }
        let id = daily_queue_scheme_id(date);
        let mut scheme = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
        scheme.id = id;
        scheme.items = Vec::new();
        self.workspace.daily_queue.insert(date, id);
        self.workspace.schemes.insert(id, scheme);
        self.workspace
            .scheme_sync
            .insert(id, daily_queue_sync_metadata(date));
        self.record_crdt_changes(
            WorkspaceCrdtChangeSet::default()
                .workspace()
                .touch_scheme(id),
        )?;
        Ok(id)
    }

    fn complete_google_calendar_import(
        &mut self,
        config: GoogleOAuthConfig,
        redirect_uri: String,
        state: String,
        code_verifier: String,
        callback_url: String,
        parent: FolderId,
    ) -> Result<MobileGoogleSyncResult> {
        let sources = google_calendar::google_calendar_sources(&self.workspace);
        let result = google_calendar::run_google_calendar_import_from_callback(
            config,
            &redirect_uri,
            &state,
            &code_verifier,
            &callback_url,
            sources,
        )?;
        self.finish_google_calendar_sync(result, true, parent)
    }

    fn sync_google_calendars(&mut self) -> Result<MobileGoogleSyncResult> {
        if self.settings.google_accounts.is_empty() {
            return Ok(MobileGoogleSyncResult {
                imported_count: 0,
                synced_count: 0,
                failure_count: 0,
                message: "No Google Calendar account is connected.".to_string(),
            });
        }
        let accounts = self.settings.google_accounts.clone();
        let sources = google_calendar::google_calendar_sources(&self.workspace);
        let result = google_calendar::run_google_calendar_background_sync(accounts, sources)?;
        self.finish_google_calendar_sync(result, false, self.workspace.root)
    }

    fn unlink_google_account(&mut self, account_id: &str) -> Result<()> {
        let old_len = self.settings.google_accounts.len();
        self.settings
            .google_accounts
            .retain(|account| account.account_id != account_id);
        if self.settings.google_accounts.len() != old_len {
            self.save_settings()?;
        }
        Ok(())
    }

    fn finish_google_calendar_sync(
        &mut self,
        result: GoogleCalendarImportResult,
        create_missing: bool,
        parent: FolderId,
    ) -> Result<MobileGoogleSyncResult> {
        let accounts_changed = self.upsert_google_accounts(result.accounts);
        let synced_count = result.calendars.len() as i32;
        let applied =
            self.apply_imported_google_calendars(result.calendars, create_missing, parent)?;

        if accounts_changed {
            self.save_settings()?;
        }
        if applied.content_changed {
            self.workspace.normalize_one_level_folders();
            self.workspace.normalize_item_markers();
            self.record_crdt_changes(applied.changes)?;
            self.save_workspace()?;
        }

        let failure_count = result.failures.len() as i32;
        let message = if result.failures.is_empty() {
            if synced_count == 0 {
                "Google Calendar is already up to date.".to_string()
            } else if applied.created_count > 0 {
                format!("Imported {} Google calendars.", applied.created_count)
            } else {
                format!("Synced {synced_count} Google calendars.")
            }
        } else {
            result.failures.join("\n")
        };

        Ok(MobileGoogleSyncResult {
            imported_count: applied.created_count,
            synced_count,
            failure_count,
            message,
        })
    }

    fn upsert_google_accounts(&mut self, accounts: Vec<knotq_model::GoogleOAuthAccount>) -> bool {
        let mut changed = false;
        for account in accounts {
            if let Some(existing) = self.settings.google_accounts.iter_mut().find(|existing| {
                existing.client_id == account.client_id && existing.account_id == account.account_id
            }) {
                if existing != &account {
                    *existing = account;
                    changed = true;
                }
            } else {
                self.settings.google_accounts.push(account);
                changed = true;
            }
        }
        changed
    }

    fn google_accounts(&self) -> Vec<MobileGoogleAccount> {
        self.settings
            .google_accounts
            .iter()
            .map(|account| {
                let title = account
                    .email
                    .clone()
                    .filter(|email| !email.trim().is_empty())
                    .unwrap_or_else(|| account.account_id.clone());
                let count = self.google_calendar_scheme_count_for_account(account);
                let detail = match count {
                    1 => "1 calendar".to_string(),
                    count => format!("{count} calendars"),
                };
                MobileGoogleAccount {
                    id: account.account_id.clone(),
                    title,
                    detail,
                }
            })
            .collect()
    }

    fn google_calendar_scheme_count_for_account(&self, account: &GoogleOAuthAccount) -> usize {
        self.workspace
            .schemes
            .values()
            .filter(|scheme| {
                let SchemeSource::ImportedCalendar(source) = &scheme.source else {
                    return false;
                };
                source.provider == CalendarProvider::Google
                    && google_account_matches_calendar_source(account, source)
            })
            .count()
    }

    fn apply_imported_google_calendars(
        &mut self,
        calendars: Vec<google_calendar::ImportedGoogleCalendar>,
        create_missing: bool,
        parent: FolderId,
    ) -> Result<GoogleCalendarApplyResult> {
        let parent = if self.workspace.folder(parent).is_some() {
            parent
        } else {
            self.workspace.root
        };
        let mut changes = WorkspaceCrdtChangeSet::default();
        let mut content_changed = false;
        let mut created_count = 0;
        let mut insert_position = 0usize;

        for calendar in calendars {
            let existing_scheme_ids = google_calendar::google_calendar_scheme_ids(
                &self.workspace,
                &calendar.account_id,
                &calendar.calendar_id,
            );
            let existing_scheme_id = existing_scheme_ids.first().copied();
            if self.delete_duplicate_google_calendar_schemes(
                existing_scheme_ids.get(1..).unwrap_or(&[]),
                &mut changes,
            ) {
                content_changed = true;
            }
            let scheme_id = match existing_scheme_id {
                Some(scheme_id) => scheme_id,
                None if create_missing => {
                    let mut scheme = Scheme::new(calendar.name.clone(), calendar.color_index);
                    let id = scheme.id;
                    scheme.source = google_calendar::google_calendar_source(&calendar);
                    self.workspace.schemes.insert(id, scheme);
                    self.workspace
                        .folders
                        .get_mut(&parent)
                        .ok_or_else(|| anyhow!("target folder is missing"))?
                        .children
                        .insert(insert_position, NodeRef::Scheme(id));
                    insert_position += 1;
                    changes.workspace = true;
                    changes.schemes.insert(id);
                    content_changed = true;
                    created_count += 1;
                    id
                }
                None => continue,
            };

            let Some(scheme) = self.workspace.schemes.get_mut(&scheme_id) else {
                continue;
            };
            let should_update_name = existing_scheme_id.is_none();
            let metadata_changed = google_calendar::apply_google_calendar_metadata(
                scheme,
                &calendar,
                should_update_name,
            );
            let items_changed = google_calendar::apply_google_calendar_items(scheme, &calendar);
            if metadata_changed {
                changes.workspace = true;
            }
            if items_changed {
                changes.schemes.insert(scheme_id);
            }
            if metadata_changed || items_changed {
                content_changed = true;
            }
        }

        Ok(GoogleCalendarApplyResult {
            content_changed,
            created_count,
            changes,
        })
    }

    fn delete_duplicate_google_calendar_schemes(
        &mut self,
        scheme_ids: &[SchemeId],
        changes: &mut WorkspaceCrdtChangeSet,
    ) -> bool {
        let mut changed = false;
        for scheme_id in scheme_ids.iter().copied() {
            if self.workspace.is_scheme_deleted(scheme_id)
                || !self.workspace.schemes.contains_key(&scheme_id)
            {
                continue;
            }

            let mut origin = None;
            for (folder_id, folder) in self.workspace.folders.iter_mut() {
                let mut index = 0usize;
                while index < folder.children.len() {
                    if folder.children[index] == NodeRef::Scheme(scheme_id) {
                        if origin.is_none() {
                            origin = Some((*folder_id, index));
                        }
                        folder.children.remove(index);
                    } else {
                        index += 1;
                    }
                }
            }

            if let Some((folder_id, position)) = origin {
                self.workspace
                    .mark_scheme_deleted_from(scheme_id, folder_id, position);
            } else {
                self.workspace.mark_scheme_deleted(scheme_id);
            }
            changes.workspace = true;
            changes.schemes.insert(scheme_id);
            changed = true;
        }
        changed
    }

    fn snapshot(
        &mut self,
        today: NaiveDate,
        week_offset: i32,
        daily_history_days: i64,
    ) -> Result<MobileSnapshot> {
        // Mark elapsed event occurrences complete before reading, mirroring the
        // desktop's background sweep. Uses the real current instant (not `today`)
        // and is best-effort: a transient save failure must not block rendering.
        if let Err(error) = self.complete_past_events(Utc::now()) {
            eprintln!("knotq: deferring past-event completion: {error:#}");
        }
        let daily_start = today - Duration::days(daily_history_days);
        let daily_end = today + Duration::days(MOBILE_DAILY_LOOKAHEAD_DAYS);
        self.load_daily_queue_date_range(daily_start, daily_end)?;
        let previous_daily_date =
            if daily_history_days > i64::from(MOBILE_DAILY_DEFAULT_HISTORY_DAYS) {
                self.workspace
                    .daily_queue
                    .range(..daily_start)
                    .next_back()
                    .map(|(date, _)| *date)
            } else {
                None
            };
        if let Some(date) = previous_daily_date {
            self.load_daily_queue_scheme_if_needed(date)?;
        }

        let week_start = today + Duration::days((week_offset as i64) * 7);
        let week_end = week_start + Duration::days(7);
        let query_start = week_start - Duration::days(1);
        self.load_daily_queue_calendar_range(query_start, week_end)?;

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
        let archived_nodes = self.archived_nodes()?;

        let daily_days = daily_end.signed_duration_since(daily_start).num_days() + 1;
        let daily = previous_daily_date
            .into_iter()
            .chain((0..daily_days).map(|offset| daily_start + Duration::days(offset)))
            .filter_map(|date| {
                self.workspace
                    .daily_queue_scheme_id(date)
                    .and_then(|id| self.workspace.scheme(id))
                    .map(|scheme| MobileDailyEntry {
                        date: date.to_string(),
                        scheme: self.mobile_scheme(scheme),
                    })
            })
            .collect();

        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: local_midnight_utc(query_start)?,
            end: local_midnight_utc(week_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();
        let days = (-1..7)
            .map(|offset| {
                let date = week_start + Duration::days(offset as i64);
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
        let upcoming = mobile_upcoming(&indexed, Utc::now(), UPCOMING_LIMIT)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        let retained = &self.retained_completed;
        let overdue = indexed
            .calendar_query()
            .overdue_retaining(Utc::now(), |event| {
                retained.contains(&CalendarOccurrenceKey {
                    scheme_id: event.scheme_id,
                    item_id: event.item_id,
                    occurrence: event.occurrence.id.clone(),
                })
            })
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        Ok(MobileSnapshot {
            root,
            schemes,
            archived_schemes,
            archived_nodes,
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
                event_notification_offset_secs: offset_to_i32(
                    self.settings.notification_defaults.event_offset_secs,
                ),
                assignment_notification_offset_secs: offset_to_i32(
                    self.settings.notification_defaults.assignment_offset_secs,
                ),
                google_account_count: self.settings.google_accounts.len() as i32,
                google_accounts: self.google_accounts(),
            },
            workspace_path: self.workspace_path.display().to_string(),
        })
    }

    fn month_days(&mut self, year: i32, month: u32) -> Result<Vec<MobileCalendarDay>> {
        let first = NaiveDate::from_ymd_opt(year, month, 1)
            .ok_or_else(|| anyhow!("invalid month {month}/{year}"))?;
        let next_month_first = if month >= 12 {
            NaiveDate::from_ymd_opt(year + 1, 1, 1)
        } else {
            NaiveDate::from_ymd_opt(year, month + 1, 1)
        }
        .ok_or_else(|| anyhow!("invalid month {month}/{year}"))?;
        // Pad the range so the leading/trailing spillover cells the grid shows
        // for the adjacent months still carry their event dots.
        let grid_start = first - Duration::days(7);
        let grid_end = next_month_first + Duration::days(7);
        self.load_daily_queue_date_range(grid_start, grid_end)?;
        self.load_daily_queue_calendar_range(grid_start, grid_end)?;

        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: local_midnight_utc(grid_start)?,
            end: local_midnight_utc(grid_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();

        let total_days = (grid_end - grid_start).num_days();
        let days = (0..total_days)
            .map(|offset| {
                let date = grid_start + Duration::days(offset);
                let date_string = date.to_string();
                MobileCalendarDay {
                    occurrences: occurrences
                        .iter()
                        .filter(|occurrence| occurrence.local_date.as_deref() == Some(&date_string))
                        .cloned()
                        .collect(),
                    date: date_string,
                }
            })
            .collect();
        Ok(days)
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
            is_read_only: false,
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
                    is_read_only: scheme.is_read_only(),
                    children: Vec::new(),
                }))
            }
        }
    }

    /// The archive as a tree mirroring the desktop trash view: each top-level
    /// archived folder keeps its subtree (nested folders + schemes), followed by
    /// archived schemes that aren't inside an archived folder.
    fn archived_nodes(&self) -> Result<Vec<MobileNode>> {
        let mut nodes = Vec::new();
        let archived_folders = self
            .workspace
            .iter_deleted_folders()
            .map(|folder| folder.id)
            .collect::<Vec<_>>();
        for folder_id in archived_folders {
            nodes.push(self.archived_folder_node(folder_id)?);
        }
        let archived_schemes = self
            .workspace
            .iter_deleted_schemes()
            .filter(|scheme| {
                !self
                    .workspace
                    .is_scheme_in_deleted_folder_subtree(scheme.id)
            })
            .map(|scheme| scheme.id)
            .collect::<Vec<_>>();
        for scheme_id in archived_schemes {
            if let Some(scheme) = self.workspace.scheme(scheme_id) {
                nodes.push(archived_scheme_node(scheme));
            }
        }
        Ok(nodes)
    }

    fn archived_folder_node(&self, id: FolderId) -> Result<MobileNode> {
        let folder = self
            .workspace
            .folder(id)
            .ok_or_else(|| anyhow!("archived folder {id} is missing"))?;
        Ok(MobileNode {
            kind: "folder".to_string(),
            id: id.to_string(),
            name: folder.name.clone(),
            color_index: None,
            is_daily_queue: false,
            is_read_only: false,
            children: folder
                .children
                .iter()
                .filter_map(|child| self.archived_child_node(child).transpose())
                .collect::<Result<Vec<_>>>()?,
        })
    }

    fn archived_child_node(&self, child: &NodeRef) -> Result<Option<MobileNode>> {
        match child {
            NodeRef::Folder(id) => self.archived_folder_node(*id).map(Some),
            NodeRef::Scheme(id) => Ok(self.workspace.scheme(*id).map(archived_scheme_node)),
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
            is_read_only: scheme.is_read_only(),
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
        // A nested scheme has no live origin folder, so this lands it at the root;
        // `RestoreScheme` detaches it from the archived folder's subtree, leaving
        // the archive entirely.
        let (folder, position) = self.deleted_scheme_restore_target(scheme_id);
        self.apply(Command::RestoreScheme {
            folder,
            position,
            scheme,
        })
    }

    fn restore_deleted_folder(&mut self, folder_id: FolderId) -> Result<()> {
        let is_archived_root = self.workspace.is_folder_deleted(folder_id);
        // A folder nested under an archived folder isn't itself flagged deleted;
        // it still needs lifting out so it (and its schemes) leave the archive.
        let is_nested = !is_archived_root
            && self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder_id));
        if !is_archived_root && !is_nested {
            return Ok(());
        }
        let Some(folder) = self.workspace.folder(folder_id).cloned() else {
            if is_archived_root {
                self.workspace.remove_folder_from_archive(folder_id);
                self.record_crdt_changes(WorkspaceCrdtChangeSet::default().workspace())?;
                return self.save_workspace();
            }
            return Ok(());
        };
        // Top-level archived folders restore to their origin (or root); nested
        // ones lift to the root. `RestoreFolder` detaches the folder and clears
        // the deleted flag across its whole subtree.
        let (parent, position) = if is_archived_root {
            self.deleted_folder_restore_target(folder_id)
        } else {
            let root = self.workspace.root;
            let position = self
                .workspace
                .folder(root)
                .map(|folder| folder.children.len())
                .unwrap_or(0);
            (root, position)
        };
        self.apply(Command::RestoreFolder {
            parent,
            position,
            folder,
        })
    }

    fn deleted_folder_restore_target(&self, folder_id: FolderId) -> (FolderId, usize) {
        if let Some(origin) = self.workspace.deleted_folder_origin(folder_id) {
            if self.is_valid_folder_restore_parent(origin.parent) {
                let len = self
                    .workspace
                    .folder(origin.parent)
                    .map(|folder| folder.children.len())
                    .unwrap_or(0);
                return (origin.parent, origin.position.min(len));
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

    fn is_valid_folder_restore_parent(&self, folder_id: FolderId) -> bool {
        self.workspace.folder(folder_id).is_some()
            && !self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder_id))
    }

    fn empty_archive(&mut self) -> Result<()> {
        // Archived folders first — each takes its whole subtree (nested folders
        // and schemes) with it — then any standalone archived schemes that remain.
        let deleted_folders = self.workspace.recently_deleted_folders.clone();
        for id in deleted_folders {
            self.apply(Command::PermanentlyDeleteFolder { id })?;
        }
        let deleted = self.workspace.recently_deleted.clone();
        for id in deleted {
            if self.workspace.is_scheme_deleted(id) {
                self.apply(Command::PermanentlyDeleteScheme { id })?;
            }
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
            && !self.workspace.is_folder_deleted(folder)
            && !self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder))
    }

    fn insert_table(
        &mut self,
        scheme_id: SchemeId,
        after_item_id: Option<ItemId>,
        item_id: ItemId,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let position = {
            let scheme = self
                .workspace
                .scheme(scheme_id)
                .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?;
            after_item_id
                .and_then(|item_id| scheme.item_index(item_id).map(|index| index + 1))
                .unwrap_or(scheme.items.len())
        };

        // Use the caller-supplied id so the editor's optimistically-rendered
        // table and the persisted item share identity from the first frame.
        let mut item = Item::new("");
        item.id = item_id;
        item.set_table(Table::new(2, 2));
        self.apply(Command::InsertItem {
            scheme: scheme_id,
            position,
            item,
        })
    }

    fn mutate_table(
        &mut self,
        scheme_id: SchemeId,
        item_id: ItemId,
        mutate: impl FnOnce(&mut Table) -> Result<()>,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let mut item = self
            .workspace
            .scheme(scheme_id)
            .and_then(|scheme| scheme.items.iter().find(|item| item.id == item_id))
            .cloned()
            .ok_or_else(|| anyhow!("item {item_id} is missing in scheme {scheme_id}"))?;
        let table = item
            .table_mut()
            .ok_or_else(|| anyhow!("item {item_id} does not contain a table"))?;
        mutate(table)?;
        table.normalize();
        self.apply(Command::ReplaceItem {
            scheme: scheme_id,
            item,
        })
    }

    fn seed_editor_image_fixture(&mut self) -> Result<()> {
        if self.workspace.iter_schemes().any(|scheme| {
            scheme
                .items
                .iter()
                .any(|item| item.text() == EDITOR_IMAGE_FIXTURE_TEXT)
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

        // Single-content: the caption and the image are two separate lines.
        let caption = Item::new(EDITOR_IMAGE_FIXTURE_TEXT);
        let mut image_item = Item::new("");
        image_item.set_image(ImageInline {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(320),
            height: Some(180),
        });

        let scheme = self
            .workspace
            .scheme_mut(target_id)
            .ok_or_else(|| anyhow!("scheme {target_id} is missing"))?;
        scheme.items.push(caption);
        scheme.items.push(image_item);
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
            let existing_item = existing_id.and_then(|id| {
                if used_ids.contains(&id) {
                    return None;
                }
                existing.iter().find(|item| item.id == id).cloned()
            });
            let has_rich_metadata = draft.start.is_some()
                || draft.end.is_some()
                || draft.notification_offset_secs.is_some()
                || draft
                    .repeat_rule
                    .as_deref()
                    .is_some_and(|rule| !rule.trim().is_empty())
                || !draft.media.is_empty();
            let should_apply_rich_metadata = existing_item.is_none() || has_rich_metadata;
            let mut item = existing_item.unwrap_or_else(|| Item::new(""));

            used_ids.push(item.id);
            // A line is single-content. A bulk save sends empty `content`/`media`
            // for an existing image/table line (its block lives only in
            // `content`, which the editor may omit), so preserve the block rather
            // than let `set_text` clobber it. When content/media *are* supplied,
            // or the line was text, the incoming text/content wins.
            let preserve_existing_block =
                item.content.is_block() && draft.content.is_empty() && draft.media.is_empty();
            if !preserve_existing_block {
                item.set_text(draft.text);
            }
            item.marker = parse_marker(Some(&draft.marker))?;
            item.indent = as_u8(draft.indent, "indent")?.min(8);
            if should_apply_rich_metadata {
                item.start = parse_datetime_opt(draft.start.as_deref())?;
                item.end = parse_datetime_opt(draft.end.as_deref())?;
                item.repeats = recurrence_from_rrule(draft.repeat_rule);
                // Legacy text+media path: rebuild the inline run, swapping the
                // attached images, then collapse back to single-content (a block
                // wins, so a line with media becomes an image line).
                let mut inlines = item.content.to_inlines();
                inlines.retain(|inline| !matches!(inline, Inline::Image(_)));
                inlines.extend(
                    draft
                        .media
                        .iter()
                        .filter_map(|media| {
                            mobile_media_to_item_media(media, &self.image_assets_dir)
                        })
                        .map(Inline::Image),
                );
                item.content = ItemContent::from_inlines(inlines);
            }
            item.enforce_marker_constraints();
            if !draft.content.is_empty() {
                item.content = ItemContent::from_inlines(mobile_inlines_to_inlines(
                    &draft.content,
                    &self.image_assets_dir,
                )?);
            }
            if item.marker == ItemMarker::Checkbox {
                let state = item.state_for_occurrence_mut(OccurrenceId::Single);
                state.progress = if draft.done { -1 } else { 0 };
                if should_apply_rich_metadata {
                    state.notification_offset_secs = draft.notification_offset_secs.map(i64::from);
                }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversions::format_datetime;
    use chrono::{Local, TimeZone};
    use knotq_model::{
        CalendarProvider, ImportedCalendarSource, ReplicaId, SchemeSource, SyncDocumentKind,
    };
    use knotq_sync::LocalSyncState;

    #[test]
    fn bootstrap_snapshot_supersedes_pending_delta_for_new_remote_document() {
        let mut workspace = Workspace::new();
        let scheme = Scheme::new("Unsynced", 0);
        let scheme_id = scheme.id;
        workspace.schemes.insert(scheme_id, scheme);
        workspace.ensure_sync_metadata();
        let document = workspace.scheme_sync.get(&scheme_id).unwrap().id;
        let replica_id = ReplicaId::new();
        let stale_delta = vec![1, 2, 3];
        let mut sync_state = LocalSyncState {
            workspace_id: Some(workspace.id),
            replica_id: Some(replica_id),
            ..LocalSyncState::default()
        };
        sync_state.document_cursors.insert(
            document,
            knotq_sync::DocumentSyncCursor {
                document,
                kind: SyncDocumentKind::Scheme,
                last_pulled_sequence: 0,
                last_pushed_sequence: 12,
            },
        );
        sync_state.push_pending(PendingCrdtEdit {
            operation_id: OperationId::new(),
            workspace_id: workspace.id,
            replica_id,
            local_sequence: 1,
            created_at: Utc::now(),
            document,
            kind: SyncDocumentKind::Scheme,
            update_v1: stale_delta.clone(),
        });

        queue_workspace_bootstrap_updates(
            &mut sync_state,
            &mut WorkspaceCrdtDocuments::try_new(&workspace).unwrap(),
            &workspace,
            replica_id,
            &std::collections::HashMap::new(),
        );

        let pending = sync_state
            .pending
            .iter()
            .filter(|edit| edit.document == document)
            .collect::<Vec<_>>();
        assert_eq!(pending.len(), 1);
        assert_ne!(pending[0].update_v1, stale_delta);
        knotq_sync::validate_crdt_update_sequence(
            SyncDocumentKind::Scheme,
            [pending[0].update_v1.as_slice()],
        )
        .unwrap();
    }

    #[test]
    fn bootstrap_drops_orphaned_pending_delta_without_remote_base() {
        // A delta queued for a scheme that has since been deleted (so it is no
        // longer in the workspace) and that the server has no base snapshot for can
        // never be accepted — pushing it trips `crdt_schema_invalid` and wedges the
        // whole push loop. Bootstrap must drop it so sync can make progress.
        let mut workspace = Workspace::new();
        workspace.ensure_sync_metadata();
        let replica_id = ReplicaId::new();
        let orphan_document = knotq_model::DocumentId::new();
        let mut sync_state = LocalSyncState {
            workspace_id: Some(workspace.id),
            replica_id: Some(replica_id),
            ..LocalSyncState::default()
        };
        sync_state.push_pending(PendingCrdtEdit {
            operation_id: OperationId::new(),
            workspace_id: workspace.id,
            replica_id,
            local_sequence: 1,
            created_at: Utc::now(),
            document: orphan_document,
            kind: SyncDocumentKind::Scheme,
            update_v1: vec![9, 9, 9],
        });

        queue_workspace_bootstrap_updates(
            &mut sync_state,
            &mut WorkspaceCrdtDocuments::try_new(&workspace).unwrap(),
            &workspace,
            replica_id,
            &std::collections::HashMap::new(),
        );

        assert!(
            !sync_state
                .pending
                .iter()
                .any(|edit| edit.document == orphan_document),
            "orphaned pending delta should be dropped"
        );
    }

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
    fn archive_keeps_folder_hierarchy_and_restores_and_purges() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_folder(None, "Projects".to_string(), None)
            .expect("create folder");
        let snapshot = core.snapshot(None, 0).expect("snapshot");
        let folder = snapshot
            .root
            .children
            .iter()
            .find(|node| node.kind == "folder" && node.name == "Projects")
            .expect("folder in tree");
        let folder_id = folder.id.clone();

        core.create_scheme(Some(folder_id.clone()), "Nested".to_string(), Some(1), None)
            .expect("create nested scheme");

        // Archive the folder as one unit.
        core.delete_folder(folder_id.clone())
            .expect("archive folder");
        let snapshot = core.snapshot(None, 0).expect("snapshot after archive");
        assert!(
            !snapshot
                .root
                .children
                .iter()
                .any(|node| node.id == folder_id),
            "archived folder should leave the sidebar tree"
        );
        let archived_folder = snapshot
            .archived_nodes
            .iter()
            .find(|node| node.id == folder_id)
            .expect("folder appears in archived tree");
        assert_eq!(archived_folder.kind, "folder");
        assert!(
            archived_folder
                .children
                .iter()
                .any(|child| child.kind == "scheme" && child.name == "Nested"),
            "archived folder keeps its nested scheme"
        );

        // Restore brings the whole subtree back to the sidebar.
        core.restore_folder(folder_id.clone())
            .expect("restore folder");
        let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
        assert!(
            snapshot
                .root
                .children
                .iter()
                .any(|node| node.id == folder_id),
            "restored folder returns to the sidebar tree"
        );
        assert!(snapshot.archived_nodes.is_empty());

        // Re-archive then purge permanently.
        core.delete_folder(folder_id.clone())
            .expect("re-archive folder");
        core.permanently_delete_folder(folder_id.clone())
            .expect("purge folder");
        let snapshot = core.snapshot(None, 0).expect("snapshot after purge");
        assert!(snapshot.archived_nodes.is_empty());
        assert!(
            !snapshot
                .schemes
                .iter()
                .any(|scheme| scheme.name == "Nested"),
            "purged folder's schemes are gone"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn restoring_a_nested_scheme_lifts_it_to_root_and_out_of_archive() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_folder(None, "Parent".to_string(), None)
            .expect("create folder");
        let snapshot = core.snapshot(None, 0).expect("snapshot");
        let folder_id = snapshot
            .root
            .children
            .iter()
            .find(|node| node.kind == "folder" && node.name == "Parent")
            .expect("folder")
            .id
            .clone();
        core.create_scheme(Some(folder_id.clone()), "Child".to_string(), Some(1), None)
            .expect("create nested scheme");
        let snapshot = core.snapshot(None, 0).expect("snapshot");
        let scheme_id = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.name == "Child")
            .expect("nested scheme")
            .id
            .clone();

        // Archive the whole folder, then restore only the nested scheme.
        core.delete_folder(folder_id.clone())
            .expect("archive folder");
        core.restore_scheme(scheme_id.clone())
            .expect("restore nested scheme");

        let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
        // The scheme is back at the root, no longer under the archived folder.
        assert!(
            snapshot
                .root
                .children
                .iter()
                .any(|node| node.id == scheme_id),
            "restored scheme sits at the root"
        );
        let archived_folder = snapshot
            .archived_nodes
            .iter()
            .find(|node| node.id == folder_id)
            .expect("folder still archived");
        assert!(
            !contains_node(archived_folder, &scheme_id),
            "restored scheme is gone from the archived subtree"
        );
        assert!(
            !snapshot
                .archived_schemes
                .iter()
                .any(|scheme| scheme.id == scheme_id),
            "restored scheme is gone from the archive"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn restoring_a_nested_folder_lifts_its_subtree_to_root() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_folder(None, "Outer".to_string(), None)
            .expect("create outer");
        let outer_id = core
            .snapshot(None, 0)
            .unwrap()
            .root
            .children
            .iter()
            .find(|node| node.name == "Outer")
            .unwrap()
            .id
            .clone();
        core.create_folder(Some(outer_id.clone()), "Inner".to_string(), None)
            .expect("create inner");
        let inner_id = core
            .snapshot(None, 0)
            .unwrap()
            .root
            .children
            .iter()
            .find(|node| node.id == outer_id)
            .unwrap()
            .children
            .iter()
            .find(|node| node.name == "Inner")
            .unwrap()
            .id
            .clone();
        core.create_scheme(Some(inner_id.clone()), "Deep".to_string(), Some(1), None)
            .expect("create deep scheme");

        core.delete_folder(outer_id.clone()).expect("archive outer");
        core.restore_folder(inner_id.clone())
            .expect("restore nested folder");

        let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
        assert!(
            snapshot
                .root
                .children
                .iter()
                .any(|node| node.id == inner_id),
            "restored inner folder sits at the root"
        );
        assert!(
            snapshot.schemes.iter().any(|scheme| scheme.name == "Deep"),
            "the inner folder's scheme is no longer archived"
        );
        let archived_outer = snapshot
            .archived_nodes
            .iter()
            .find(|node| node.id == outer_id)
            .expect("outer still archived");
        assert!(
            !contains_node(archived_outer, &inner_id),
            "restored inner folder left the archived subtree"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    fn contains_node(node: &MobileNode, id: &str) -> bool {
        node.id == id || node.children.iter().any(|child| contains_node(child, id))
    }

    #[test]
    fn completing_an_overdue_assignment_keeps_it_on_the_upcoming_panel() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Work".to_string(), Some(1), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(None, 0)
            .unwrap()
            .schemes
            .iter()
            .find(|scheme| scheme.name == "Work")
            .unwrap()
            .id
            .clone();
        core.add_calendar_item(
            Some(scheme_id),
            None,
            "Old essay".to_string(),
            "assignment".to_string(),
            None,
            Some("2020-01-01T10:00:00Z".to_string()),
        )
        .expect("add overdue assignment");

        let overdue = core.snapshot(None, 0).unwrap().calendar.overdue;
        let occ = overdue
            .iter()
            .find(|occ| occ.title == "Old essay")
            .expect("overdue assignment present");
        assert!(!occ.done);

        // Completing it keeps it on the panel (marked done), not dropped.
        core.toggle_occurrence(
            occ.scheme_id.clone(),
            occ.item_id.clone(),
            occ.occurrence_json.clone(),
        )
        .expect("complete");
        let overdue = core.snapshot(None, 0).unwrap().calendar.overdue;
        let occ = overdue
            .iter()
            .find(|occ| occ.title == "Old essay")
            .expect("retained after completion");
        assert!(occ.done, "the completed assignment stays, faded");

        // Un-completing removes the retention but it's still overdue, so it stays.
        core.toggle_occurrence(
            occ.scheme_id.clone(),
            occ.item_id.clone(),
            occ.occurrence_json.clone(),
        )
        .expect("un-complete");
        let overdue = core.snapshot(None, 0).unwrap().calendar.overdue;
        let occ = overdue
            .iter()
            .find(|occ| occ.title == "Old essay")
            .expect("still present");
        assert!(!occ.done);

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn daily_queue_loads_old_entries_on_demand() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let workspace_path = dir.join("workspace").join("workspace.json");
        let old_date = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
        let current_date = NaiveDate::from_ymd_opt(2026, 5, 26).unwrap();
        let old_id = daily_queue_scheme_id(old_date);
        let mut workspace = Workspace::new();
        let mut old_daily = Scheme::new(daily_queue_scheme_name(old_date), DAILY_QUEUE_COLOR_INDEX);
        old_daily.id = old_id;
        old_daily.items.push(Item::new("archived daily note"));
        workspace.daily_queue.insert(old_date, old_id);
        workspace.schemes.insert(old_id, old_daily);
        save_workspace(&workspace_path, &workspace).expect("seed workspace");

        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let current = core
            .snapshot(Some(current_date.to_string()), 0)
            .expect("current snapshot");
        assert!(!current
            .daily
            .iter()
            .any(|entry| entry.date == old_date.to_string()));

        let old = core
            .snapshot_with_daily_history(Some(current_date.to_string()), 0, 31)
            .expect("old snapshot");
        let loaded = old
            .daily
            .iter()
            .find(|entry| entry.date == old_date.to_string())
            .expect("old daily loaded");
        assert_eq!(loaded.scheme.items[0].text, "archived daily note");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn new_daily_queue_is_empty() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let date = NaiveDate::from_ymd_opt(2026, 5, 26).unwrap();

        core.ensure_daily_queue(Some(date.to_string()))
            .expect("ensure daily");

        let snapshot = core
            .snapshot(Some(date.to_string()), 0)
            .expect("snapshot after ensure");
        let daily = snapshot
            .daily
            .iter()
            .find(|entry| entry.date == date.to_string())
            .expect("daily exists");
        assert!(daily.scheme.items.is_empty());

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn idle_remote_syncs_are_coalesced_but_pending_edits_bypass_the_throttle() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let mut inner = MobileCoreInner::open(dir.clone()).expect("open mobile core");

        // Never synced yet -> a sync must always run (no throttle on the first one).
        assert!(!inner.should_coalesce_idle_sync(false));

        // Just synced with nothing queued -> a fresh wake-up is coalesced. This is
        // what stops the silent-push feedback loop from barraging the backend.
        inner.last_remote_sync_at = Some(std::time::Instant::now());
        assert!(inner.should_coalesce_idle_sync(false));

        // Just synced but local edits are queued -> never coalesce, so user changes
        // are pushed promptly rather than waiting out the throttle window.
        assert!(!inner.should_coalesce_idle_sync(true));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn google_calendar_sync_deletes_duplicate_imported_schemes_after_first() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let mut inner = MobileCoreInner::open(dir.clone()).expect("open mobile core");
        inner.workspace = Workspace::new();
        let root = inner.workspace.root;

        let first = imported_google_scheme("First", "account", "calendar");
        let first_id = first.id;
        let duplicate = imported_google_scheme("Duplicate", "account", "calendar");
        let duplicate_id = duplicate.id;
        inner.workspace.schemes.insert(first_id, first);
        inner.workspace.schemes.insert(duplicate_id, duplicate);
        inner
            .workspace
            .folders
            .get_mut(&root)
            .unwrap()
            .children
            .extend([NodeRef::Scheme(first_id), NodeRef::Scheme(duplicate_id)]);

        let result = inner
            .apply_imported_google_calendars(
                vec![google_calendar::ImportedGoogleCalendar {
                    account_id: "account".to_string(),
                    account_email: Some("user@example.com".to_string()),
                    calendar_id: "calendar".to_string(),
                    name: "Calendar".to_string(),
                    color_index: 3,
                    sync_token: Some("token".to_string()),
                    full_sync: true,
                    items: Vec::new(),
                    deleted: Vec::new(),
                }],
                false,
                root,
            )
            .expect("apply imported calendars");

        assert!(result.content_changed);
        assert!(!inner.workspace.is_scheme_deleted(first_id));
        assert!(inner.workspace.is_scheme_deleted(duplicate_id));
        assert_eq!(
            inner.workspace.folders[&root].children,
            vec![NodeRef::Scheme(first_id)]
        );
        assert!(result.changes.workspace);
        assert!(result.changes.schemes.contains(&duplicate_id));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn daily_add_always_targets_today_not_selected_snapshot_date() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let future_date = (default_today() + Duration::days(30))
            .format("%Y-%m-%d")
            .to_string();

        let future = core
            .snapshot(Some(future_date.clone()), 0)
            .expect("future snapshot");
        assert!(!future.daily.iter().any(|entry| entry.date == future_date));

        core.add_today_daily_item(
            "2026-05-26".to_string(),
            "Write daily note".to_string(),
            Some("checkbox".to_string()),
            Some(0),
        )
        .expect("add today daily");

        let today = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("today snapshot");
        let daily = today
            .daily
            .iter()
            .find(|entry| entry.date == "2026-05-26")
            .expect("today daily exists");
        assert_eq!(daily.scheme.items[0].text, "Write daily note");

        let future = core
            .snapshot(Some(future_date.clone()), 0)
            .expect("future snapshot after add");
        assert!(!future.daily.iter().any(|entry| entry.date == future_date));

        core.add_calendar_item(
            None,
            Some(future_date.clone()),
            "Future scheduled task".to_string(),
            "reminder".to_string(),
            Some(format!("{future_date}T09:00:00Z")),
            None,
        )
        .expect("add future scheduled daily task");

        let future = core
            .snapshot(Some(future_date.clone()), 0)
            .expect("future snapshot after calendar add");
        assert!(!future.daily.iter().any(|entry| entry.date == future_date));

        let actual_today = default_today().format("%Y-%m-%d").to_string();
        let today = core
            .snapshot(Some(actual_today.clone()), 0)
            .expect("actual today snapshot");
        let today_daily = today
            .daily
            .iter()
            .find(|entry| entry.date == actual_today)
            .expect("actual today daily exists");
        assert!(today_daily
            .scheme
            .items
            .iter()
            .any(|item| item.text == "Future scheduled task"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn calendar_snapshot_groups_occurrences_by_local_day() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let local_start = Local
            .with_ymd_and_hms(2026, 6, 1, 23, 30, 0)
            .single()
            .or_else(|| Local.with_ymd_and_hms(2026, 6, 1, 23, 30, 0).earliest())
            .or_else(|| Local.with_ymd_and_hms(2026, 6, 1, 23, 30, 0).latest())
            .expect("local start");
        let local_end = local_start + Duration::minutes(30);
        let local_date = local_start.date_naive().to_string();
        let utc_date = local_start.with_timezone(&Utc).date_naive().to_string();

        core.create_scheme(None, "Calendar".to_string(), Some(1), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some(local_date.clone()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Calendar")
            .expect("scheme")
            .id;

        core.add_calendar_item(
            Some(scheme_id),
            Some(local_date.clone()),
            "Late local event".to_string(),
            "event".to_string(),
            Some(local_start.with_timezone(&Utc).to_rfc3339()),
            Some(local_end.with_timezone(&Utc).to_rfc3339()),
        )
        .expect("add event");

        let snapshot = core
            .snapshot(Some(local_date.clone()), 0)
            .expect("snapshot after event");
        let local_day = snapshot
            .calendar
            .days
            .iter()
            .find(|day| day.date == local_date)
            .expect("local day");
        let occurrence = local_day
            .occurrences
            .iter()
            .find(|occurrence| occurrence.title == "Late local event")
            .expect("event on local day");
        assert_eq!(occurrence.local_date.as_deref(), Some(local_date.as_str()));

        if utc_date != local_date {
            let utc_day = snapshot
                .calendar
                .days
                .iter()
                .find(|day| day.date == utc_date);
            assert!(!utc_day.is_some_and(|day| day
                .occurrences
                .iter()
                .any(|occurrence| occurrence.title == "Late local event")));
        }

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
                    start: None,
                    end: None,
                    notification_offset_secs: None,
                    repeat_rule: None,
                    media: Vec::new(),
                    content: Vec::new(),
                },
                MobileItemEdit {
                    id: None,
                    text: "New child".to_string(),
                    marker: "bullet".to_string(),
                    indent: 2,
                    done: false,
                    start: None,
                    end: None,
                    notification_offset_secs: None,
                    repeat_rule: None,
                    media: Vec::new(),
                    content: Vec::new(),
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
    fn mobile_tables_are_visible_editable_and_preserved_by_document_saves() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Tables".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Tables")
            .expect("created scheme")
            .id;

        let table_item_id = uuid::Uuid::new_v4().to_string();
        core.insert_table(scheme_id.clone(), None, table_item_id.clone())
            .expect("insert table");
        let table_item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| !item.tables.is_empty())
            .expect("table item");
        // The persisted item carries the caller-supplied id, so the editor can
        // address it immediately without a snapshot round-trip.
        assert_eq!(table_item.id, table_item_id);
        assert_eq!(table_item.tables[0].columns.len(), 2);
        assert_eq!(table_item.tables[0].rows.len(), 2);

        core.set_table_cell_text(
            scheme_id.clone(),
            table_item.id.clone(),
            0,
            1,
            "Q1".to_string(),
        )
        .expect("edit cell");
        core.insert_table_row(scheme_id.clone(), table_item.id.clone(), 1)
            .expect("insert row");
        core.insert_table_column(scheme_id.clone(), table_item.id.clone(), 2)
            .expect("insert column");
        core.set_table_column_name(
            scheme_id.clone(),
            table_item.id.clone(),
            1,
            "Quarter".to_string(),
        )
        .expect("rename column");

        let item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| item.id == table_item.id)
            .expect("table item");
        assert_eq!(item.tables[0].rows[0].cells[1].text, "Q1");
        assert_eq!(item.tables[0].rows.len(), 3);
        assert_eq!(item.tables[0].columns.len(), 3);
        assert_eq!(item.tables[0].columns[1].name, "Quarter");

        core.set_table_cell_text(
            scheme_id.clone(),
            table_item.id.clone(),
            0,
            1,
            "One\nTwo".to_string(),
        )
        .expect("edit multiline cell");
        let item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| item.id == table_item.id)
            .expect("table item");
        assert_eq!(item.tables[0].rows[0].cells[1].text, "One Two");
        assert_eq!(item.tables[0].rows[0].cells[1].lines.len(), 2);
        assert_eq!(item.tables[0].rows[0].cells[1].lines[0].text, "One");
        assert_eq!(item.tables[0].rows[0].cells[1].lines[1].text, "Two");

        // A bulk save that carries no replacement content for the table line must
        // preserve the table. A table is the whole content of its line, so the
        // editor sends empty text/content for it.
        core.replace_scheme_items(
            scheme_id.clone(),
            vec![MobileItemEdit {
                id: Some(table_item.id.clone()),
                text: String::new(),
                marker: "blank".to_string(),
                indent: 0,
                done: false,
                start: None,
                end: None,
                notification_offset_secs: None,
                repeat_rule: None,
                media: Vec::new(),
                content: Vec::new(),
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
            .find(|item| item.id == table_item.id)
            .expect("table item");
        assert_eq!(item.text, "");
        assert_eq!(item.tables[0].rows[0].cells[1].text, "One Two");
        assert_eq!(item.tables[0].rows.len(), 3);
        assert_eq!(item.tables[0].columns.len(), 3);
        assert_eq!(item.tables[0].columns[1].name, "Quarter");

        // A save that *does* carry the table in `content` round-trips it as the
        // line's single block.
        let table = item.tables[0].clone();
        core.replace_scheme_items(
            scheme_id.clone(),
            vec![MobileItemEdit {
                id: Some(table_item.id.clone()),
                text: String::new(),
                marker: "blank".to_string(),
                indent: 0,
                done: false,
                start: None,
                end: None,
                notification_offset_secs: None,
                repeat_rule: None,
                media: Vec::new(),
                content: vec![MobileInline::Table { table }],
            }],
        )
        .expect("replace items with table content");

        let item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| item.id == table_item.id)
            .expect("table item");
        assert_eq!(item.text, "");
        assert_eq!(item.content.len(), 1);
        assert!(matches!(
            item.content.first(),
            Some(MobileInline::Table { .. })
        ));

        core.delete_table_row(scheme_id.clone(), table_item.id.clone(), 1)
            .expect("delete row");
        core.delete_table_column(scheme_id.clone(), table_item.id.clone(), 1)
            .expect("delete column");
        let item = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .into_iter()
            .find(|item| item.id == table_item.id)
            .expect("table item");
        assert_eq!(item.tables[0].rows.len(), 2);
        assert_eq!(item.tables[0].columns.len(), 2);

        // The line's content is the single table block; each cell exposes
        // editable lines (not just a flat summary string).
        assert_eq!(item.content.len(), 1);
        assert!(matches!(
            item.content.first(),
            Some(MobileInline::Table { .. })
        ));
        assert_eq!(item.tables[0].rows[0].cells[0].lines.len(), 1);
        assert_eq!(item.tables[0].rows[0].cells[0].lines[0].marker, "blank");

        // Granular cell-line editing: set, add a second line, then remove it.
        core.set_table_cell_line_text(
            scheme_id.clone(),
            table_item.id.clone(),
            0,
            1,
            0,
            "Updated".to_string(),
        )
        .expect("set cell line text");
        core.add_table_cell_line(
            scheme_id.clone(),
            table_item.id.clone(),
            0,
            1,
            1,
            "Second".to_string(),
        )
        .expect("add cell line");

        let cell = || {
            core.snapshot(Some("2026-05-26".to_string()), 0)
                .expect("snapshot")
                .schemes
                .into_iter()
                .find(|scheme| scheme.id == scheme_id)
                .expect("scheme")
                .items
                .into_iter()
                .find(|item| item.id == table_item.id)
                .expect("table item")
                .tables
                .into_iter()
                .next()
                .expect("table")
                .rows[0]
                .cells[1]
                .clone()
        };
        let edited = cell();
        assert_eq!(edited.lines.len(), 2);
        assert_eq!(edited.lines[0].text, "Updated");
        assert_eq!(edited.lines[1].text, "Second");

        core.remove_table_cell_line(scheme_id.clone(), table_item.id.clone(), 0, 1, 1)
            .expect("remove cell line");
        let trimmed = cell();
        assert_eq!(trimmed.lines.len(), 1);
        assert_eq!(trimmed.lines[0].text, "Updated");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn move_item_to_scheme_transfers_item_preserving_identity() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Source".to_string(), Some(1), None)
            .expect("create source");
        core.create_scheme(None, "Target".to_string(), Some(2), None)
            .expect("create target");
        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        let source_id = snapshot
            .schemes
            .iter()
            .find(|s| s.display_name == "Source")
            .expect("source scheme")
            .id
            .clone();
        let target_id = snapshot
            .schemes
            .iter()
            .find(|s| s.display_name == "Target")
            .expect("target scheme")
            .id
            .clone();

        core.add_item(
            source_id.clone(),
            "Move me".to_string(),
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
            .find(|s| s.id == source_id)
            .expect("source scheme")
            .items
            .into_iter()
            .find(|i| i.text == "Move me")
            .expect("added item")
            .id;

        core.move_item_to_scheme(source_id.clone(), target_id.clone(), item_id.clone())
            .expect("move item");

        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        let source = snapshot
            .schemes
            .iter()
            .find(|s| s.id == source_id)
            .expect("source scheme");
        let target = snapshot
            .schemes
            .iter()
            .find(|s| s.id == target_id)
            .expect("target scheme");
        assert!(
            !source.items.iter().any(|i| i.id == item_id),
            "item left the source scheme"
        );
        let moved = target
            .items
            .iter()
            .find(|i| i.id == item_id)
            .expect("item present in target scheme");
        assert_eq!(moved.text, "Move me", "text preserved");
        assert_eq!(moved.marker, "checkbox", "marker preserved");

        // A same-scheme move is a no-op rather than an error or a duplicate.
        core.move_item_to_scheme(target_id.clone(), target_id.clone(), item_id.clone())
            .expect("no-op move");
        let target_count = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|s| s.id == target_id)
            .expect("target scheme")
            .items
            .iter()
            .filter(|i| i.id == item_id)
            .count();
        assert_eq!(target_count, 1, "no duplicate after same-scheme move");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn lock_recovers_after_a_poisoning_panic() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        // Poison the mutex by panicking while the lock is held, the way a panic
        // mid-sync would. catch_unwind keeps the test from aborting.
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = core.lock().expect("lock");
            panic!("boom while holding the core lock");
        }));
        assert!(panicked.is_err(), "the closure panicked as set up");

        // Before the fix this returned Err("mobile core lock was poisoned"); now
        // the core recovers and keeps working.
        let snapshot = core.snapshot(Some("2026-05-26".to_string()), 0);
        assert!(
            snapshot.is_ok(),
            "core recovers after a poisoning panic instead of wedging"
        );

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
                start: None,
                end: None,
                notification_offset_secs: None,
                repeat_rule: None,
                media: Vec::new(),
                content: Vec::new(),
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
    fn replace_scheme_items_applies_rich_metadata_for_new_items() {
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

        core.replace_scheme_items(
            scheme_id.clone(),
            vec![MobileItemEdit {
                id: None,
                text: "Copied event".to_string(),
                marker: "checkbox".to_string(),
                indent: 2,
                done: true,
                start: Some("2026-05-27T12:00:00Z".to_string()),
                end: Some("2026-05-27T13:00:00Z".to_string()),
                notification_offset_secs: Some(600),
                repeat_rule: Some("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE".to_string()),
                media: Vec::new(),
                content: Vec::new(),
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
            .find(|item| item.text == "Copied event")
            .expect("item");
        assert_eq!(item.marker, "checkbox");
        assert_eq!(item.indent, 2);
        assert!(item.done);
        assert_eq!(item.start.as_deref(), Some("2026-05-27T12:00:00Z"));
        assert_eq!(item.end.as_deref(), Some("2026-05-27T13:00:00Z"));
        assert_eq!(item.notification_offset_secs, Some(600));
        assert_eq!(
            item.repeat_rule.as_deref(),
            Some("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE")
        );

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
        assert_eq!(request.end_at, None);

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

    #[test]
    fn pending_event_notifications_include_end_at() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let now = Utc.with_ymd_and_hms(2026, 5, 27, 12, 0, 0).unwrap();
        let start = now + Duration::hours(2);
        let end = start + Duration::minutes(45);

        core.add_calendar_item(
            None,
            Some(start.date_naive().to_string()),
            "Design review".to_string(),
            "event".to_string(),
            Some(format_datetime(start)),
            Some(format_datetime(end)),
        )
        .expect("add event");

        let request = core
            .pending_notifications(Some(format_datetime(now)), 14)
            .expect("pending notifications")
            .into_iter()
            .find(|request| request.title == "Design review")
            .expect("event notification");

        assert_eq!(request.kind, "event");
        let expected_end = format_datetime(end);
        assert_eq!(request.end_at.as_deref(), Some(expected_end.as_str()));
        assert_eq!(request.expires_at.as_deref(), Some(expected_end.as_str()));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn notification_snooze_actions_reschedule_visible_ios_options() {
        for (action, delay_secs) in [
            (ACTION_SNOOZE_10_MINUTES, 10 * 60),
            (ACTION_SNOOZE_1_HOUR, 60 * 60),
            (ACTION_SNOOZE_2_HOURS, 2 * 60 * 60),
            (ACTION_SNOOZE_6_HOURS, 6 * 60 * 60),
            (ACTION_SNOOZE_1_DAY, 24 * 60 * 60),
        ] {
            let dir =
                std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
            let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
            let now = Utc::now();
            let trigger_at = now + Duration::days(3);
            let date = trigger_at.date_naive().to_string();

            core.add_calendar_item(
                None,
                Some(date),
                format!("Snooze {action}"),
                "reminder".to_string(),
                Some(format_datetime(trigger_at)),
                None,
            )
            .expect("add reminder");

            let request = core
                .pending_notifications(Some(format_datetime(now)), 14)
                .expect("pending notifications")
                .into_iter()
                .find(|request| request.title == format!("Snooze {action}"))
                .expect("new reminder notification");

            let started = Utc::now();
            let changed = core
                .apply_notification_action(
                    action.to_string(),
                    request.scheme_id.clone(),
                    request.item_id.clone(),
                    request.occurrence_json.clone(),
                    request.trigger_at.clone(),
                )
                .expect("snooze");
            let finished = Utc::now();
            assert!(changed);

            let snoozed = core
                .pending_notifications(Some(format_datetime(finished)), 14)
                .expect("pending notifications after snooze")
                .into_iter()
                .find(|request| request.title == format!("Snooze {action}"))
                .expect("snoozed reminder notification");
            let fire_at = parse_datetime(&snoozed.fire_at).expect("snoozed fire_at");
            let expected_delay = Duration::seconds(delay_secs);
            assert!(fire_at >= started + expected_delay - Duration::seconds(1));
            assert!(fire_at <= finished + expected_delay + Duration::seconds(1));

            let _ = std::fs::remove_dir_all(dir);
        }

        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let now = Utc::now();
        let trigger_at = now + Duration::days(3);
        let date = trigger_at.date_naive().to_string();

        core.add_calendar_item(
            None,
            Some(date),
            "Snooze tomorrow morning".to_string(),
            "reminder".to_string(),
            Some(format_datetime(trigger_at)),
            None,
        )
        .expect("add reminder");

        let request = core
            .pending_notifications(Some(format_datetime(now)), 14)
            .expect("pending notifications")
            .into_iter()
            .find(|request| request.title == "Snooze tomorrow morning")
            .expect("new reminder notification");

        let expected_started = notification_tomorrow_morning_utc();
        let changed = core
            .apply_notification_action(
                ACTION_SNOOZE_TOMORROW_MORNING.to_string(),
                request.scheme_id.clone(),
                request.item_id.clone(),
                request.occurrence_json.clone(),
                request.trigger_at.clone(),
            )
            .expect("snooze tomorrow morning");
        let expected_finished = notification_tomorrow_morning_utc();
        assert!(changed);

        let snoozed = core
            .pending_notifications(Some(format_datetime(Utc::now())), 14)
            .expect("pending notifications after snooze")
            .into_iter()
            .find(|request| request.title == "Snooze tomorrow morning")
            .expect("snoozed reminder notification");
        let fire_at = parse_datetime(&snoozed.fire_at).expect("snoozed fire_at");
        assert!(fire_at >= expected_started - Duration::seconds(1));
        assert!(fire_at <= expected_finished + Duration::seconds(1));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn mobile_upcoming_only_shows_next_recurring_occurrence() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let start = Utc::now() + Duration::hours(2);
        let end = start + Duration::minutes(30);
        let today = start.date_naive().to_string();

        core.create_scheme(None, "Recurring".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some(today.clone()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Recurring")
            .expect("scheme")
            .id;
        core.add_calendar_item(
            Some(scheme_id.clone()),
            Some(today.clone()),
            "Daily standup".to_string(),
            "event".to_string(),
            Some(format_datetime(start)),
            Some(format_datetime(end)),
        )
        .expect("add event");
        let item_id = core
            .snapshot(Some(today.clone()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_recurrence(
            scheme_id,
            item_id,
            Some("FREQ=DAILY;INTERVAL=1".to_string()),
        )
        .expect("repeat");

        let snapshot = core.snapshot(Some(today), 0).expect("snapshot");
        let matches = snapshot
            .calendar
            .upcoming
            .iter()
            .filter(|occurrence| occurrence.title == "Daily standup")
            .count();
        assert_eq!(matches, 1);

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn mobile_upcoming_excludes_items_beyond_shared_horizon() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
        let start = Utc::now() + Duration::days(knotq_date_util::UPCOMING_HORIZON_DAYS + 1);
        let end = start + Duration::minutes(30);
        let today = Utc::now().date_naive().to_string();

        core.add_calendar_item(
            None,
            Some(today.clone()),
            "Far future review".to_string(),
            "event".to_string(),
            Some(format_datetime(start)),
            Some(format_datetime(end)),
        )
        .expect("add event");

        let snapshot = core.snapshot(Some(today), 0).expect("snapshot");
        assert!(!snapshot
            .calendar
            .upcoming
            .iter()
            .any(|occurrence| occurrence.title == "Far future review"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn notification_defaults_and_item_override_roundtrip() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.set_notification_defaults(10 * 60, 6 * 60 * 60)
            .expect("set defaults");
        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        assert_eq!(snapshot.settings.event_notification_offset_secs, 10 * 60);
        assert_eq!(
            snapshot.settings.assignment_notification_offset_secs,
            6 * 60 * 60
        );

        core.create_scheme(None, "Notify".to_string(), Some(3), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Notify")
            .expect("scheme")
            .id;
        core.add_calendar_item(
            Some(scheme_id.clone()),
            Some("2026-05-26".to_string()),
            "Ping me".to_string(),
            "event".to_string(),
            Some("2026-05-26T12:00:00Z".to_string()),
            Some("2026-05-26T13:00:00Z".to_string()),
        )
        .expect("add event");
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
        core.set_occurrence_notification_offset(
            scheme_id.clone(),
            item_id.clone(),
            None,
            Some(30 * 60),
        )
        .expect("set offset");

        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        let item = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .iter()
            .find(|item| item.id == item_id)
            .expect("item");
        assert_eq!(item.notification_offset_secs, Some(30 * 60));

        let occurrence = snapshot
            .calendar
            .days
            .into_iter()
            .flat_map(|day| day.occurrences)
            .find(|occurrence| occurrence.title == "Ping me")
            .expect("occurrence");
        assert_eq!(occurrence.notification_offset_secs, Some(30 * 60));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn recurring_event_edit_this_event_uses_desktop_scoped_commit() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Calendar".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Calendar")
            .expect("scheme")
            .id;
        core.add_calendar_item(
            Some(scheme_id.clone()),
            Some("2026-01-05".to_string()),
            "Standup".to_string(),
            "event".to_string(),
            Some("2026-01-05T10:00:00Z".to_string()),
            Some("2026-01-05T11:00:00Z".to_string()),
        )
        .expect("add event");
        let item_id = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_recurrence(
            scheme_id.clone(),
            item_id,
            Some("FREQ=DAILY;INTERVAL=1".to_string()),
        )
        .expect("repeat");

        let occurrence = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .calendar
            .days
            .into_iter()
            .flat_map(|day| day.occurrences)
            .find(|occurrence| {
                occurrence.title == "Standup"
                    && occurrence.local_date.as_deref() == Some("2026-01-07")
            })
            .expect("jan 7 occurrence");
        assert!(occurrence.is_recurring);
        assert_eq!(occurrence.occurrence_index, 2);

        core.commit_event_edit(
            occurrence.scheme_id.clone(),
            occurrence.item_id.clone(),
            occurrence.occurrence_json.clone(),
            occurrence.occurrence_index,
            occurrence.title.clone(),
            occurrence.start.clone(),
            occurrence.end.clone(),
            Some("2026-01-07T14:00:00Z".to_string()),
            Some("2026-01-07T15:00:00Z".to_string()),
            occurrence.repeat_rule.clone(),
            occurrence.notification_offset_secs,
            false,
            occurrence.done,
            "this_event".to_string(),
        )
        .expect("scoped edit");

        let snapshot = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot after edit");
        let item = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .iter()
            .find(|item| item.text == "Standup")
            .expect("item");
        assert_eq!(item.start.as_deref(), Some("2026-01-05T10:00:00Z"));
        let moved = snapshot
            .calendar
            .days
            .into_iter()
            .flat_map(|day| day.occurrences)
            .find(|occurrence| {
                occurrence.title == "Standup"
                    && occurrence.local_date.as_deref() == Some("2026-01-07")
            })
            .expect("moved occurrence");
        assert_eq!(moved.start.as_deref(), Some("2026-01-07T14:00:00Z"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn recurring_event_delete_this_event_adds_exception_not_delete_item() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Calendar".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Calendar")
            .expect("scheme")
            .id;
        core.add_calendar_item(
            Some(scheme_id.clone()),
            Some("2026-01-05".to_string()),
            "Standup".to_string(),
            "event".to_string(),
            Some("2026-01-05T10:00:00Z".to_string()),
            Some("2026-01-05T11:00:00Z".to_string()),
        )
        .expect("add event");
        let item_id = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_recurrence(
            scheme_id.clone(),
            item_id,
            Some("FREQ=DAILY;INTERVAL=1".to_string()),
        )
        .expect("repeat");

        let occurrence = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot")
            .calendar
            .days
            .into_iter()
            .flat_map(|day| day.occurrences)
            .find(|occurrence| {
                occurrence.title == "Standup"
                    && occurrence.local_date.as_deref() == Some("2026-01-07")
            })
            .expect("jan 7 occurrence");
        core.delete_event_occurrence(
            occurrence.scheme_id.clone(),
            occurrence.item_id.clone(),
            occurrence.occurrence_json,
            occurrence.occurrence_index,
            "this_event".to_string(),
        )
        .expect("delete occurrence");

        let snapshot = core
            .snapshot(Some("2026-01-05".to_string()), 0)
            .expect("snapshot after delete");
        let item_count = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items
            .len();
        assert_eq!(item_count, 1);
        assert!(!snapshot
            .calendar
            .days
            .into_iter()
            .flat_map(|day| day.occurrences)
            .any(|occurrence| {
                occurrence.title == "Standup"
                    && occurrence.local_date.as_deref() == Some("2026-01-07")
            }));

        let _ = std::fs::remove_dir_all(dir);
    }

    fn imported_google_scheme(name: &str, account_id: &str, calendar_id: &str) -> Scheme {
        let mut scheme = Scheme::new(name, 0);
        scheme.source = SchemeSource::ImportedCalendar(ImportedCalendarSource {
            provider: CalendarProvider::Google,
            account_id: account_id.to_string(),
            account_email: Some("user@example.com".to_string()),
            calendar_id: calendar_id.to_string(),
            sync_token: None,
            read_only: true,
            last_synced_at: None,
        });
        scheme
    }
}
