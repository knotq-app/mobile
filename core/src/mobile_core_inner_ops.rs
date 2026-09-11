use super::*;
use base64::Engine as _;
use knotq_model::WorkspaceId;
use sha2::{Digest, Sha256};
use std::collections::HashSet;

pub(crate) struct CommitEventEdit {
    pub(crate) scheme_id: SchemeId,
    pub(crate) item_id: ItemId,
    pub(crate) occurrence: OccurrenceId,
    pub(crate) occurrence_index: usize,
    pub(crate) title: String,
    pub(crate) occurrence_start: Option<DateTime<Utc>>,
    pub(crate) occurrence_end: Option<DateTime<Utc>>,
    pub(crate) draft_start: Option<DateTime<Utc>>,
    pub(crate) draft_end: Option<DateTime<Utc>>,
    pub(crate) draft_repeats: Option<Recurrence>,
    pub(crate) draft_notification_offset_secs: Option<i64>,
    pub(crate) notification_dirty: bool,
    pub(crate) draft_done: bool,
    pub(crate) scope: DateEditScope,
}

/// The small set of prelude decisions that change the transport-agnostic sync
/// cycle. Keeping these together makes call sites auditable and avoids growing
/// a long positional argument list every time a new repair mode is added.
pub(crate) struct SyncCycleOptions<'a> {
    pub(crate) account_switched: bool,
    pub(crate) prelude_workspace_changed: bool,
    pub(crate) media_client: Option<&'a MobileSyncHttpClient>,
    pub(crate) push_local_edits_first: bool,
}

/// Phase timing for `MobileCoreInner::open`, printed when `KNOTQ_LOAD_TIMING`
/// is set. Cold launch blocks on `open` before a single frame is drawn, and the
/// phases have unrelated causes (scheme XML parse, CRDT restore, a startup
/// save), so a total tells you nothing actionable. Mirrors `KNOTQ_EDIT_TIMING`
/// in `save_workspace`.
struct LoadTiming {
    enabled: bool,
    at: std::time::Instant,
}

impl LoadTiming {
    fn start() -> Self {
        Self {
            enabled: std::env::var_os("KNOTQ_LOAD_TIMING").is_some(),
            at: std::time::Instant::now(),
        }
    }

    fn phase(&mut self, label: &str) {
        if self.enabled {
            eprintln!("  open: {label} {}ms", self.at.elapsed().as_millis());
        }
        self.at = std::time::Instant::now();
    }
}

/// Phase timing for one sync cycle, printed only when `KNOTQ_SYNC_TIMING` is
/// set. Sync deliberately holds the core mutex while it runs, so a user-visible
/// "Resyncing" delay needs a phase split rather than another total guessed from
/// the UI. This is diagnostic-only and is inert in normal/release builds unless
/// explicitly enabled.
struct SyncTiming {
    enabled: bool,
    at: std::time::Instant,
}

impl SyncTiming {
    fn start() -> Self {
        Self {
            // Debug mobile builds collect this in the native sync log by
            // default; desktop/host tests stay quiet. Release builds require
            // the explicit opt-in, so this cannot become store-facing noise.
            enabled: (cfg!(debug_assertions)
                && cfg!(any(target_os = "android", target_os = "ios")))
                || std::env::var_os("KNOTQ_SYNC_TIMING").is_some(),
            at: std::time::Instant::now(),
        }
    }

    fn phase(&mut self, label: &str) {
        if self.enabled {
            eprintln!("  sync: {label} {}ms", self.at.elapsed().as_millis());
        }
        self.at = std::time::Instant::now();
    }
}

