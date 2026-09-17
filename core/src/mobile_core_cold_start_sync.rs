//! A lock-free pull for the one sync that matters most for "does the app feel
//! stuck": the very first pull this device ever runs, typically right after a
//! fresh install or sign-in, when the whole point is downloading an existing
//! account's content onto a new device -- the slowest, highest-latency pull
//! there is, and the one most likely to overlap with the user immediately
//! trying to do something (e.g. create a scheme) while it's still in flight.
//!
//! Every other sync trigger (routine polls, websocket wakes, a manual pull-to-
//! refresh once cursors exist) keeps running through the ordinary, fully
//! locked `MobileCoreInner::sync_once`/`run_sync_cycle_with_options` path,
//! completely unchanged: `MobileCore::sync_once` only takes the lock-free path
//! when [`MobileCoreInner::try_prepare_cold_start_pull`] finds this device has
//! never completed a pull. That keeps the change's blast radius to exactly the
//! scenario it targets.
//!
//! # Why the CRDT-merge approach, not a resumable pull loop
//!
//! `batch_pull_and_apply`'s multi-page loop (materialization-gap budgets,
//! epoch adoption, deferred-document handling) is some of the most
//! carefully-tuned, bug-history-laden code in this crate. Rather than
//! surgically inserting an unlock point into it (high risk of a transcription
//! error in logic that has fixed several "stuck on Resyncing" livelocks
//! before), this runs that function COMPLETELY UNCHANGED -- just against an
//! owned, empty `WorkspaceCrdtDocuments` clone instead of the live one, with
//! no lock held at all during the call. The clone's result is then folded
//! into live state as an ordinary CRDT merge (`apply_remote_updates`) --
//! exactly the same operation two independently-syncing devices already rely
//! on to converge, which is the thing this whole crate is fuzzed hardest to
//! get right.
//!
//! # Why cursors are the only `LocalSyncState` field this needs to reconcile
//!
//! `apply(Command)` (the path `create_scheme` and every other edit command
//! goes through) only ever touches `LocalSyncState::pending` (queueing the new
//! edit) and the identity fields `workspace_id`/`replica_id` (set idempotently
//! to values a concurrent pull would compute identically) -- see
//! `MobileCoreInner::record_crdt_changes`. It never touches
//! `document_cursors`, `deferred_materialization_pending`, or
//! `unlanded_pulls`; those are pull-owned. `finish_cold_start_pull` therefore
//! re-reads the CURRENT on-disk state (preserving whatever a concurrent edit
//! queued) and overwrites ONLY those three pull-owned fields with the values
//! the lock-free pull produced. If a future edit path ever starts writing one
//! of those fields too, the worst case here is a stale cursor that a later,
//! ordinary sync cycle corrects -- not a lost edit.

use super::*;
use knotq_sync::StoredCrdtUpdate;
use std::collections::HashSet;

/// Everything the unlocked network phase of a cold-start pull needs, gathered
/// while the core lock is still held. Every field is an owned value (a clone
/// or an `Arc` clone) so the caller can drop the lock before using any of
/// this.
pub(crate) struct ColdStartPullPrelude {
    pub(crate) transport_client: MobileSyncHttpClient,
    pub(crate) ws_client: Option<std::sync::Arc<knotq_sync::ws::WsClient>>,
    pub(crate) replica_id: knotq_model::ReplicaId,
    /// The workspace as it stood when this prelude was prepared. Used only to
    /// interpret the pull's own response (scheme-index bindings, deferred
    /// classification) -- NOT reused as the merge target, since by the time
    /// the result is folded back the live workspace may have moved on.
    pub(crate) workspace_snapshot: knotq_model::Workspace,
    pub(crate) sync_state_snapshot: knotq_sync::LocalSyncState,
}

impl MobileCoreInner {
    /// Locked, fast, no network: decide whether this call qualifies for the
    /// lock-free cold-start pull and, if so, gather everything its network
    /// phase needs as owned values.
    ///
    /// Eligibility is "this device has never completed a pull"
    /// (`sync_state.document_cursors.is_empty()`), not "the CRDT is
    /// unseeded": a local-only edit (e.g. starter content created before the
    /// user ever signs in) already seeds the CRDT's workspace-index document
    /// via `record_crdt_changes`, well before any network sync runs, so that
    /// check would never fire in the exact scenario this exists for. An empty
    /// cursor set is untouched by local edits and stays a reliable "never
    /// synced" signal regardless of local content.
    pub(crate) fn try_prepare_cold_start_pull(
        &mut self,
        api_base: &str,
        bearer_token: &str,
    ) -> Result<Option<ColdStartPullPrelude>> {
        // The edit path rewrites sync-state.json around network I/O; drop the
        // cache so it cannot go stale behind this call, mirroring
        // `sync_once_with_mode`'s own prelude.
        self.sync_state_cache = None;
        let sync_state = load_local_sync_state(&self.workspace_path).unwrap_or_default();
        if !sync_state.document_cursors.is_empty() {
            return Ok(None);
        }
        let client = MobileSyncHttpClient::with_agent(
            normalize_sync_api_base(api_base)?,
            bearer_token.to_string(),
            self.http_agent.clone(),
        );
        // Leave the durable "a sync was in flight" breadcrumb BEFORE any
        // network I/O runs unlocked, matching `sync_once_with_mode`'s
        // prelude: a crash during the pull must still arm the next launch's
        // recovery proof.
        let mut breadcrumbed = sync_state.clone();
        breadcrumbed.sync_in_progress = true;
        save_local_sync_state(&self.workspace_path, &breadcrumbed)?;
        Ok(Some(ColdStartPullPrelude {
            transport_client: client,
            ws_client: self.ws_client.clone(),
            replica_id: self.settings.replica_id,
            workspace_snapshot: self.workspace.clone(),
            sync_state_snapshot: sync_state,
        }))
    }

