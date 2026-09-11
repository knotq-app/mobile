use super::*;
use crate::tests_daily::MobileFuzzServer;
use knotq_model::{DocumentId, NodeRef, ReplicaId, SyncDocumentKind};
use knotq_sync::{
    BatchPullRequest, BatchPullResponse, BatchPushRequest, BatchPushResponse, DocumentSyncCursor,
    LocalSyncState, SyncTransport,
};
use std::collections::HashMap;

/// A caught-up server: it deliberately returns no documents. This is the exact
/// response that used to leave a device with current pull cursors but a stale
/// materialized workspace permanently claiming it was synced.
pub(crate) struct EmptyPullTransport;

impl SyncTransport for EmptyPullTransport {
    fn pull(&self, _request: &BatchPullRequest) -> anyhow::Result<BatchPullResponse> {
        Ok(BatchPullResponse::default())
    }

    fn push(&self, _request: &BatchPushRequest) -> anyhow::Result<BatchPushResponse> {
        Ok(BatchPushResponse::default())
    }
}

/// A single recorded server response whose request cursors must match exactly.
/// This keeps the disk-backed lazy-Daily regression honest: the final pull is
/// genuinely caught up, not an artificial local repair trigger.
pub(crate) struct ExpectedPullTransport {
    pub(crate) expected_cursors: HashMap<DocumentId, u64>,
    pub(crate) response: BatchPullResponse,
}

impl SyncTransport for ExpectedPullTransport {
    fn pull(&self, request: &BatchPullRequest) -> anyhow::Result<BatchPullResponse> {
        assert_eq!(
            request.cursors, self.expected_cursors,
            "test transport received unexpected pull cursors"
        );
        Ok(self.response.clone())
    }

    fn push(&self, _request: &BatchPushRequest) -> anyhow::Result<BatchPushResponse> {
        Ok(BatchPushResponse::default())
    }
}

#[test]
fn startup_integrity_proof_is_reserved_for_interrupted_syncs() {
    let dir = std::env::temp_dir().join(format!(
        "knotq-mobile-startup-integrity-marker-{}",
        uuid::Uuid::new_v4()
    ));
    let workspace_path = dir.join("workspace").join("workspace.json");

    let clean = LocalSyncState::default();
    save_local_sync_state(&workspace_path, &clean).expect("save clean sync marker");
    let clean_open = MobileCoreInner::open(dir.clone()).expect("open clean core");
    assert!(!clean_open.startup_integrity_check_pending);

    let interrupted = LocalSyncState {
        sync_in_progress: true,
        ..LocalSyncState::default()
    };
    save_local_sync_state(&workspace_path, &interrupted).expect("save interrupted marker");
    let interrupted_open = MobileCoreInner::open(dir.clone()).expect("reopen interrupted core");
    assert!(interrupted_open.startup_integrity_check_pending);

    let _ = std::fs::remove_dir_all(dir);
}

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
            epoch: 0,
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
        touched_items: Vec::new(),
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
        touched_items: Vec::new(),
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

/// Snapshot, month view, and search share a cached index between reads, but a
/// local write must never let that cache hide newly-created content.
#[test]
fn cached_index_is_invalidated_by_a_local_write() {
    let dir = std::env::temp_dir().join(format!("knotq-index-cache-test-{}", uuid::Uuid::new_v4()));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

    core.snapshot(Some("2026-05-26".to_string()), 0)
        .expect("initial snapshot builds index");
    assert!(core.inner.lock().unwrap().indexed_workspace.is_some());

    core.create_scheme(None, "Cache Freshness".to_string(), Some(1), None)
        .expect("create scheme");
    assert!(
        core.inner.lock().unwrap().indexed_workspace.is_none(),
        "a durable write must invalidate the read cache"
    );

    let hits = core.search("Cache Freshness".to_string()).expect("search");
    assert!(hits.iter().any(|hit| hit.title == "Cache Freshness"));
    assert!(core.inner.lock().unwrap().indexed_workspace.is_some());

    let _ = std::fs::remove_dir_all(dir);
}