fn sync_token_fingerprint(bearer_token: &str) -> String {
    Sha256::digest(bearer_token.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

impl MobileCoreInner {
    pub(crate) fn open(app_dir: PathBuf) -> Result<Self> {
        let mut timing = LoadTiming::start();
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
        timing.phase("load_workspace");
        // `|` not `||`: both normalizations must run, and the third is what mints
        // any missing sync identity. Together they decide whether what we hold
        // differs from what is on disk — see the save below.
        let workspace_changed = workspace.normalize_one_level_folders()
            | workspace.normalize_item_markers()
            | workspace.ensure_sync_metadata();
        timing.phase("normalize");
        let settings = load_app_settings(&settings_path).unwrap_or_default();
        timing.phase("load_settings");
        if should_reset_workspace_dir {
            // The workspace index could not be parsed, so the fresh in-memory
            // replacement must not inherit its old "already pulled" cursor.
            // Reset only the workspace-index cursor: the next pull receives
            // that one document, discovers the actual scheme set, and the sync
            // engine re-fetches only scheme documents missing from the new
            // local CRDT store. Keeping every scheme cursor and pending edit is
            // both faster and safer than a workspace-wide reset.
            let mut sync_state = load_local_sync_state(&workspace_path).unwrap_or_default();
            if sync_state.reset_workspace_pull_cursor() {
                if let Err(error) = save_local_sync_state(&workspace_path, &sync_state) {
                    eprintln!(
                        "knotq: could not persist workspace parse-recovery cursor reset: {error:#}"
                    );
                }
            }
        }
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
        // Only write back what loading actually changed. A save here rewrites
        // every scheme file, the index, the daily backup and a history snapshot
        // — and it blocks the first frame, since the shell opens the core on the
        // main actor. On the normal launch nothing changed, so persisting is
        // pure launch latency; when normalization or sync-identity minting did
        // change something it still has to reach disk before an OS notification
        // action can depend on those ids. (Desktop gates its startup save the
        // same way.) Best-effort: a transient write failure must not prevent
        // startup — the workspace lives in memory and every edit retries.
        if workspace_changed || should_reset_workspace_dir {
            if let Err(error) = save_workspace(&workspace_path, &workspace) {
                eprintln!("knotq: deferring workspace save at startup: {error:#}");
            }
        }
        timing.phase("save_workspace");
        // Cheap now (`save_app_settings` skips an unchanged file), and still the
        // path that seeds a first-launch settings.json and moves any plaintext
        // token into the keychain.
        if let Err(error) = save_app_settings(&settings_path, &settings) {
            eprintln!("knotq: deferring settings save at startup: {error:#}");
        }
        timing.phase("save_settings");
        let persisted_sync_state = load_local_sync_state(&workspace_path).unwrap_or_default();
        let next_sequence = persisted_sync_state
            .pending
            .iter()
            .map(|edit| edit.local_sequence)
            .max()
            .unwrap_or(0)
            + 1;
        // Restore the long-lived CRDT documents from disk with this replica's stable
        // deterministic clientID, so their Yjs identity survives restarts instead of
        // being rebuilt from plain data with a throwaway identity.
        timing.phase("load_sync_state");
        let crdt_states = load_crdt_state(&workspace_path).unwrap_or_default();
        timing.phase("load_crdt_state");
        let crdt = WorkspaceCrdtDocuments::from_states_lazy(
            &workspace,
            settings.replica_id,
            &crdt_states,
        )?;
        timing.phase("crdt_from_states");
        // Do not scan every deferred CRDT update on a clean launch. The cache
        // is only needed by the one-shot interrupted-sync recovery proof, and
        // that proof fills it inside the sync task when it is actually needed.
        // This keeps a normal launch entirely free of the historical daily
        // queue's CRDT metadata work.
        Ok(Self {
            workspace_path,
            settings_path,
            image_assets_dir,
            workspace,
            indexed_workspace: None,
            settings,
            crdt,
            next_sequence,
            sync_state_cache: None,
            dirty_schemes: std::collections::HashSet::new(),
            dirty_crdt_schemes: std::collections::HashSet::new(),
            crdt_state_requires_full_save: false,
            daily_recovery_pending: false,
            deferred_materialization_pending: persisted_sync_state
                .deferred_materialization_pending
                .iter()
                .copied()
                .collect(),
            sync_notice: None,
            push_token: None,
            push_environment: None,
            registered_push_token: None,
            registered_push_environment: None,
            retained_completed: RetainedCompletedItems::default(),
            background_refresh_required: false,
            notification_schedule_cache: None,
            last_remote_sync_at: None,
            // A cleanly completed prior sync does not need a workspace-wide
            // state-vector proof on every launch. Arm it only when the previous
            // process died during a sync, after it may have advanced cursors or
            // written only half of the paired workspace/CRDT state.
            startup_integrity_check_pending: persisted_sync_state.sync_in_progress,
            ws_client: None,
            ws_token: std::sync::Arc::new(std::sync::Mutex::new(String::new())),
            ws_changed: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            ws_api_base: None,
            account_workspace_cache: None,
            http_agent: ureq::Agent::new(),
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
        let t0 = std::time::Instant::now();
        let crdt_changes = mobile_crdt_change_set_for_command(&command);
        if mobile_command_may_change_notification_schedule(&self.workspace, &command) {
            self.notification_schedule_cache = None;
        }
        // A completion or schedule edit can require offline peers to redraw
        // their Upcoming widget / cancel a delivered banner even when the
        // pushed notification hash is unchanged (e.g. completing a past
        // occurrence). Carry that intent through the next push. Covers every
        // apply path — direct edits, notification "Mark Done", event-popup
        // commits — not just the toggle_occurrence entry point.
        if mobile_command_requires_background_refresh(&command) {
            self.background_refresh_required = true;
        }
        let receipt = self.workspace.apply(command)?;
        // Only the schemes this command touched need their files rewritten. The
        // receipt's `touched` set is the same one the desktop's incremental save
        // relies on.
        self.dirty_schemes
            .extend(receipt.touched.schemes.iter().copied());
        self.workspace.normalize_one_level_folders();
        self.workspace.normalize_item_markers();
        let t1 = std::time::Instant::now();
        self.record_crdt_changes(crdt_changes)?;
        let t2 = std::time::Instant::now();
        let r = self.save_workspace();
        if edit_timing_enabled() {
            eprintln!(
                "apply: command {:?}ms, crdt+pending {:?}ms, save_workspace {:?}ms",
                (t1 - t0).as_millis(),
                (t2 - t1).as_millis(),
                t2.elapsed().as_millis()
            );
        }
        r
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
        self.notification_schedule_cache = None;
        let mut changeset = WorkspaceCrdtChangeSet::default();
        for key in &keys {
            changeset.schemes.insert(key.scheme_id);
        }
        self.record_crdt_changes(changeset)?;
        self.background_refresh_required = true;
        self.save_workspace()?;
        Ok(changed)
    }

    pub(crate) fn save_workspace(&mut self) -> Result<()> {
        // A successful mutation may have changed any index dimension. Drop the
        // read cache before persistence so a later snapshot/search can only
        // observe a freshly-built view of the workspace.
        self.indexed_workspace = None;
        // Rewrite only the scheme files that changed. A full save writes all of
        // them — measured at ~55 ms of a ~57 ms edit on a 170-scheme workspace,
        // which is the entire cost of a keystroke pause. An empty dirty set
        // still means "write everything", so the paths that can touch any
        // scheme (sync pulls, migrations) keep their previous behaviour.
        if self.dirty_schemes.is_empty() {
            save_workspace(&self.workspace_path, &self.workspace)?;
        } else {
            save_workspace_incremental(&self.workspace_path, &self.workspace, &self.dirty_schemes)?;
        }
        // Persist the CRDT documents' state in lockstep with the workspace so a
        // restart restores them consistently (and with their stable identity).
        // A checkbox or text edit changes exactly one scheme document. Once the
        // per-document directory is authoritative, avoid encoding and probing
        // every other CRDT document for that common path. Structural edits and
        // all migration/legacy states retain the full writer, which also sweeps
        // deleted documents safely.
        let can_save_crdt_incrementally = !self.crdt_state_requires_full_save
            && !self.dirty_crdt_schemes.is_empty()
            && crdt_state_dir(&self.workspace_path).is_dir()
            && !crdt_state_path(&self.workspace_path).exists();
        if can_save_crdt_incrementally {
            save_crdt_state_incremental(
                &self.workspace_path,
                &self.crdt.scheme_document_states(&self.dirty_crdt_schemes),
            )?;
        } else {
            save_crdt_state(&self.workspace_path, &self.crdt.document_states())?;
        }
        // Only clear once both writes landed: a failure must leave the schemes
        // marked so the next save retries them rather than leaving them stale.
        self.dirty_schemes.clear();
        self.dirty_crdt_schemes.clear();
        self.crdt_state_requires_full_save = false;
        Ok(())
    }

    pub(crate) fn load_daily_queue_scheme_if_needed(
        &mut self,
        date: NaiveDate,
    ) -> Result<Option<SchemeId>> {
        let Some(expected_id) = self.workspace.daily_queue_scheme_id(date) else {
            return Ok(None);
        };
        if self.workspace.schemes.contains_key(&expected_id) {
            return Ok(Some(expected_id));
        }

        match load_daily_queue_scheme(&self.workspace_path, date) {
            Ok(Some(scheme)) if scheme.id == expected_id => {
                self.notification_schedule_cache = None;
                let remote_materialization_pending = self
                    .workspace
                    .scheme_sync
                    .get(&expected_id)
                    .is_some_and(|meta| {
                        self.deferred_materialization_pending.contains(&meta.id)
                            && self.crdt.is_deferred(expected_id)
                    });
                if remote_materialization_pending
                    && self.materialize_deferred_daily_if_available(expected_id)?
                {
                    return Ok(Some(expected_id));
                }
                self.workspace.schemes.insert(expected_id, scheme);
                self.indexed_workspace = None;
                // A valid plain file is sufficient for this lazy load. If a
                // remote pull retained newer CRDT bytes for this off-window
                // day, the normal remote-change path already rewrites the
                // file before advancing its durable cursor. Do not hydrate the
                // whole requested history range here: `snapshot(..., 120)` can
                // legitimately load dozens of valid historical files, and
                // doing so would turn a lazy read into a CRDT decode sweep.
                Ok(Some(expected_id))
            }
            Ok(Some(scheme)) => Err(anyhow!(
                "daily queue {} loaded with unexpected id {}, expected {}",
                date,
                scheme.id,
                expected_id
            )),
            Ok(None) if self.materialize_deferred_daily_if_available(expected_id)? => {
                self.notification_schedule_cache = None;
                Ok(Some(expected_id))
            }
            Ok(None) => {
                self.workspace.daily_queue.remove(&date);
                self.indexed_workspace = None;
                Ok(None)
            }
            Err(parse_error) => {
                // The Daily Queue file for this date is unreadable (a partial
                // write, malformed XML, bad bytes). Its durable CRDT state may
                // still be intact: decode just that one document from the
                // deferred bytes so the next sync -- even a caught-up one --
                // re-materializes the day and the following save rewrites a
                // good file. Unrelated deferred dailies are untouched. The
                // parse error is still surfaced so the caller knows this exact
                // date is not yet renderable; the retry after a sync succeeds.
                if self.crdt.request_deferred_recovery(expected_id) {
                    self.daily_recovery_pending = true;
                    eprintln!(
                        "knotq: daily queue {date} file unreadable ({parse_error:#}); \
                         scheduled CRDT-backed recovery for {expected_id}"
                    );
                }
                Err(parse_error)
            }
        }
    }

    /// Hydrate one deferred daily when it enters the view and persist only that
    /// day if its CRDT state is available. Returns whether a scheme was
    /// materialized. A failed hydration leaves the caller's ordinary file-load
    /// or corruption-recovery path in charge.
    fn materialize_deferred_daily_if_available(&mut self, scheme_id: SchemeId) -> Result<bool> {
        if !self.crdt.is_deferred(scheme_id) {
            return Ok(false);
        }
        self.crdt.request_deferred_recovery(scheme_id);
        let repaired = self
            .crdt
            .materialized_workspace_repair(&self.workspace, &|id| *id == scheme_id)?;
        let Some(scheme) = repaired.schemes.get(&scheme_id).cloned() else {
            return Ok(false);
        };
        self.workspace.schemes.insert(scheme_id, scheme);
        self.indexed_workspace = None;
        self.dirty_schemes.insert(scheme_id);
        self.dirty_crdt_schemes.insert(scheme_id);
        self.save_workspace()?;
        if let Some(document) = self
            .workspace
            .scheme_sync
            .get(&scheme_id)
            .map(|meta| meta.id)
        {
            self.deferred_materialization_pending.remove(&document);
            let mut sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
            if sync_state.clear_deferred_materialization(document) {
                save_local_sync_state(&self.workspace_path, &sync_state)?;
            }
        }
        Ok(true)
    }

    pub(crate) fn load_daily_queue_date_range(
        &mut self,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<()> {
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

    pub(crate) fn load_daily_queue_calendar_range(
        &mut self,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<()> {
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
            if let std::collections::hash_map::Entry::Vacant(entry) =
                self.workspace.schemes.entry(scheme.id)
            {
                entry.insert(scheme);
                self.indexed_workspace = None;
            }
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

    pub(crate) fn commit_event_edit(&mut self, edit: CommitEventEdit) -> Result<()> {
        let CommitEventEdit {
            scheme_id,
            item_id,
            occurrence,
            occurrence_index,
            title,
            occurrence_start,
            occurrence_end,
            draft_start,
            draft_end,
            draft_repeats,
            draft_notification_offset_secs,
            notification_dirty,
            draft_done,
            scope,
        } = edit;
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
        if changeset.workspace {
            self.crdt_state_requires_full_save = true;
            self.dirty_crdt_schemes.clear();
        } else {
            self.dirty_crdt_schemes
                .extend(changeset.schemes.iter().copied());
        }

        // This state is rewritten durably below on every edit. Reuse the exact
        // version we successfully wrote last time instead of parsing a growing
        // JSON queue again; take it so a failed save cannot leave a cache that
        // claims an edit reached disk when it did not.
        let mut sync_state = self
            .sync_state_cache
            .take()
            .unwrap_or_else(|| load_local_sync_state(&self.workspace_path).unwrap_or_default());
        let identity_changed = sync_state.workspace_id != Some(self.workspace.id)
            || sync_state.replica_id != Some(self.settings.replica_id);
        sync_state.workspace_id = Some(self.workspace.id);
        sync_state.replica_id = Some(self.settings.replica_id);

        // A device with no server configured has nowhere to push, and signing in
        // re-seeds every document as a full snapshot straight from the live CRDT
        // state (`queue_account_switch_reseed` / `queue_workspace_bootstrap_updates`).
        // So a queue built while signed out carries nothing sign-in would not
        // rebuild — it only grows, by a full snapshot per touched document, and
        // gets re-serialized on every keystroke. Measured on a never-signed-in
        // simulator: 201 entries / 2.6 MB of `sync-state.json`, +14 KB per edit,
        // and 72 ms per edit spent almost entirely rewriting it.
        //
        // The CRDT documents themselves still record every edit (they persist
        // separately in `sync-crdt-state.json`), so enabling sync later still
        // converges — that invariant is what makes dropping this safe.
        if sync_state.server_url.is_none() {
            let had_queue = !sync_state.pending.is_empty();
            sync_state.pending.clear();
            // Only touch the disk when the file's contents would actually differ.
            if had_queue || identity_changed {
                let saved = save_local_sync_state(&self.workspace_path, &sync_state);
                if saved.is_ok() {
                    self.sync_state_cache = Some(sync_state);
                }
                return saved;
            }
            self.sync_state_cache = Some(sync_state);
            return Ok(());
        }

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
                touched_items: update.touched_items,
            });
        }
        // The queue only drains on a successful push, so a device that cannot
        // push — signed out, offline for a long stretch, or a build with
        // accounts compiled out — otherwise grows it by one entry per edit
        // forever, and re-reads and re-writes the whole file on every later
        // edit. Collapsing a document's backlog into a single full snapshot
        // keeps every edit (it is the same content) while bounding the file, so
        // enabling sync later still converges.
        compact_pending_documents(&mut sync_state, MAX_PENDING_PER_DOCUMENT);
        let saved = save_local_sync_state(&self.workspace_path, &sync_state);
        if saved.is_ok() {
            // Only cache what is actually on disk; a failed write must not leave
            // the next edit building on state no reader would see.
            self.sync_state_cache = Some(sync_state);
        }
        saved
    }

    pub(crate) fn register_push_device(&mut self, client: &MobileSyncHttpClient) {
        let Some(token) = self.push_token.clone() else {
            return;
        };
        let environment = self.push_environment.unwrap_or(PushEnvironment::Production);
        if self.registered_push_token.as_deref() == Some(token.as_str())
            && self.registered_push_environment == Some(environment)
        {
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
            push_environment: Some(environment),
            notification_permission: NotificationPermissionState::default(),
            local_scheduler_supported: Some(true),
        };
        // Device registration is only a best-effort wake-up optimization. It
        // must never hold the core mutex in front of the CRDT pull: on a cold
        // mobile network this request can consume the full HTTP timeout while
        // the UI reports "Resyncing". Mark this token as attempted before
        // spawning so wake storms do not start one request per sync cycle.
        // A new app process retries naturally, and a rotated token clears this
        // marker in `set_push_registration`.
        self.registered_push_token = Some(token);
        self.registered_push_environment = Some(environment);
        let client = client.clone();
        let spawned = std::thread::Builder::new()
            .name("knotq-push-registration".into())
            .spawn(move || {
                if let Err(error) = client.register_device(&request) {
                    // Registration is not part of sync correctness. Keep the
                    // failure visible in debug builds without polluting a
                    // released sync log or turning it into a user-facing error.
                    if cfg!(debug_assertions) {
                        eprintln!("knotq: push-device registration skipped: {error:#}");
                    }
                }
            });
        if spawned.is_err() {
            // Thread creation failure is exceptionally unlikely; leave the
            // optimistic marker in place because retrying synchronously would
            // reintroduce the very startup stall this path avoids.
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

    pub(crate) fn sync_once(
        &mut self,
        api_base: &str,
        bearer_token: &str,
        account_user_id: &str,
    ) -> Result<bool> {
        self.sync_once_with_mode(api_base, bearer_token, account_user_id, false)
    }

    /// A user-requested resync must be a real pull, even if an automatic poll or
    /// silent wake ran moments ago. It deliberately uses HTTP instead of a socket
    /// that may look connected after the app was suspended.
    pub(crate) fn force_sync_once(
        &mut self,
        api_base: &str,
        bearer_token: &str,
        account_user_id: &str,
    ) -> Result<bool> {
        self.sync_once_with_mode(api_base, bearer_token, account_user_id, true)
    }

    fn server_workspace_id(
        &mut self,
        client: &MobileSyncHttpClient,
        persisted_state: &knotq_sync::LocalSyncState,
        account_user_id: &str,
    ) -> Result<WorkspaceId> {
        let cache_is_current = self.account_workspace_cache.as_ref().is_some_and(|cached| {
            cached.api_base == client.api_base
                && cached.bearer_token == client.bearer_token
                && cached.fetched_at.elapsed() < ACCOUNT_WORKSPACE_CACHE_TTL
        });
        if cache_is_current {
            if let Some(cached) = self.account_workspace_cache.as_ref() {
                return Ok(cached.workspace_id);
            }
            return Err(anyhow!("account workspace cache became unavailable"));
        }

        // Access tokens rotate on ordinary refresh, so key this cache by the
        // stable account id as well as the server. An actual account switch
        // misses this guard and still takes the authoritative status path.
        let token_fingerprint = sync_token_fingerprint(&client.bearer_token);
        if persisted_state.server_url.as_deref() == Some(client.api_base.as_str())
            && (persisted_state.account_user_id.as_deref() == Some(account_user_id)
                || persisted_state.account_token_fingerprint.as_deref()
                    == Some(token_fingerprint.as_str()))
        {
            if let Some(workspace_id) = persisted_state.workspace_id {
                self.account_workspace_cache = Some(CachedAccountWorkspace {
                    api_base: client.api_base.clone(),
                    bearer_token: client.bearer_token.clone(),
                    workspace_id,
                    fetched_at: std::time::Instant::now(),
                });
                return Ok(workspace_id);
            }
        }

        let workspace_id = client.account_status()?.workspace_id;
        self.account_workspace_cache = Some(CachedAccountWorkspace {
            api_base: client.api_base.clone(),
            bearer_token: client.bearer_token.clone(),
            workspace_id,
            fetched_at: std::time::Instant::now(),
        });
        Ok(workspace_id)
    }

    fn sync_once_with_mode(
        &mut self,
        api_base: &str,
        bearer_token: &str,
        account_user_id: &str,
        force_remote_pull: bool,
    ) -> Result<bool> {
        let mut prelude_timing = SyncTiming::start();
        // Coalesce wake-storms: a silent push wakes every device on each push, so two
        // devices that re-push on every sync form a feedback loop that barrages the
        // backend. Skip the round-trip when nothing local is queued and we synced
        // moments ago — see `should_coalesce_idle_sync`.
        // The sync path rewrites this file around network I/O; drop the edit
        // path's copy so it cannot go stale behind it.
        self.sync_state_cache = None;
        let persisted_sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
        let has_local_pending = !persisted_sync_state.pending.is_empty();
        prelude_timing.phase("prelude_load_state");
        // A server `changed` nudge over the socket means a peer pushed — always run
        // (and clear the flag) rather than coalescing it away.
        let ws_changed = self
            .ws_changed
            .swap(false, std::sync::atomic::Ordering::SeqCst);
        if !force_remote_pull && !ws_changed && self.should_coalesce_idle_sync(has_local_pending) {
            return Ok(false);
        }
        // Keep the ws reconnect token fresh (the shell hands us the current token).
        if let Ok(mut token) = self.ws_token.lock() {
            *token = bearer_token.to_string();
        }

        let client = MobileSyncHttpClient::with_agent(
            normalize_sync_api_base(api_base)?,
            bearer_token.to_string(),
            self.http_agent.clone(),
        );
        // A timed-out WS request marks its supervisor stopped. Recreate it before
        // selecting the transport so the current cycle can use HTTP safely and the
        // next cycle has a chance to use a fresh socket. This is deliberately after
        // wake coalescing: an idle/coalesced call must not create network work.
        if !force_remote_pull
            && self
                .ws_client
                .as_ref()
                .is_some_and(|client| client.is_stopped())
        {
            self.stop_ws_sync();
            self.start_ws_sync(api_base, bearer_token);
        }
        // Batched pull/push prefer the live socket and fall back to HTTP; aux calls
        // (account status, device register, media) always use the HTTP `client`.
        // Clone the Arc into a local so the transport doesn't borrow `self` (which is
        // mutated below).
        let ws_client = self.ws_client.clone();
        let transport = if force_remote_pull {
            crate::ws_sync::FallbackTransport::http_only(&client)
        } else {
            crate::ws_sync::FallbackTransport::new(ws_client.as_deref(), &client)
        };
        // The account this bearer token belongs to owns the one canonical
        // personal-workspace document id; always adopt it. The previous shortcut
        // ("if sync.id == id we're already canonicalized, reuse it") only proved
        // the workspace was bound to *some* account — signing into a different one
        // (e.g. prod -> sandbox) left the old id in place and wedged every pull
        // with a document-id mismatch.
        let server_workspace_id =
            self.server_workspace_id(&client, &persisted_sync_state, account_user_id)?;
        prelude_timing.phase("prelude_account_status");
        let (_local_workspace_repair_needed, local_workspace_changed) = self
            .workspace
            .canonicalize_personal_sync_identity_with_change(server_workspace_id);
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
        let account_switched = reidentified_workspace.is_some();

        let prior_account_user_id = persisted_sync_state.account_user_id.clone();
        let mut sync_state = persisted_sync_state;
        // One-time recovery: repair only the documents the local CRDT store is
        // missing. The earlier wedge could advance a cursor past an off-window
        // Daily Queue document, but re-pulling every already-owned document made
        // cold startup needlessly expensive. Existing bytes are retained and all
        // ordinary server sequence changes still arrive through the normal pull.
        sync_state
            .heal_for_recovery_version_targeted(&self.workspace, &self.crdt.known_document_ids());
        // Signing into a different account/server than the persisted cursors were
        // built against must not reuse the previous account's pull/push cursors: a
        // stale cursor silently skips pulling the new account's lower document
        // sequences and makes the bootstrap push a bare delta the new server has no
        // base for (crdt_schema_invalid). Reset them so the next sync re-pulls from
        // zero and re-seeds full snapshots (idempotent in Yjs).
        let account_identity_changed = prior_account_user_id.as_deref() != Some(account_user_id)
            && prior_account_user_id.is_some();
        if account_identity_changed
            || sync_state.reset_for_account_change(self.workspace.id, &client.api_base)
        {
            // A new account/server has a different document universe. Treat its
            // first pull like a fresh startup so the integrity proof covers the
            // newly adopted base, while later websocket wakes remain cursor-only.
            self.startup_integrity_check_pending = true;
        }
        sync_state.workspace_id = Some(self.workspace.id);
        sync_state.replica_id = Some(self.settings.replica_id);
        sync_state.server_url = Some(client.api_base.clone());
        sync_state.account_token_fingerprint = Some(sync_token_fingerprint(bearer_token));
        sync_state.account_user_id = Some(account_user_id.to_string());

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
                touched_items: update.touched_items,
            });
        }

        // Leave a durable breadcrumb until the entire cycle, including the
        // post-push repair pull and media persistence, has completed. If the app
        // is killed in the middle, the next launch performs the expensive proof;
        // clean launches remain cursor-only.
        sync_state.sync_in_progress = true;
        save_local_sync_state(&self.workspace_path, &sync_state)?;
        prelude_timing.phase("prelude_mark_in_progress");

        // Register this device (with its push token, if any) so the backend can
        // wake it via silent push. Best effort — never block sync on it.
        self.register_push_device(&client);
        prelude_timing.phase("prelude_register_device");

        let push_local_edits_first =
            !force_remote_pull && !ws_changed && has_local_pending && !account_identity_changed;
        let result = self.run_sync_cycle_with_options(
            &transport,
            &mut sync_state,
            server_workspace_id,
            SyncCycleOptions {
                account_switched,
                prelude_workspace_changed: local_workspace_changed,
                media_client: Some(&client),
                push_local_edits_first,
            },
        );
        prelude_timing.phase("prelude_run_sync_cycle");
        if result.is_ok() {
            // Only coalesce future wake-ups after this cycle really completed.
            // A failed account lookup, pull, or push must remain eligible for
            // the next retry rather than being mistaken for a recent sync.
            self.last_remote_sync_at = Some(std::time::Instant::now());
        }
        result
    }

    /// The transport-agnostic core of a sync cycle: pull + merge + workspace
    /// repair + account-switch reseed + bootstrap + durable save + push (with a
    /// single `document_epoch_stale` retry) + cursor persistence, then media.
    ///
    /// [`Self::sync_once`] runs this straight after its HTTP-only prelude
    /// (account-status lookup, identity canonicalization, wake coalescing). The
    /// disk-backed sync fuzz drives this exact method with an in-memory
    /// transport, so the fuzz exercises the production sync path rather than a
    /// re-implementation of it. `media_client` is `None` when there is no media
    /// transport (the fuzz) and media transfer is then skipped.
    ///
    /// Returns whether anything changed (a remote update landed, a workspace was
    /// repaired, something was pushed, or media moved).
    pub(crate) fn run_sync_cycle_with_options(
        &mut self,
        transport: &dyn knotq_sync::SyncTransport,
        sync_state: &mut knotq_sync::LocalSyncState,
        server_workspace_id: knotq_model::WorkspaceId,
        options: SyncCycleOptions<'_>,
    ) -> Result<bool> {
        let SyncCycleOptions {
            account_switched,
            prelude_workspace_changed,
            media_client,
            push_local_edits_first,
        } = options;
        let mut timing = SyncTiming::start();
        // One batched pull syncs the whole workspace: the server returns the current
        // merged state of every document past our cursor (and any document created
        // on another device). Applying merged state is idempotent in Yjs.
        let workspace = self.workspace.clone();
        let run_startup_integrity_check = self.startup_integrity_check_pending;
        // Older installs may have the recovery marker but no vector cache. Fill
        // that cache lazily here, rather than during `open`, so clean launches
        // never pay to inspect cold Daily Queue histories. The persisted-update
        // metadata path does not materialize deferred Yjs documents.
        let startup_proof_eligible = run_startup_integrity_check && sync_state.pending.is_empty();
        if startup_proof_eligible {
            let known_documents = self.crdt.known_document_ids();
            let cache_complete = !sync_state.integrity_state_vectors.is_empty()
                && known_documents
                    .iter()
                    .all(|document| sync_state.integrity_state_vectors.contains_key(document));
            if !cache_complete {
                for (document, state_vector_v1) in self.crdt.persisted_state_vectors_v1() {
                    sync_state
                        .integrity_state_vectors
                        .entry(document)
                        .or_insert_with(|| {
                            base64::engine::general_purpose::STANDARD.encode(state_vector_v1)
                        });
                }
            }
        }
        let use_persisted_integrity_vectors =
            startup_proof_eligible && !sync_state.integrity_state_vectors.is_empty();
        let persisted_integrity_vectors =
            use_persisted_integrity_vectors.then(|| sync_state.integrity_state_vectors.clone());
        timing.phase("integrity_prepare");
        let pull = if push_local_edits_first && !sync_state.pending.is_empty() {
            // A local CRDT update can be merged safely without first fetching
            // the server head. The post-push pull below still receives every
            // peer document past its cursor, while avoiding one round-trip on
            // every debounced keystroke. Stale squashed epochs remain protected
            // by the typed push rejection and its bounded adoption retry.
            PullOutcome {
                workspace,
                remote_updates_applied: 0,
                pull_requests: 0,
                remote_documents_received: 0,
                remote_delta_documents: 0,
                remote_state_bytes: 0,
                remote_latest: sync_state
                    .document_cursors
                    .values()
                    .map(|cursor| (cursor.document, cursor.last_pulled_sequence))
                    .collect(),
                changed_documents: HashSet::new(),
                skipped: Vec::new(),
            }
        } else {
            batch_pull_and_apply_with_persisted_integrity_vectors(
                transport,
                &mut self.crdt,
                sync_state,
                workspace,
                self.settings.replica_id,
                run_startup_integrity_check,
                persisted_integrity_vectors.as_ref(),
            )?
        };
        if pull.remote_updates_applied > 0 {
            self.notification_schedule_cache = None;
        }
        self.deferred_materialization_pending
            .extend(sync_state.deferred_materialization_pending.iter().copied());
        if timing.enabled {
            eprintln!(
                "  sync: pull_result requests={} documents={} deltas={} state_bytes={} applied={} changed={} skipped={} cursors={} pending={}",
                pull.pull_requests,
                pull.remote_documents_received,
                pull.remote_delta_documents,
                pull.remote_state_bytes,
                pull.remote_updates_applied,
                pull.changed_documents.len(),
                pull.skipped.len(),
                sync_state.document_cursors.len(),
                sync_state.pending.len(),
            );
        }
        timing.phase("pull_and_apply");
        // A successful pull has completed the one expensive startup proof. Keep
        // ordinary websocket nudges cursor-based; local edits request their own
        // proof after the push below.
        if !run_startup_integrity_check || sync_state.pending.is_empty() {
            self.startup_integrity_check_pending = false;
        }
        // Log skipped documents (per-document errors that did not block the pull).
        for skipped in &pull.skipped {
            if !skipped.unknown_scheme_document && !skipped.deferred {
                eprintln!(
                    "sync: skipped document {}: {}",
                    skipped.document, skipped.reason
                );
            }
        }
        let mut remote_updates_applied = pull.remote_updates_applied;
        // Scope the durable save to documents whose Yjs state actually changed.
        // The pull is batched, but a one-document remote edit must not turn into
        // a rewrite of every scheme file and every CRDT state on disk.
        let pull_changed_documents = pull.changed_documents.clone();
        let changed_scheme_ids: HashSet<SchemeId> = pull
            .workspace
            .scheme_sync
            .iter()
            .filter_map(|(scheme_id, meta)| {
                pull_changed_documents
                    .contains(&meta.id)
                    .then_some(*scheme_id)
            })
            .collect();
        self.dirty_schemes
            .extend(changed_scheme_ids.iter().copied());
        self.dirty_crdt_schemes
            .extend(changed_scheme_ids.iter().copied());
        if pull_changed_documents.contains(&pull.workspace.sync.id) {
            // The incremental CRDT writer intentionally handles scheme documents
            // only; a changed workspace-index document requires the full writer
            // so its own state is persisted too.
            self.crdt_state_requires_full_save = true;
        }
        self.workspace = pull.workspace;
        if self.daily_recovery_pending {
            let repaired = self
                .crdt
                .materialized_workspace_for_diagnostics(&self.workspace)?;
            if repaired != self.workspace {
                self.workspace = repaired;
            }
            self.daily_recovery_pending = false;
            self.save_workspace()?;
        }
        let (repaired_identity, repaired_identity_changed) = self
            .workspace
            .canonicalize_personal_sync_identity_with_change(server_workspace_id);
        let repaired_folders = self.workspace.normalize_one_level_folders();
        let repaired_markers = self.workspace.normalize_item_markers();
        let repaired_workspace_changed = repaired_identity || repaired_folders || repaired_markers;
        let repaired_workspace_persist_changed =
            repaired_identity_changed || repaired_folders || repaired_markers;
        if repaired_workspace_changed {
            self.notification_schedule_cache = None;
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
                        touched_items: update.touched_items,
                    });
                }
            }
        }
        timing.phase("workspace_repair");
        if account_switched {
            // Defer scheme reseeding until the destination account's workspace
            // index has been pulled. A pre-pull reseed can leave source-only scheme
            // documents pending after the destination index removes them, producing
            // an avoidable schema-invalid orphan push.
            queue_account_switch_reseed(
                sync_state,
                &self.crdt,
                &self.workspace,
                self.settings.replica_id,
                &HashSet::new(),
            );
            self.next_sequence = sync_state
                .pending
                .iter()
                .map(|edit| edit.local_sequence)
                .max()
                .unwrap_or(0)
                + 1;
        }
        timing.phase("account_reseed");

        // A read-only remote pull cannot create a new local media asset. Avoid
        // walking and hashing the entire workspace on that path; local edits
        // and bootstrap pushes are handled by the post-push retry below.
        if let Some(client) = media_client.filter(|_| !sync_state.pending.is_empty()) {
            let pending_documents: HashSet<knotq_model::DocumentId> = sync_state
                .pending
                .iter()
                .map(|edit| edit.document)
                .collect();
            mobile_upload_local_media_assets_for_documents(
                client,
                sync_state,
                &self.workspace,
                &self.image_assets_dir,
                &pull.remote_latest,
                Some(&pending_documents),
            )?;
        }
        timing.phase("media_upload");

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
            sync_state,
            &mut self.crdt,
            &self.workspace,
            self.settings.replica_id,
            &pull.remote_latest,
        );
        for document in &healed_documents {
            eprintln!("mobile sync: repopulated schema-less CRDT document {document}");
        }
        timing.phase("bootstrap");
        if remote_updates_applied > 0
            || prelude_workspace_changed
            || repaired_workspace_persist_changed
            || !healed_documents.is_empty()
        {
            self.save_workspace()?;
        }
        timing.phase("workspace_persist");

        // The recovery cache is derived from raw persisted update metadata, so
        // it does not require hydrating every cold history. On ordinary pulls,
        // refresh only documents whose CRDT state changed in this cycle.
        if !pull_changed_documents.is_empty() {
            self.refresh_persisted_integrity_vectors(sync_state, Some(&pull_changed_documents));
        }

        // The risky pairing is now durable: the merged CRDT/workspace and the
        // pull cursors are both on disk. Persist that cursor checkpoint before
        // entering push/media work, then disarm recovery. If the process dies
        // before the push, pending edits remain queued and the old cursor
        // checkpoint simply causes a harmless idempotent re-pull. If it dies
        // after the push, the normal pending-queue retry is sufficient; a
        // workspace-wide integrity proof is not.
        sync_state.sync_in_progress = false;
        save_local_sync_state(&self.workspace_path, sync_state)?;

        // Persist pull cursors, dropped orphans, and per-document push acks even
        // if the push below fails partway, so a transient push error never forces
        // the next sync to re-download every document from sequence zero. The merged
        // workspace above is already durable, so the cursor never runs ahead of it.
        let mut pushed = Vec::new();
        let background_refresh_required = self.background_refresh_required;
        let notification_schedule = if sync_state.pending.is_empty() {
            None
        } else {
            // Notification scheduling is only part of a push request. A
            // caught-up startup/wakeup has no pending edits, so avoid traversing
            // every visible item just to build data that will never be sent.
            // Reuse the metadata for ordinary prose edits; the cache is cleared
            // by local schedule-affecting commands and remote CRDT merges.
            let now = Utc::now();
            if let Some(cached) = self
                .notification_schedule_cache
                .clone()
                .filter(|cached| cached.window_start.date_naive() == now.date_naive())
            {
                Some(cached)
            } else {
                let schedule = mobile_notification_schedule_snapshot(
                    &self.workspace,
                    self.settings.notification_defaults,
                    now,
                    0,
                )?;
                self.notification_schedule_cache = Some(schedule.clone());
                Some(schedule)
            }
        };
        let mut push_result = match notification_schedule.as_ref() {
            Some(notification_schedule) => batch_push_pending(
                transport,
                sync_state,
                self.settings.replica_id,
                notification_schedule,
                background_refresh_required,
                &mut pushed,
                &mut self.crdt,
                &self.workspace,
            ),
            None => Ok(()),
        };
        // A `document_epoch_stale` rejection means some document was squashed
        // (history replaced, epoch bumped) since this run's pull. One bounded
        // re-pull adopts the squashed state and re-expresses the pending edits
        // against it, after which the push succeeds — mirroring the desktop
        // scheduler's single epoch retry.
        if push_result.as_ref().err().is_some_and(|err| {
            err.downcast_ref::<knotq_sync::SyncPushEpochStale>()
                .is_some()
        }) {
            eprintln!(
                "mobile sync: push hit a stale document epoch; re-pulling to adopt and retrying"
            );
            let adoption = batch_pull_and_apply_with_integrity_check(
                transport,
                &mut self.crdt,
                sync_state,
                self.workspace.clone(),
                self.settings.replica_id,
                false,
            )?;
            remote_updates_applied += adoption.remote_updates_applied;
            self.workspace = adoption.workspace;
            self.save_workspace()?;
            let Some(notification_schedule) = notification_schedule.as_ref() else {
                return Err(anyhow!(
                    "stale push retry requested without a notification schedule"
                ));
            };
            push_result = batch_push_pending(
                transport,
                sync_state,
                self.settings.replica_id,
                notification_schedule,
                background_refresh_required,
                &mut pushed,
                &mut self.crdt,
                &self.workspace,
            );
        }
        timing.phase("push");
        save_local_sync_state(&self.workspace_path, sync_state)?;
        push_result?;
        self.background_refresh_required = false;

        // Local edits have now been accepted (or the push returned an error above).
        // Re-run the one-shot integrity pull only after an actual push, so a
        // mismatch caused by our own pending daily edit cannot trigger a re-pull
        // first. At this point there is no pending local edit for an accepted
        // document; any remaining mismatch is therefore resolved from the
        // server's state, including deferred off-window dailies. On an ordinary
        // caught-up startup/wakeup there is no reason to issue a second empty
        // pull: the first pull already advanced the durable cursors.
        if !pushed.is_empty() {
            let pushed_documents: HashSet<knotq_model::DocumentId> =
                pushed.iter().map(|document| document.document).collect();
            // The push response includes the exact server sequence reached by
            // each accepted document. Start the proof pull at those heads so a
            // local edit does not immediately download its own full merged state
            // again. This state is deliberately a clone: if the proof pull fails,
            // the durable state keeps the old cursors and the next cycle retries
            // safely. If a concurrent device pushed after our response, the proof
            // still catches it because the server head or state vector differs.
            let mut post_push_sync_state = sync_state.clone();
            if !push_local_edits_first {
                for pushed_document in &pushed {
                    post_push_sync_state.advance_pushed_server_sequence(
                        pushed_document.document,
                        pushed_document.kind,
                        pushed_document.server_sequence,
                    );
                }
            }
            let post_push_pull = batch_pull_and_apply_with_integrity_documents(
                transport,
                &mut self.crdt,
                &mut post_push_sync_state,
                self.workspace.clone(),
                self.settings.replica_id,
                true,
                Some(&pushed_documents),
            )?;
            let mut proof_documents = pushed_documents.clone();
            proof_documents.extend(post_push_pull.changed_documents.iter().copied());
            remote_updates_applied += post_push_pull.remote_updates_applied;
            if post_push_pull.remote_updates_applied > 0 {
                self.notification_schedule_cache = None;
                let changed_scheme_ids: HashSet<SchemeId> = post_push_pull
                    .workspace
                    .scheme_sync
                    .iter()
                    .filter_map(|(scheme_id, meta)| {
                        post_push_pull
                            .changed_documents
                            .contains(&meta.id)
                            .then_some(*scheme_id)
                    })
                    .collect();
                self.dirty_schemes
                    .extend(changed_scheme_ids.iter().copied());
                self.dirty_crdt_schemes
                    .extend(changed_scheme_ids.iter().copied());
                if post_push_pull
                    .changed_documents
                    .contains(&post_push_pull.workspace.sync.id)
                {
                    self.crdt_state_requires_full_save = true;
                }
                self.workspace = post_push_pull.workspace;
                self.save_workspace()?;
            }
            *sync_state = post_push_sync_state;
            self.refresh_persisted_integrity_vectors(sync_state, Some(&proof_documents));
            save_local_sync_state(&self.workspace_path, sync_state)?;
        }
        timing.phase("post_push_repair");

        if let Some(client) = media_client {
            // Retry media after the CRDT push using a head map that treats newly
            // pushed documents as present, so successful pre-push uploads are not
            // re-sent but skipped or changed local assets still get uploaded.
            let mut media_remote_latest = pull.remote_latest;
            for pushed_document in &pushed {
                media_remote_latest
                    .entry(pushed_document.document)
                    .or_insert(1);
            }
            let mut media_documents: HashSet<knotq_model::DocumentId> =
                pushed.iter().map(|document| document.document).collect();
            media_documents.extend(sync_state.pending.iter().map(|edit| edit.document));
            if !media_documents.is_empty() {
                mobile_upload_local_media_assets_for_documents(
                    client,
                    sync_state,
                    &self.workspace,
                    &self.image_assets_dir,
                    &media_remote_latest,
                    Some(&media_documents),
                )?;
            }
            save_local_sync_state(&self.workspace_path, sync_state)?;
            // Missing-media discovery is a retry/backstop and can walk every
            // scheme plus its image metadata. A local text edit does not make
            // an unrelated asset newly available, so avoid repeating that
            // workspace scan on every keystroke. A remote CRDT change triggers
            // it immediately; otherwise the interval guarantees a failed
            // download is retried without making the hot path unbounded.
            let now = Utc::now();
            let media_reconciliation_due =
                sync_state.last_media_reconciliation_at.is_none_or(|last| {
                    now.signed_duration_since(last)
                        .to_std()
                        .is_ok_and(|elapsed| elapsed >= MEDIA_RECONCILIATION_INTERVAL)
                });
            if remote_updates_applied > 0 || !pushed.is_empty() || media_reconciliation_due {
                // Missing media is a repair/backstop, not sync correctness. Do
                // not hold the core mutex while serially fetching images (each
                // request has a 30s timeout); mark the attempt durably and let a
                // small worker do the I/O after the CRDT cycle can report done.
                sync_state.last_media_reconciliation_at = Some(now);
                save_local_sync_state(&self.workspace_path, sync_state)?;
                let client = client.clone();
                let workspace = self.workspace.clone();
                let image_assets_dir = self.image_assets_dir.clone();
                let spawned = std::thread::Builder::new()
                    .name("knotq-media-reconciliation".into())
                    .spawn(move || {
                        let started = std::time::Instant::now();
                        let result = mobile_download_missing_media_assets(
                            &client,
                            &workspace,
                            &image_assets_dir,
                        );
                        if cfg!(debug_assertions) {
                            match result {
                                Ok(downloaded) => eprintln!(
                                    "  sync: background media reconciliation downloaded={} {}ms",
                                    downloaded,
                                    started.elapsed().as_millis()
                                ),
                                Err(error) => eprintln!(
                                    "knotq: background media reconciliation failed after {}ms: {error:#}",
                                    started.elapsed().as_millis()
                                ),
                            }
                        }
                    });
                if spawned.is_err() {
                    // The durable timestamp prevents a thread-creation failure
                    // from blocking this sync; the interval retry will try again.
                }
            }
        }
        timing.phase("media");

        Ok(remote_updates_applied > 0 || repaired_workspace_changed || !pushed.is_empty())
    }

    /// Update the durable startup-proof cache without touching unrelated CRDT
    /// documents. `None` is reserved for compatibility callers that need every
    /// persisted document; deferred documents use raw update metadata.
    fn refresh_persisted_integrity_vectors(
        &mut self,
        sync_state: &mut knotq_sync::LocalSyncState,
        documents: Option<&HashSet<knotq_model::DocumentId>>,
    ) {
        let vectors = documents
            .map(|documents| self.crdt.state_vectors_v1_for_documents(documents))
            .unwrap_or_else(|| self.crdt.persisted_state_vectors_v1());
        for (document, state_vector_v1) in vectors {
            sync_state.integrity_state_vectors.insert(
                document,
                base64::engine::general_purpose::STANDARD.encode(state_vector_v1),
            );
        }
    }

    /// Returns the queue's scheme id and whether this call had to create it.
    /// Callers use the flag to skip a whole-workspace save on the (overwhelmingly
    /// common) path where the queue already existed — every launch calls this,
    /// and an unconditional save costs a full scheme-file + index + CRDT-state
    /// write before the first frame.
    pub(crate) fn ensure_daily_queue(&mut self, date: NaiveDate) -> Result<(SchemeId, bool)> {
        if let Some(id) = self.load_daily_queue_scheme_if_needed(date)? {
            return Ok((id, false));
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
        self.notification_schedule_cache = None;
        self.record_crdt_changes(
            WorkspaceCrdtChangeSet::default()
                .workspace()
                .touch_scheme(id),
        )?;
        Ok((id, true))
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

    /// Initial link + import driven by a platform-issued access token.
    ///
    /// The Android counterpart of [`Self::complete_google_calendar_import`]:
    /// there is no authorization code to exchange because Google Identity
    /// already did the granting, so this goes straight to resolving the account
    /// and importing its calendars.
    pub(crate) fn import_google_calendars_with_identity(
        &mut self,
        identity: MobileGoogleIdentityAccount,
        parent: FolderId,
    ) -> Result<MobileGoogleSyncResult> {
        let sources = google_calendar::google_calendar_sources(&self.workspace);
        let result = google_calendar::run_google_calendar_import_with_identity(&identity, sources)?;
        self.finish_google_calendar_sync(result, true, parent)
    }

    pub(crate) fn sync_google_calendars(&mut self) -> Result<MobileGoogleSyncResult> {
        self.sync_google_calendars_with_identities(Vec::new())
    }

    /// Periodic/manual sync of every linked account.
    ///
    /// `identities` carries freshly minted access tokens for the accounts whose
    /// tokens the core cannot renew itself (Android's platform-identity
    /// accounts). Each one is matched to its stored account and swapped in
    /// before the sync runs; accounts with no matching entry fall back to
    /// whatever they already hold, which is exactly right for the desktop-style
    /// refresh-token accounts iOS still uses.
    pub(crate) fn sync_google_calendars_with_identities(
        &mut self,
        identities: Vec<MobileGoogleIdentityAccount>,
    ) -> Result<MobileGoogleSyncResult> {
        if self.settings.google_accounts.is_empty() {
            return Ok(MobileGoogleSyncResult {
                imported_count: 0,
                synced_count: 0,
                failure_count: 0,
                message: knotq_l10n::t("google.sync.no_account").to_string(),
            });
        }
        let mut accounts = self.settings.google_accounts.clone();
        for identity in &identities {
            apply_google_identity_token(&mut accounts, identity);
        }
        let sources = google_calendar::google_calendar_sources(&self.workspace);
        let result = google_calendar::run_google_calendar_background_sync(accounts, sources)?;
        self.finish_google_calendar_sync(result, false, self.workspace.root)
    }

    /// Flags (or clears) an account's reconnect state from the shell.
    ///
    /// Android calls this when Google Identity refuses to renew authorization
    /// without user interaction, so the UI can offer an explicit reconnect
    /// instead of every background sync failing quietly.
    pub(crate) fn set_google_account_needs_reauth(
        &mut self,
        account_id: &str,
        needs_reauth: bool,
    ) -> Result<()> {
        let Some(account) = self
            .settings
            .google_accounts
            .iter_mut()
            .find(|account| account.account_id == account_id)
        else {
            return Ok(());
        };
        if account.needs_reauth == needs_reauth {
            return Ok(());
        }
        account.needs_reauth = needs_reauth;
        self.save_settings()
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
            self.notification_schedule_cache = None;
            self.workspace.normalize_one_level_folders();
            self.workspace.normalize_item_markers();
            self.record_crdt_changes(applied.changes)?;
            self.save_workspace()?;
        }

        let failure_count = result.failures.len() as i32;
        let message = if result.failures.is_empty() {
            if synced_count == 0 {
                knotq_l10n::t("google.sync.up_to_date").to_string()
            } else if applied.created_count > 0 {
                knotq_l10n::t_count("google.sync.imported_count", applied.created_count as i64)
            } else {
                knotq_l10n::t_count("google.sync.synced_count", synced_count as i64)
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

    pub(crate) fn upsert_google_accounts(
        &mut self,
        accounts: Vec<knotq_model::GoogleOAuthAccount>,
    ) -> bool {
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
                    email: account.email.clone().unwrap_or_default(),
                    needs_reauth: account.needs_reauth,
                }
            })
            .collect()
    }

    pub(crate) fn google_calendar_scheme_count_for_account(
        &self,
        account: &GoogleOAuthAccount,
    ) -> usize {
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
            // An import that was archived (by hand, or as a duplicate) still owns
            // this calendar: bring it back rather than minting a second scheme
            // for it, which is what made the calendar count climb on reconnect.
            let archived_scheme_id = if create_missing && existing_scheme_id.is_none() {
                google_calendar::archived_google_calendar_scheme_id(
                    &self.workspace,
                    &calendar.account_id,
                    &calendar.calendar_id,
                )
            } else {
                None
            };
            if let Some(scheme_id) = archived_scheme_id {
                self.restore_deleted_scheme(scheme_id)?;
                changes.workspace = true;
                changes.schemes.insert(scheme_id);
                content_changed = true;
                created_count += 1;
            }

            let scheme_id = match existing_scheme_id.or(archived_scheme_id) {
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
            let should_update_name = existing_scheme_id.is_none() && archived_scheme_id.is_none();
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

/// Swaps a freshly minted platform access token into the matching stored
/// account. Matching is by account id first, then by email, so an account
/// linked before the identity flow existed still picks up its new token.
fn apply_google_identity_token(
    accounts: &mut [knotq_model::GoogleOAuthAccount],
    identity: &MobileGoogleIdentityAccount,
) {
    let access_token = identity.access_token.trim();
    if access_token.is_empty() {
        return;
    }
    let email = identity
        .email
        .as_deref()
        .map(str::trim)
        .filter(|email| !email.is_empty());
    let account_id = identity
        .account_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty());
    let Some(account) = accounts.iter_mut().find(|account| {
        account_id.is_some_and(|id| account.account_id == id)
            || email.is_some_and(|email| {
                account
                    .email
                    .as_deref()
                    .is_some_and(|stored| stored.eq_ignore_ascii_case(email))
            })
    }) else {
        return;
    };

    account.access_token = access_token.to_string();
    account.token_source = knotq_model::GoogleTokenSource::PlatformIdentity;
    account.expires_at = Some(google_calendar::platform_token_expiry(
        identity.expires_in_secs,
    ));
    if let Some(scope) = identity
        .scope
        .as_deref()
        .map(str::trim)
        .filter(|scope| !scope.is_empty())
    {
        account.scope = scope.to_string();
    }
    if let Some(email) = email {
        account.email = Some(email.to_string());
    }
}
