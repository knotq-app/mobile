use super::*;

impl MobileCoreInner {
    pub(crate) fn open(app_dir: PathBuf) -> Result<Self> {
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
            ws_client: None,
            ws_token: std::sync::Arc::new(std::sync::Mutex::new(String::new())),
            ws_changed: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            ws_api_base: None,
        })
    }

    /// Insert/remove a toggled occurrence from the retained-completed set based on
    /// its resulting done state — mirroring desktop's
    /// `sync_retained_completed_calendar_items`.
    pub(crate) fn sync_retained_completed(
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
        let now = Utc::now();
        if is_done {
            self.retained_completed.insert(key, now);
        } else {
            self.retained_completed.remove(&key);
        }
        // Bound the set: entries past their panel TTL are dead weight.
        self.retained_completed.purge_expired(now);
    }

    pub(crate) fn apply(&mut self, command: Command) -> Result<()> {
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
    pub(crate) fn complete_past_events(&mut self, now: DateTime<Utc>) -> Result<usize> {
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

    pub(crate) fn save_workspace(&self) -> Result<()> {
        save_workspace(&self.workspace_path, &self.workspace)?;
        // Persist the CRDT documents' state in lockstep with the workspace so a
        // restart restores them consistently (and with their stable identity).
        save_crdt_state(&self.workspace_path, &self.crdt.document_states())
    }

    pub(crate) fn load_daily_queue_scheme_if_needed(&mut self, date: NaiveDate) -> Result<Option<SchemeId>> {
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

    pub(crate) fn load_daily_queue_date_range(&mut self, start: NaiveDate, end: NaiveDate) -> Result<()> {
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

    pub(crate) fn load_daily_queue_calendar_range(&mut self, start: NaiveDate, end: NaiveDate) -> Result<()> {
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

    pub(crate) fn save_settings(&self) -> Result<()> {
        save_app_settings(&self.settings_path, &self.settings)
    }

    pub(crate) fn pending_notifications(
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

    /// OS notification ids whose delivered banners should be torn down: events
    /// whose occurrence has passed its end time, plus any occurrence (event,
    /// reminder, assignment) that has since been completed. `pending_notifications`
    /// already drops these from the *scheduled* set, so this exists to dismiss the
    /// banner that already fired and otherwise lingers in Notification Center.
    pub(crate) fn delivered_notifications_to_clear(
        &self,
        now: DateTime<Utc>,
    ) -> Result<Vec<String>> {
        let lead_times = mobile_notification_lead_times(self.settings.notification_defaults);
        let mut keys = expired_event_notification_keys(&self.workspace, lead_times, now);
        keys.extend(completed_notification_keys(
            &self.workspace,
            lead_times,
            now - Duration::days(NOTIFICATION_HORIZON_DAYS),
            now + Duration::days(NOTIFICATION_HORIZON_DAYS),
        ));
        keys.sort();
        keys.dedup();
        Ok(keys
            .into_iter()
            .map(|key| mobile_notification_id(&key))
            .collect())
    }

    pub(crate) fn apply_notification_action(
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

    pub(crate) fn commit_event_edit(
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

    pub(crate) fn delete_event_occurrence(
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

    pub(crate) fn record_crdt_changes(&mut self, changeset: WorkspaceCrdtChangeSet) -> Result<()> {
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

    pub(crate) fn register_push_device(&mut self, client: &MobileSyncHttpClient) {
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
    pub(crate) fn should_coalesce_idle_sync(&self, has_local_pending: bool) -> bool {
        if has_local_pending {
            return false;
        }
        self.last_remote_sync_at
            .is_some_and(|last| last.elapsed() < MIN_REMOTE_SYNC_INTERVAL)
    }

    pub(crate) fn sync_once(&mut self, api_base: &str, bearer_token: &str) -> Result<bool> {
        // Coalesce wake-storms: a silent push wakes every device on each push, so two
        // devices that re-push on every sync form a feedback loop that barrages the
        // backend. Skip the round-trip when nothing local is queued and we synced
        // moments ago — see `should_coalesce_idle_sync`.
        let has_local_pending = load_local_sync_state(&self.workspace_path)
            .map(|state| !state.pending.is_empty())
            .unwrap_or(false);
        // A server `changed` nudge over the socket means a peer pushed — always run
        // (and clear the flag) rather than coalescing it away.
        let ws_changed = self.ws_changed.swap(false, std::sync::atomic::Ordering::SeqCst);
        if !ws_changed && self.should_coalesce_idle_sync(has_local_pending) {
            return Ok(false);
        }
        self.last_remote_sync_at = Some(std::time::Instant::now());
        // Keep the ws reconnect token fresh (the shell hands us the current token).
        if let Ok(mut token) = self.ws_token.lock() {
            *token = bearer_token.to_string();
        }

        let client = MobileSyncHttpClient {
            api_base: normalize_sync_api_base(api_base)?,
            bearer_token: bearer_token.to_string(),
        };
        // Batched pull/push prefer the live socket and fall back to HTTP; aux calls
        // (account status, device register, media) always use the HTTP `client`.
        // Clone the Arc into a local so the transport doesn't borrow `self` (which is
        // mutated below).
        let ws_client = self.ws_client.clone();
        let transport = crate::ws_sync::FallbackTransport::new(ws_client.as_deref(), &client);
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
            // Force re-seed this device's scheme content to the new account. The
            // bootstrap only re-seeds documents the new server LACKS, so a scheme the
            // new account already holds from another origin would otherwise never
            // receive this device's content (the cross-account content gap). Full
            // snapshots union idempotently; deterministic item creation dedupes items.
            queue_account_switch_reseed(
                &mut sync_state,
                &self.crdt,
                &self.workspace,
                self.settings.replica_id,
            );
            self.next_sequence = sync_state
                .pending
                .iter()
                .map(|edit| edit.local_sequence)
                .max()
                .unwrap_or(0)
                + 1;
        }

        // Register this device (with its push token, if any) so the backend can
        // wake it via silent push. Best effort — never block sync on it.
        self.register_push_device(&client);

        // One batched pull syncs the whole workspace: the server returns the current
        // merged state of every document past our cursor (and any document created
        // on another device). Applying merged state is idempotent in Yjs.
        let workspace = self.workspace.clone();
        let pull = batch_pull_and_apply(
            &transport,
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
            &transport,
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

    pub(crate) fn ensure_daily_queue(&mut self, date: NaiveDate) -> Result<SchemeId> {
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

    pub(crate) fn complete_google_calendar_import(
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

    pub(crate) fn sync_google_calendars(&mut self) -> Result<MobileGoogleSyncResult> {
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

    pub(crate) fn unlink_google_account(&mut self, account_id: &str) -> Result<()> {
        let old_len = self.settings.google_accounts.len();
        self.settings
            .google_accounts
            .retain(|account| account.account_id != account_id);
        if self.settings.google_accounts.len() != old_len {
            self.save_settings()?;
        }
        Ok(())
    }

    pub(crate) fn finish_google_calendar_sync(
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

    pub(crate) fn upsert_google_accounts(&mut self, accounts: Vec<knotq_model::GoogleOAuthAccount>) -> bool {
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

    pub(crate) fn google_accounts(&self) -> Vec<MobileGoogleAccount> {
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

    pub(crate) fn google_calendar_scheme_count_for_account(&self, account: &GoogleOAuthAccount) -> usize {
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

    pub(crate) fn apply_imported_google_calendars(
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

    pub(crate) fn delete_duplicate_google_calendar_schemes(
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

}