/// A token can survive an APNs environment change (for example switching the
/// same debug install between sandbox and production credentials). The
/// registration dedupe marker must include both values or the backend keeps
/// sending through the stale environment.
#[cfg(feature = "accounts")]
#[test]
fn push_registration_environment_change_forces_reregistration() {
    let dir = std::env::temp_dir().join(format!(
        "knotq-push-registration-environment-test-{}",
        uuid::Uuid::new_v4()
    ));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
    core.set_push_registration("stable-token".to_string(), "sandbox".to_string())
        .expect("set sandbox registration");
    {
        let mut inner = core.inner.lock().expect("lock mobile core");
        inner.registered_push_token = Some("stable-token".to_string());
        inner.registered_push_environment = Some(PushEnvironment::Sandbox);
    }

    // Reapplying the same token/environment is a no-op for the dedupe marker.
    core.set_push_registration("stable-token".to_string(), "sandbox".to_string())
        .expect("reapply sandbox registration");
    {
        let inner = core.inner.lock().expect("lock mobile core");
        assert_eq!(inner.registered_push_token.as_deref(), Some("stable-token"));
        assert_eq!(
            inner.registered_push_environment,
            Some(PushEnvironment::Sandbox)
        );
    }

    // The token is unchanged, but the environment is not: force the next sync
    // to send the updated registration.
    core.set_push_registration("stable-token".to_string(), "production".to_string())
        .expect("switch to production registration");
    {
        let inner = core.inner.lock().expect("lock mobile core");
        assert!(inner.registered_push_token.is_none());
        assert!(inner.registered_push_environment.is_none());
        assert_eq!(inner.push_environment, Some(PushEnvironment::Production));
    }

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn stderr_capture_rotation_keeps_log_bounded() {
    assert!(!stderr_capture_would_exceed(
        0,
        MAX_STDERR_CAPTURE_BYTES as usize
    ));
    assert!(stderr_capture_would_exceed(
        1,
        MAX_STDERR_CAPTURE_BYTES as usize
    ));
    assert!(stderr_capture_would_exceed(MAX_STDERR_CAPTURE_BYTES, 1));
    assert!(!stderr_capture_would_exceed(4 * 1024 * 1024, 4096));
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

    // Retention is not permanent: re-complete it, then backdate the retention
    // timestamp past the TTL — as if the completion happened over an hour ago —
    // and the row ages off the panel.
    core.toggle_occurrence(
        occ.scheme_id.clone(),
        occ.item_id.clone(),
        occ.occurrence_json.clone(),
    )
    .expect("re-complete");
    let key = CalendarOccurrenceKey {
        scheme_id: crate::parsing::parse_id(&occ.scheme_id).unwrap(),
        item_id: crate::parsing::parse_id(&occ.item_id).unwrap(),
        occurrence: serde_json::from_str(&occ.occurrence_json).unwrap(),
    };
    {
        let mut inner = core.inner.lock().unwrap();
        assert!(
            inner.retained_completed.contains(&key),
            "sanity: the re-completion was retained"
        );
        let stale =
            Utc::now() - chrono::Duration::seconds(knotq_state::RETAINED_COMPLETED_TTL_SECS + 60);
        inner.retained_completed.insert(key, stale);
    }
    let overdue = core.snapshot(None, 0).unwrap().calendar.overdue;
    assert!(
        !overdue.iter().any(|occ| occ.title == "Old essay"),
        "an hour after completion the row no longer holds its place"
    );

    let _ = std::fs::remove_dir_all(dir);
}

fn mobile_sync_cycle(inner: &mut MobileCoreInner, server: &MobileFuzzServer) -> anyhow::Result<()> {
    inner.sync_state_cache = None;
    let mut sync_state = load_local_sync_state(&inner.workspace_path).unwrap_or_default();
    let server_workspace_id = sync_state.workspace_id.unwrap_or(inner.workspace.id);
    let push_local_edits_first = !sync_state.pending.is_empty();
    let pulls_before = *server.pull_calls.borrow();
    inner.run_sync_cycle_with_options(
        server,
        &mut sync_state,
        server_workspace_id,
        SyncCycleOptions {
            account_switched: false,
            prelude_workspace_changed: false,
            media_client: None,
            push_local_edits_first,
        },
    )?;
    if push_local_edits_first {
        let pulls = *server.pull_calls.borrow() - pulls_before;
        assert!(
            pulls <= 1,
            "local edit fast path used {pulls} pull requests instead of one post-push pull"
        );
    }
    inner.sync_state_cache = None;
    Ok(())
}

/// Append one line to a scheme through the CRDT/sync layers exactly as an edit
/// command does: mutate the in-memory items, record the change (which queues a
/// pending CRDT edit), and persist.
fn append_line(inner: &mut MobileCoreInner, scheme_id: SchemeId, text: &str) -> anyhow::Result<()> {
    inner
        .workspace
        .schemes
        .get_mut(&scheme_id)
        .expect("scheme is loaded")
        .items
        .push(Item::new(text.to_string()));
    inner.record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(scheme_id))?;
    inner.save_workspace()?;
    Ok(())
}