    /// Locked, fast, no network: fold a lock-free cold-start pull's result
    /// into live state.
    ///
    /// Safe regardless of what a concurrent `apply(Command)` did to
    /// `self.crdt` / `self.workspace` / `sync-state.json` while this ran
    /// unlocked: the CRDT side is an ordinary, commutative Yjs merge, and the
    /// `LocalSyncState` side overwrites only the fields the pull owns (see
    /// the module doc comment) rather than replacing the file wholesale.
    pub(crate) fn finish_cold_start_pull(
        &mut self,
        server_workspace_id: knotq_model::WorkspaceId,
        pulled_crdt: &WorkspaceCrdtDocuments,
        pulled_sync_state: &knotq_sync::LocalSyncState,
        changed_documents: &HashSet<knotq_model::DocumentId>,
        resolved_account_workspace: CachedAccountWorkspace,
    ) -> Result<()> {
        // The account-status lookup that resolved `server_workspace_id` ran
        // unlocked too (this device has never synced, so it is always a real
        // network call, never a cache hit). Store its result now so the
        // ordinary `sync_once` call this feeds into does not immediately pay
        // for a second, redundant account-status round trip.
        self.account_workspace_cache = Some(resolved_account_workspace);

        // The live workspace/CRDT were never canonicalized to the server's id
        // (that only happened on the throwaway clone the unlocked pull used) --
        // `try_prepare_cold_start_pull` runs before `server_workspace_id` is
        // even known. Do it now, exactly like `sync_once_with_mode`'s prelude
        // does for the ordinary path. `reidentify_workspace_document` re-keys
        // the LIVE workspace-index document (preserving its content, which by
        // now may include a scheme a concurrent `apply(Command)` added under
        // the old identity) and hands back that content as an update this
        // device must still push -- exactly like the ordinary path's own
        // "workspace re-identified" handling.
        self.workspace
            .canonicalize_personal_sync_identity_with_change(server_workspace_id);
        self.workspace.ensure_sync_metadata();
        let reidentified_workspace = self
            .crdt
            .reidentify_workspace_document(self.workspace.sync.id)?;

        if !changed_documents.is_empty() {
            let snapshot = pulled_crdt.full_snapshot_updates_for_documents(changed_documents);
            let updates: Vec<StoredCrdtUpdate> = snapshot
                .updates
                .into_iter()
                .map(|update| StoredCrdtUpdate {
                    workspace_id: self.workspace.id,
                    document: update.document,
                    kind: update.kind,
                    replica_id: self.settings.replica_id,
                    sequence: 0,
                    received_at: Utc::now(),
                    update_v1: update.update_v1,
                })
                .collect();
            // The live workspace is read fresh here (not the prelude's
            // snapshot): a concurrent `create_scheme` may have added a scheme
            // to it while this ran unlocked, and `apply_remote_updates`
            // specifically protects locally-created-but-not-yet-synced
            // content against being treated as a remote deletion.
            let outcome = self.crdt.apply_remote_updates(&self.workspace, &updates);
            if !outcome.workspace_is_ok() {
                return Err(anyhow!(
                    "cold-start pull merge failed: {:?}",
                    outcome
                        .workspace_errors
                        .iter()
                        .map(|error| error.message.as_str())
                        .collect::<Vec<_>>()
                ));
            }
            self.workspace = outcome.workspace;
            self.notification_schedule_cache = None;
        }
        let mut live = self
            .sync_state_cache
            .take()
            .unwrap_or_else(|| load_local_sync_state(&self.workspace_path).unwrap_or_default());
        live.document_cursors = pulled_sync_state.document_cursors.clone();
        live.deferred_materialization_pending =
            pulled_sync_state.deferred_materialization_pending.clone();
        live.unlanded_pulls = pulled_sync_state.unlanded_pulls.clone();
        if let Some(update) = reidentified_workspace {
            let local_sequence = self.next_sequence;
            self.next_sequence += 1;
            live.push_pending(PendingCrdtEdit {
                operation_id: OperationId::new(),
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
        save_local_sync_state(&self.workspace_path, &live)?;
        self.sync_state_cache = Some(live);
        Ok(())
    }
}
