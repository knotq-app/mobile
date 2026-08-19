use super::*;

impl MobileCore {
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

    /// Returns whether the day's queue had to be created. Every launch and every
    /// return to the foreground calls this, and on all but the first call of a
    /// day the queue is already there — so both the save here and the caller's
    /// snapshot rebuild are pure launch latency unless something changed.
    pub fn ensure_daily_queue(&self, date: Option<String>) -> Result<bool, MobileError> {
        let date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        if !inner.ensure_daily_queue(date)?.1 {
            return Ok(false);
        }
        inner.save_workspace()?;
        Ok(true)
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

    /// Links a Google account from a token the shell obtained through a
    /// platform identity service, then imports its calendars.
    ///
    /// This is Android's replacement for `complete_google_calendar_import`:
    /// Google blocks the loopback redirect on Android, so the shell runs Google
    /// Identity `AuthorizationClient` and hands the resulting access token here
    /// instead of an authorization code. Desktop and iOS keep using the
    /// browser/OAuth entry points above.
    pub fn import_google_calendars_with_identity(
        &self,
        account: MobileGoogleIdentityAccount,
        parent_id: Option<String>,
    ) -> Result<MobileGoogleSyncResult, MobileError> {
        let account = MobileGoogleIdentityAccount {
            client_id: non_empty(account.client_id, "Google client id")?,
            access_token: non_empty(account.access_token, "Google access token")?,
            ..account
        };
        let mut inner = self.lock()?;
        let parent = parent_id
            .as_deref()
            .map(parse_id)
            .transpose()?
            .unwrap_or(inner.workspace.root);
        inner
            .import_google_calendars_with_identity(account, parent)
            .map_err(Into::into)
    }

    pub fn sync_google_calendars(&self) -> Result<MobileGoogleSyncResult, MobileError> {
        self.lock()?.sync_google_calendars().map_err(Into::into)
    }

    /// Syncs every linked account, using shell-supplied access tokens for the
    /// accounts the core cannot refresh on its own.
    ///
    /// Android calls this on every periodic/manual sync after asking Google
    /// Identity for a fresh token per connected account. Accounts with no entry
    /// in `accounts` sync with their stored credentials exactly as before.
    pub fn sync_google_calendars_with_identity(
        &self,
        accounts: Vec<MobileGoogleIdentityAccount>,
    ) -> Result<MobileGoogleSyncResult, MobileError> {
        self.lock()?
            .sync_google_calendars_with_identities(accounts)
            .map_err(Into::into)
    }

    /// Records that an account needs the user to grant authorization again.
    pub fn set_google_account_needs_reauth(
        &self,
        account_id: String,
        needs_reauth: bool,
    ) -> Result<(), MobileError> {
        let account_id = non_empty(account_id, "Google account id")?;
        self.lock()?
            .set_google_account_needs_reauth(&account_id, needs_reauth)
            .map_err(Into::into)
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
        let (scheme_id, _created) = inner.ensure_daily_queue(today)?;
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
            None => inner.ensure_daily_queue(default_today())?.0,
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
                let header = knotq_l10n::t_with(
                    "editor.table.default_column",
                    &[("number", &(at + 1).to_string())],
                );
                table.insert_column(at, header);
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

    // This is the original UniFFI surface used by the iOS bridge. Keep it
    // source-compatible; Android uses `commit_event_edit_payload` below because
    // its JNA bridge cannot marshal the trailing booleans reliably.
    #[allow(clippy::too_many_arguments)]
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
            .commit_event_edit(crate::mobile_core_inner_ops::CommitEventEdit {
                scheme_id: parse_id(&scheme_id)?,
                item_id: parse_id(&item_id)?,
                occurrence: parse_occurrence_json(&occurrence_json)?,
                occurrence_index: position_from_i32(occurrence_index)?,
                title,
                occurrence_start: parse_datetime_opt(occurrence_start.as_deref())?,
                occurrence_end: parse_datetime_opt(occurrence_end.as_deref())?,
                draft_start: parse_datetime_opt(start.as_deref())?,
                draft_end: parse_datetime_opt(end.as_deref())?,
                draft_repeats: recurrence_from_rrule(rrule),
                draft_notification_offset_secs: notification_offset_secs.map(i64::from),
                notification_dirty,
                draft_done: done,
                scope: parse_date_edit_scope(&scope)?,
            })
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

    pub fn set_upcoming_display_settings(
        &self,
        event_lookahead_days: i32,
        reminder_lookahead_days: i32,
        assignment_lookahead_days: i32,
        maximum_items: i32,
        show_overdue: bool,
        show_completed: bool,
    ) -> Result<(), MobileError> {
        for (name, days) in [
            ("event", event_lookahead_days),
            ("reminder", reminder_lookahead_days),
            ("assignment", assignment_lookahead_days),
        ] {
            if !(MOBILE_UPCOMING_MIN_LOOKAHEAD_DAYS..=MOBILE_UPCOMING_MAX_LOOKAHEAD_DAYS)
                .contains(&days)
            {
                return Err(anyhow!("{name} lookahead must be between 1 and 365 days").into());
            }
        }
        if !(MOBILE_UPCOMING_MIN_ITEMS..=MOBILE_UPCOMING_MAX_ITEMS).contains(&maximum_items) {
            return Err(anyhow!("maximum upcoming items must be between 1 and 100").into());
        }

        let mut inner = self.lock()?;
        let display = UpcomingDisplaySettings {
            event_lookahead_days: as_u16(event_lookahead_days, "event lookahead days")?,
            reminder_lookahead_days: as_u16(reminder_lookahead_days, "reminder lookahead days")?,
            assignment_lookahead_days: as_u16(
                assignment_lookahead_days,
                "assignment lookahead days",
            )?,
            maximum_items: as_u16(maximum_items, "maximum upcoming items")?,
            show_overdue,
            show_completed,
        };
        if inner.settings.upcoming_display == display {
            return Ok(());
        }
        inner.settings.upcoming_display = display;
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

    /// OS notification ids the shell should remove from the delivered list (and
    /// any matching pending alarm) because their event has ended or their
    /// occurrence was completed. The shell calls this on refresh/foreground so a
    /// banner doesn't outlive its event's end time or persist after completion.
    pub fn delivered_notifications_to_clear(
        &self,
        now: Option<String>,
    ) -> Result<Vec<String>, MobileError> {
        let now = parse_datetime_opt(now.as_deref())?.unwrap_or_else(Utc::now);
        self.lock()?
            .delivered_notifications_to_clear(now)
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

    // ---------------------------------------------------------------------
    // Accounts/sync surface. These 8 functions stay in the UDL unconditionally
    // (generated bindings expect them), but when the `accounts` feature is OFF
    // their bodies stub to safe no-ops/defaults so shipped builds carry no
    // sign-in/sync/billing behavior. Real impls are `#[cfg(feature = "accounts")]`.
    // ---------------------------------------------------------------------

    #[cfg(feature = "accounts")]
    pub fn sync_once(&self, api_base: String, bearer_token: String) -> Result<bool, MobileError> {
        self.lock()?
            .sync_once(&api_base, &bearer_token)
            .map_err(Into::into)
    }

    #[cfg(not(feature = "accounts"))]
    pub fn sync_once(&self, _api_base: String, _bearer_token: String) -> Result<bool, MobileError> {
        Ok(false)
    }

    #[cfg(feature = "accounts")]
    pub fn take_sync_notice(&self) -> Result<Option<String>, MobileError> {
        Ok(self.lock()?.sync_notice.take())
    }

    #[cfg(not(feature = "accounts"))]
    pub fn take_sync_notice(&self) -> Result<Option<String>, MobileError> {
        Ok(None)
    }

    /// Open a persistent WebSocket for online, poll-free sync. While connected,
    /// `sync_once`'s pull/push ride the socket and a peer's push triggers a prompt
    /// sync (see `ws_pending_changed`). Idempotent; re-points on an account change.
    #[cfg(feature = "accounts")]
    pub fn start_ws_sync(&self, api_base: String, bearer_token: String) -> Result<(), MobileError> {
        self.lock()?.start_ws_sync(&api_base, &bearer_token);
        Ok(())
    }

    #[cfg(not(feature = "accounts"))]
    pub fn start_ws_sync(
        &self,
        _api_base: String,
        _bearer_token: String,
    ) -> Result<(), MobileError> {
        Ok(())
    }

    /// Tear down the WebSocket (sign-out, app backgrounded). Sync falls back to HTTP.
    #[cfg(feature = "accounts")]
    pub fn stop_ws_sync(&self) -> Result<(), MobileError> {
        self.lock()?.stop_ws_sync();
        Ok(())
    }

    #[cfg(not(feature = "accounts"))]
    pub fn stop_ws_sync(&self) -> Result<(), MobileError> {
        Ok(())
    }

    #[cfg(feature = "accounts")]
    pub fn is_ws_connected(&self) -> Result<bool, MobileError> {
        Ok(self.lock()?.is_ws_connected())
    }

    #[cfg(not(feature = "accounts"))]
    pub fn is_ws_connected(&self) -> Result<bool, MobileError> {
        Ok(false)
    }

    /// Whether a server `changed` nudge is waiting. The shell polls this while
    /// connected and calls `sync_once` promptly when true (which clears it). Read
    /// lock-free so the poll is never blocked behind an in-flight `sync_once`.
    #[cfg(feature = "accounts")]
    pub fn ws_pending_changed(&self) -> Result<bool, MobileError> {
        Ok(self.ws_changed.load(std::sync::atomic::Ordering::SeqCst))
    }

    #[cfg(not(feature = "accounts"))]
    pub fn ws_pending_changed(&self) -> Result<bool, MobileError> {
        Ok(false)
    }

    /// Flag that a peer pushed — the shell calls this when a silent FCM wake-up
    /// arrives, before running `sync_once`. Equivalent to the socket's server
    /// `changed` nudge: it defeats the idle-sync coalescer, which otherwise skips
    /// the pull when nothing local is queued and the last sync looks recent.
    /// "Recent" is measured on a monotonic clock that pauses while the device
    /// sleeps, so without this flag a background wake can silently pull nothing
    /// and a peer's change (often a notification) is missed until the next wake.
    #[cfg(feature = "accounts")]
    pub fn note_remote_changed(&self) -> Result<(), MobileError> {
        self.ws_changed
            .store(true, std::sync::atomic::Ordering::SeqCst);
        Ok(())
    }

    #[cfg(not(feature = "accounts"))]
    pub fn note_remote_changed(&self) -> Result<(), MobileError> {
        Ok(())
    }

    /// Hand the core a push token (e.g. an FCM registration token) so the next
    /// sync registers this device for silent background wake-ups. An empty token
    /// clears the registration. Channel is FCM; environment is "sandbox"/"production".
    #[cfg(feature = "accounts")]
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

    #[cfg(not(feature = "accounts"))]
    pub fn set_push_registration(
        &self,
        _token: String,
        _environment: String,
    ) -> Result<(), MobileError> {
        Ok(())
    }

    pub fn seed_editor_image_fixture(&self) -> Result<(), MobileError> {
        self.lock()?.seed_editor_image_fixture().map_err(Into::into)
    }
}