#[test]
fn completing_a_past_event_flags_background_refresh_then_clears_it_after_push() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-bgrefresh-{}", uuid::Uuid::new_v4()));
    let workspace_path = dir.join("workspace").join("workspace.json");

    // One ordinary scheme with an event that already ended.
    let mut initial = Workspace::new();
    let mut scheme = Scheme::new("Work", 0);
    let start = chrono::Utc::now() - chrono::Duration::hours(3);
    let end = start + chrono::Duration::hours(1);
    let event = Item::new("Standup").with_start(start).with_end(end);
    let item_id = event.id;
    scheme.items.push(event);
    let scheme_id = scheme.id;
    initial
        .folders
        .get_mut(&initial.root)
        .unwrap()
        .children
        .push(NodeRef::Scheme(scheme_id));
    initial.schemes.insert(scheme_id, scheme);
    initial.canonicalize_personal_sync_identity(initial.id);
    initial.ensure_sync_metadata();

    let seed_crdt = WorkspaceCrdtDocuments::try_new(&initial).unwrap();
    let seed_states = seed_crdt.document_states();
    let server = MobileFuzzServer::seeded(&initial, &seed_states);

    let replica_id = ReplicaId::new();
    let mut sync_state = LocalSyncState {
        workspace_id: Some(initial.id),
        replica_id: Some(replica_id),
        server_url: Some("http://fuzz.local".to_string()),
        ..LocalSyncState::default()
    };
    for document in seed_states.keys() {
        sync_state.document_cursors.insert(
            *document,
            DocumentSyncCursor {
                document: *document,
                kind: if *document == initial.sync.id {
                    SyncDocumentKind::PersonalWorkspace
                } else {
                    SyncDocumentKind::Scheme
                },
                last_pulled_sequence: 1,
                last_pushed_sequence: 1,
                epoch: 0,
            },
        );
    }
    save_workspace(&workspace_path, &initial).unwrap();
    save_crdt_state(&workspace_path, &seed_states).unwrap();
    save_local_sync_state(&workspace_path, &sync_state).unwrap();

    let mut dev = MobileCoreInner::open(dir.clone()).unwrap();
    dev.settings.replica_id = replica_id;

    // A plain text edit must not flag a background refresh.
    append_line(&mut dev, scheme_id, "notes line").unwrap();
    assert!(!dev.background_refresh_required);
    mobile_sync_cycle(&mut dev, &server).unwrap();
    assert_eq!(
        server.push_background_refresh.borrow().last().copied(),
        Some(false),
        "a prose edit pushes without the offline-peer wake flag"
    );

    // Completing the already-ended event: the pushed notification hash won't
    // change (it's outside the upcoming window), so the flag is what tells the
    // backend to wake offline peers to cancel the banner + redraw the widget.
    let occurrence_json = serde_json::to_string(&OccurrenceId::Single).unwrap();
    let occurrence: OccurrenceId = serde_json::from_str(&occurrence_json).unwrap();
    dev.apply(Command::ToggleOccurrence {
        scheme: scheme_id,
        item: item_id,
        occurrence,
    })
    .unwrap();
    assert!(dev.background_refresh_required);

    mobile_sync_cycle(&mut dev, &server).unwrap();
    assert_eq!(
        server.push_background_refresh.borrow().last().copied(),
        Some(true),
        "completing a past event carries background_refresh_required on the push"
    );
    assert!(
        !dev.background_refresh_required,
        "the flag is cleared once the push that carried it succeeds"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn two_device_lazy_daily_lifecycle_fuzz_converges() {
    // Two real, disk-backed `MobileCoreInner` instances ("two laptops") on one
    // account, syncing through an in-memory backend that merges exactly as the
    // Worker does. Each seed mixes the operations that were reported as buggy:
    // concurrent edits to ordinary schemes AND lazy dailies, restarts, caught-up
    // syncs, historical renders, new dailies around calendar boundaries, and a
    // malformed off-window daily file that must recover from CRDT. After the run
    // both devices must converge on identical content for every scheme.
    let seeds = std::env::var("KNOTQ_FUZZ_SEEDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(12_u64);
    let steps = std::env::var("KNOTQ_FUZZ_STEPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(48_u64);

    for seed in 0..seeds {
        let root = std::env::temp_dir().join(format!(
            "knotq-mobile-2dev-fuzz-{seed}-{}",
            uuid::Uuid::new_v4()
        ));
        let dir_a = root.join("a");
        let dir_b = root.join("b");
        let today = default_today();

        // Off-window dailies (deferred at cold open) + in-window dailies +
        // ordinary schemes.
        let off_window_dates: Vec<NaiveDate> = (0..3)
            .map(|i| today - chrono::Duration::days(70 + i * 11 + seed as i64))
            .collect();
        let in_window_date = today - chrono::Duration::days(1);

        let mut initial = Workspace::new();
        for date in off_window_dates.iter().copied().chain([in_window_date]) {
            let id = daily_queue_scheme_id(date);
            let mut daily = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
            daily.id = id;
            daily
                .items
                .push(Item::new(format!("seed {seed} {date} base")));
            initial.daily_queue.insert(date, id);
            initial.schemes.insert(id, daily);
        }
        let mut ordinary_ids = Vec::new();
        for index in 0..2u8 {
            let mut scheme = Scheme::new(format!("seed {seed} ordinary {index}"), index);
            scheme
                .items
                .push(Item::new(format!("seed {seed} ordinary {index} base")));
            let id = scheme.id;
            initial
                .folders
                .get_mut(&initial.root)
                .unwrap()
                .children
                .push(NodeRef::Scheme(id));
            initial.schemes.insert(id, scheme);
            ordinary_ids.push(id);
        }
        // A real device's workspace document id is derived from the workspace id
        // (`sync_once` canonicalizes it on the first sync). Do it here too, so
        // `run_sync_cycle`'s canonicalize is a no-op and the CRDT state keyed on
        // disk stays addressable across restarts.
        initial.canonicalize_personal_sync_identity(initial.id);
        initial.ensure_sync_metadata();

        let seed_crdt = WorkspaceCrdtDocuments::try_new(&initial).unwrap();
        let seed_states = seed_crdt.document_states();
        let server = MobileFuzzServer::seeded(&initial, &seed_states);

        // Seed both device dirs identically; each device keeps its own replica id.
        let mut replica_ids = HashMap::new();
        for dir in [&dir_a, &dir_b] {
            let workspace_path = dir.join("workspace").join("workspace.json");
            let replica_id = ReplicaId::new();
            replica_ids.insert(dir.clone(), replica_id);
            let mut sync_state = LocalSyncState {
                workspace_id: Some(initial.id),
                replica_id: Some(replica_id),
                server_url: Some("http://fuzz.local".to_string()),
                ..LocalSyncState::default()
            };
            for document in seed_states.keys() {
                sync_state.document_cursors.insert(
                    *document,
                    DocumentSyncCursor {
                        document: *document,
                        kind: if *document == initial.sync.id {
                            SyncDocumentKind::PersonalWorkspace
                        } else {
                            SyncDocumentKind::Scheme
                        },
                        last_pulled_sequence: 1,
                        last_pushed_sequence: 1,
                        epoch: 0,
                    },
                );
            }
            save_workspace(&workspace_path, &initial).unwrap();
            save_crdt_state(&workspace_path, &seed_states).unwrap();
            save_local_sync_state(&workspace_path, &sync_state).unwrap();
        }

        // Force each device's stored replica id (open() would mint a fresh one).
        let mut dev_a = MobileCoreInner::open(dir_a.clone()).unwrap();
        dev_a.settings.replica_id = replica_ids[&dir_a];
        let mut dev_b = MobileCoreInner::open(dir_b.clone()).unwrap();
        dev_b.settings.replica_id = replica_ids[&dir_b];

        let mut random = seed.wrapping_add(0xa24b_af09_31c2_77d1);
        let next_rand = |random: &mut u64| {
            *random ^= *random << 13;
            *random ^= *random >> 7;
            *random ^= *random << 17;
            *random
        };

        for step in 0..steps {
            let roll = next_rand(&mut random);
            let on_a = roll & 1 == 0;
            let (dir, dev, other) = if on_a {
                (&dir_a, &mut dev_a, "a")
            } else {
                (&dir_b, &mut dev_b, "b")
            };
            let _ = other;

            if std::env::var("KNOTQ_FUZZ_TRACE").is_ok() {
                eprintln!(
                    "seed {seed} step {step}: dev {other} op {}",
                    (roll >> 1) % 9
                );
            }
            match (roll >> 1) % 9 {
                // Edit an ordinary scheme, then sync.
                0 | 1 => {
                    let id = ordinary_ids[((roll >> 8) as usize) % ordinary_ids.len()];
                    append_line(
                        dev,
                        id,
                        &format!("seed {seed} step {step} {}", if on_a { "a" } else { "b" }),
                    )
                    .unwrap();
                    mobile_sync_cycle(dev, &server)
                        .unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
                }
                // Edit an in-window daily (loaded), then sync.
                2 => {
                    let _ = dev.snapshot(today, 0, 5);
                    let id = daily_queue_scheme_id(in_window_date);
                    if dev.workspace.schemes.contains_key(&id) {
                        append_line(dev, id, &format!("seed {seed} step {step} daily")).unwrap();
                        mobile_sync_cycle(dev, &server)
                            .unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
                    }
                }
                // Load an off-window daily, edit it, then sync.
                3 => {
                    let date = off_window_dates[((roll >> 8) as usize) % off_window_dates.len()];
                    let _ = dev.snapshot(today, 0, 120);
                    let id = daily_queue_scheme_id(date);
                    if dev.workspace.schemes.contains_key(&id) {
                        append_line(dev, id, &format!("seed {seed} step {step} old-daily"))
                            .unwrap();
                        mobile_sync_cycle(dev, &server)
                            .unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
                    }
                }
                // Plain sync (propagates the peer's edits).
                4 | 5 => mobile_sync_cycle(dev, &server).unwrap(),
                // Restart.
                6 => {
                    dev.save_workspace().unwrap();
                    let replica_id = dev.settings.replica_id;
                    let reopened = MobileCoreInner::open(dir.clone()).unwrap();
                    if on_a {
                        dev_a = reopened;
                        dev_a.settings.replica_id = replica_id;
                    } else {
                        dev_b = reopened;
                        dev_b.settings.replica_id = replica_id;
                    }
                }
                // Historical render — must stay harmless.
                7 => {
                    let _ = dev.snapshot(today, 0, 120);
                }
                // Malformed off-window daily file: corrupt, restart, navigate
                // (recoverable error), sync -> recovered from CRDT.
                _ => {
                    let date = off_window_dates[((roll >> 12) as usize) % off_window_dates.len()];
                    let id = daily_queue_scheme_id(date);
                    dev.save_workspace().unwrap();
                    let scheme_path = dir
                        .join("workspace")
                        .join("schemes")
                        .join(format!("{id}.knotq"));
                    if scheme_path.exists() {
                        let clean = std::fs::read(&scheme_path).unwrap();
                        let damaged = match (roll >> 20) % 3 {
                            0 => clean[..clean.len() / 2].to_vec(),
                            1 => b"<scheme><item>bad".to_vec(),
                            _ => vec![0xff, 0xfe, b'<'],
                        };
                        std::fs::write(&scheme_path, damaged).unwrap();
                        let replica_id = dev.settings.replica_id;
                        let mut reopened = MobileCoreInner::open(dir.clone()).unwrap();
                        reopened.settings.replica_id = replica_id;
                        // Navigating to the corrupted date surfaces a recoverable
                        // error and schedules CRDT recovery for that one date.
                        let _ = reopened.snapshot(today, 0, 120);
                        mobile_sync_cycle(&mut reopened, &server).unwrap();
                        // The repaired file now reads.
                        reopened.snapshot(today, 0, 120).unwrap_or_else(|error| {
                            panic!("seed {seed} step {step}: daily recovery failed: {error}")
                        });
                        if on_a {
                            dev_a = reopened;
                        } else {
                            dev_b = reopened;
                        }
                    }
                }
            }
        }

        // Settle: sync both devices to a fixed point.
        for _ in 0..6 {
            mobile_sync_cycle(&mut dev_a, &server).unwrap();
            mobile_sync_cycle(&mut dev_b, &server).unwrap();
        }

        let server_ws = server.workspace.borrow().clone();
        let mat_a = dev_a
            .crdt
            .materialized_workspace_for_diagnostics(&dev_a.workspace)
            .unwrap();
        let mat_b = dev_b
            .crdt
            .materialized_workspace_for_diagnostics(&dev_b.workspace)
            .unwrap();

        let scheme_ids: Vec<SchemeId> = server_ws.scheme_sync.keys().copied().collect();
        for id in scheme_ids {
            let a = mat_a.schemes.get(&id).map(|s| item_texts(&s.items));
            let b = mat_b.schemes.get(&id).map(|s| item_texts(&s.items));
            assert_eq!(
                a, b,
                "seed {seed}: devices diverged on scheme {id}\n  a={a:?}\n  b={b:?}"
            );
        }
        let _ = std::fs::remove_dir_all(root);
    }
}

fn item_texts(items: &[Item]) -> Vec<String> {
    items.iter().map(|item| item.text().to_string()).collect()
}

/// Two real `MobileCoreInner` devices syncing over the REAL WebSocket
/// (`start_ws_sync` -> tungstenite -> Durable Object) against a live
/// `wrangler dev` backend, driving the production `run_sync_cycle`. This is the
/// one seam the in-memory fuzz can't reach: mobile's own `ws_client` lifecycle
/// and the `FallbackTransport` WS path.
///
/// Skips (does not fail) unless `KNOTQ_SYNC_BACKEND_URL` is set — see
/// `local/run-sync-integration.sh`.
#[test]
fn mobile_two_device_convergence_over_real_websocket() {
    let Ok(base_url) = std::env::var("KNOTQ_SYNC_BACKEND_URL") else {
        eprintln!("[mobile ws] KNOTQ_SYNC_BACKEND_URL not set — skipping");
        return;
    };
    let base_url = base_url.trim_end_matches('/').to_string();
    let email = format!("mobile-ws-{}@test.knotq", uuid::Uuid::new_v4());

    let bootstrap = |label: &str| -> (String, knotq_model::WorkspaceId) {
        let resp: serde_json::Value = ureq::post(&format!("{base_url}/__test/bootstrap"))
            .set("content-type", "application/json")
            .send_json(serde_json::json!({ "email": email }))
            .unwrap_or_else(|e| panic!("bootstrap {label}: {e}"))
            .into_json()
            .expect("bootstrap json");
        let token = resp["bearer_token"].as_str().expect("token").to_string();
        let ws_id: knotq_model::WorkspaceId = resp["workspace_id"]
            .as_str()
            .expect("ws id")
            .parse()
            .expect("uuid");
        (token, ws_id)
    };
    let (token_a, ws_id) = bootstrap("A");
    let (token_b, ws_id_b) = bootstrap("B");
    assert_eq!(ws_id, ws_id_b, "both devices share the workspace");

    // Seed a disk-backed device whose workspace is already canonicalized to the
    // server's id (a fresh device's `sync_once` prelude does this before the
    // core cycle; the cycle itself does not re-identify).
    let seed_device = |token: &str| -> (PathBuf, MobileCoreInner) {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-ws-{}", uuid::Uuid::new_v4()));
        let workspace_path = dir.join("workspace").join("workspace.json");
        let mut workspace = make_default_workspace();
        workspace.canonicalize_personal_sync_identity(ws_id);
        workspace.ensure_sync_metadata();
        let replica_id = ReplicaId::new();
        let sync_state = LocalSyncState {
            workspace_id: Some(ws_id),
            replica_id: Some(replica_id),
            server_url: Some(base_url.clone()),
            ..LocalSyncState::default()
        };
        save_workspace(&workspace_path, &workspace).unwrap();
        save_crdt_state(
            &workspace_path,
            &WorkspaceCrdtDocuments::try_new(&workspace)
                .unwrap()
                .document_states(),
        )
        .unwrap();
        save_local_sync_state(&workspace_path, &sync_state).unwrap();
        let mut inner = MobileCoreInner::open(dir.clone()).unwrap();
        inner.settings.replica_id = replica_id;
        inner.start_ws_sync(&base_url, token);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < deadline && !inner.is_ws_connected() {
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        assert!(inner.is_ws_connected(), "device WS never connected");
        (dir, inner)
    };

    let ws_sync = |inner: &mut MobileCoreInner, token: &str| {
        inner.sync_state_cache = None;
        let mut sync_state = load_local_sync_state(&inner.workspace_path).unwrap_or_default();
        let http = crate::media_sync::MobileSyncHttpClient::with_agent(
            base_url.clone(),
            token.to_string(),
            ureq::Agent::new(),
        );
        let ws = inner.ws_client.clone();
        let transport = crate::ws_sync::FallbackTransport::new(ws.as_deref(), &http);
        inner
            .run_sync_cycle_with_options(
                &transport,
                &mut sync_state,
                ws_id,
                SyncCycleOptions {
                    account_switched: false,
                    prelude_workspace_changed: false,
                    media_client: Some(&http),
                    push_local_edits_first: false,
                },
            )
            .expect("ws run_sync_cycle");
        inner.sync_state_cache = None;
    };

    let (dir_a, mut dev_a) = seed_device(&token_a);
    let (dir_b, mut dev_b) = seed_device(&token_b);

    // A creates content and pushes over the socket.
    let scheme_id = {
        let mut scheme = Scheme::new("WS mobile plan", 1);
        scheme.items.push(Item::new("alpha"));
        let id = scheme.id;
        dev_a
            .workspace
            .folders
            .get_mut(&dev_a.workspace.root)
            .unwrap()
            .children
            .push(NodeRef::Scheme(id));
        dev_a.workspace.schemes.insert(id, scheme);
        dev_a
            .record_crdt_changes(
                WorkspaceCrdtChangeSet::default()
                    .workspace()
                    .touch_scheme(id),
            )
            .unwrap();
        dev_a.save_workspace().unwrap();
        id
    };
    ws_sync(&mut dev_a, &token_a);

    // B pulls over the socket and must see it; then B edits and A converges.
    ws_sync(&mut dev_b, &token_b);
    assert!(
        dev_b.workspace.schemes.contains_key(&scheme_id),
        "device B discovered the scheme over the websocket"
    );
    dev_b
        .workspace
        .schemes
        .get_mut(&scheme_id)
        .unwrap()
        .items
        .push(Item::new("beta from B"));
    dev_b
        .record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(scheme_id))
        .unwrap();
    dev_b.save_workspace().unwrap();
    ws_sync(&mut dev_b, &token_b);
    ws_sync(&mut dev_a, &token_a);

    let texts_a = item_texts(&dev_a.workspace.schemes[&scheme_id].items);
    let texts_b = item_texts(&dev_b.workspace.schemes[&scheme_id].items);
    assert_eq!(
        texts_a, texts_b,
        "devices converged over the real websocket"
    );
    assert!(texts_a.contains(&"alpha".to_string()));
    assert!(texts_a.contains(&"beta from B".to_string()));

    dev_a.stop_ws_sync();
    dev_b.stop_ws_sync();
    let _ = std::fs::remove_dir_all(dir_a);
    let _ = std::fs::remove_dir_all(dir_b);
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
fn failed_sync_does_not_throttle_the_next_retry() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let mut inner = MobileCoreInner::open(dir.clone()).expect("open mobile core");

    // An invalid API base fails before any network work. A failed prelude must
    // not look like a recent successful sync to the wake coalescer.
    assert!(inner.sync_once("not a URL", "token", "user").is_err());
    assert!(inner.last_remote_sync_at.is_none());

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
