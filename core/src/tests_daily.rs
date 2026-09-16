use super::*;
use crate::tests::{EmptyPullTransport, ExpectedPullTransport};
use knotq_model::{DocumentId, ReplicaId, SyncDocumentKind};
use knotq_sync::{
    BatchPullRequest, BatchPullResponse, BatchPushRequest, BatchPushResponse, DocumentSyncCursor,
    LocalSyncState, PulledCrdtDocument, PushedCrdtDocument, StoredCrdtUpdate, SyncPushRejected,
    SyncTransport,
};
use std::cell::RefCell;
use std::collections::HashMap;

// Deferred Daily Queue loading, recovery, and restart stress tests live here.
// Keep these expensive, disk-backed scenarios discoverable separately from the
// ordinary sync/account unit cases.

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
fn historical_daily_load_refreshes_search_index_without_decoding_all_history() {
    let dir = std::env::temp_dir().join(format!(
        "knotq-mobile-daily-search-index-{}",
        uuid::Uuid::new_v4()
    ));
    let workspace_path = dir.join("workspace").join("workspace.json");
    let old_date = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
    let current_date = NaiveDate::from_ymd_opt(2026, 5, 26).unwrap();
    let old_id = daily_queue_scheme_id(old_date);
    let mut workspace = Workspace::new();
    let mut old_daily = Scheme::new(daily_queue_scheme_name(old_date), DAILY_QUEUE_COLOR_INDEX);
    old_daily.id = old_id;
    old_daily
        .items
        .push(Item::new("historical indexing sentinel"));
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
    assert!(core
        .search("historical indexing sentinel".to_string())
        .expect("search before history load")
        .is_empty());

    core.snapshot_with_daily_history(Some(current_date.to_string()), 0, 31)
        .expect("load historical daily");
    let hits = core
        .search("historical indexing sentinel".to_string())
        .expect("search after history load");
    let old_id_text = old_id.to_string();
    assert!(hits.iter().any(|hit| {
        hit.target_kind == "daily_queue"
            && hit.scheme_id.as_deref() == Some(old_id_text.as_str())
            && hit.title == "historical indexing sentinel"
    }));

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn cold_restore_and_caught_up_pull_scale_with_visible_dailies_not_history() {
    // A structural (counter-based, not timing) guarantee: cold open and a
    // caught-up pull decode no persisted scheme documents until one is needed.
    // Regressing lazy loading (decoding every scheme on startup, or
    // re-materializing them on every pull) shows up here as a jump in the live
    // count / a drop in the deferred count.
    let dir =
        std::env::temp_dir().join(format!("knotq-mobile-daily-scale-{}", uuid::Uuid::new_v4()));
    let workspace_path = dir.join("workspace").join("workspace.json");
    let today = default_today();

    let historical_daily_count = 60_i64;
    let ordinary_count = 3_usize;
    let mut workspace = Workspace::new();
    for offset in 0..historical_daily_count {
        // Well outside the initial load window.
        let date = today - chrono::Duration::days(40 + offset);
        let id = daily_queue_scheme_id(date);
        let mut daily = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
        daily.id = id;
        daily.items.push(Item::new(format!("history {offset}")));
        workspace.daily_queue.insert(date, id);
        workspace.schemes.insert(id, daily);
    }
    for index in 0..ordinary_count {
        let mut scheme = Scheme::new(format!("ordinary {index}"), index as u8);
        scheme
            .items
            .push(Item::new(format!("ordinary {index} line")));
        let id = scheme.id;
        workspace
            .folders
            .get_mut(&workspace.root)
            .unwrap()
            .children
            .push(NodeRef::Scheme(id));
        workspace.schemes.insert(id, scheme);
    }
    workspace.ensure_sync_metadata();

    let replica_id = ReplicaId::new();
    let crdt = WorkspaceCrdtDocuments::try_new(&workspace).unwrap();
    let states = crdt.document_states();
    let mut sync_state = LocalSyncState {
        workspace_id: Some(workspace.id),
        replica_id: Some(replica_id),
        ..LocalSyncState::default()
    };
    let mut heads = HashMap::new();
    for document in states.keys() {
        heads.insert(*document, 1_u64);
        sync_state.document_cursors.insert(
            *document,
            DocumentSyncCursor {
                document: *document,
                kind: if *document == workspace.sync.id {
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
    save_workspace(&workspace_path, &workspace).unwrap();
    save_crdt_state(&workspace_path, &states).unwrap();
    save_local_sync_state(&workspace_path, &sync_state).unwrap();

    // Cold open: all existing scheme states stay as deferred bytes. The plain
    // workspace is already available to render the UI, so decoding unchanged
    // Yjs history here buys nothing.
    let mut inner = MobileCoreInner::open(dir.clone()).unwrap();
    let population = inner.crdt.document_population();
    assert_eq!(
        population.deferred_schemes,
        (historical_daily_count as usize) + ordinary_count,
        "every persisted scheme must be deferred at cold open"
    );
    assert!(
        population.live_schemes <= ordinary_count + 4,
        "cold open decoded {} live scheme docs for {ordinary_count} ordinary schemes — \
         lazy loading regressed",
        population.live_schemes
    );

    // A caught-up pull must not decode a single additional daily.
    let transport = TestScaleTransport {
        heads: heads.clone(),
    };
    let pull = batch_pull_and_apply(
        &transport,
        &mut inner.crdt,
        &mut sync_state,
        inner.workspace.clone(),
        inner.settings.replica_id,
    )
    .unwrap();
    assert_eq!(
        inner.crdt.document_population(),
        population,
        "a caught-up pull decoded a deferred daily"
    );
    assert!(
        !pull.workspace.schemes.keys().any(|id| inner
            .workspace
            .daily_queue
            .values()
            .any(|d| d == id)
            && !inner.workspace.schemes.contains_key(id)),
        "a caught-up pull eagerly materialized an off-window daily"
    );

    // The bytes for every historical daily are still owned and still persisted.
    let owned = inner.crdt.document_states();
    for id in workspace.daily_queue.values() {
        let document = workspace.scheme_sync[id].id;
        assert!(
            owned.contains_key(&document),
            "deferred daily {id} lost its persisted CRDT bytes"
        );
    }

    let _ = std::fs::remove_dir_all(dir);
}

struct TestScaleTransport {
    heads: HashMap<DocumentId, u64>,
}

impl SyncTransport for TestScaleTransport {
    fn pull(&self, _request: &BatchPullRequest) -> anyhow::Result<BatchPullResponse> {
        Ok(BatchPullResponse {
            known_documents: Some(self.heads.clone()),
            ..BatchPullResponse::default()
        })
    }

    fn push(&self, _request: &BatchPushRequest) -> anyhow::Result<BatchPushResponse> {
        Ok(BatchPushResponse::default())
    }
}

#[test]
fn seeded_disk_fault_fuzz_recovers_lazy_daily_parser_wedges() {
    // This is intentionally disk-backed rather than a white-box mutation of
    // `Workspace`: each seed follows the production sequence that matters:
    // save -> damage an *unloaded* Daily Queue file -> cold-open -> lazy view
    // reports its parse error -> a caught-up/empty sync repairs from durable
    // CRDT bytes -> save -> relaunch and render. The byte faults model partial
    // writes and malformed content, while the date variation exercises the
    // lazy-load boundary itself. Keep every failure reproducible by seed.
    for seed in 0..16_i64 {
        let dir = std::env::temp_dir().join(format!(
            "knotq-mobile-daily-recovery-fuzz-{seed}-{}",
            uuid::Uuid::new_v4()
        ));
        let workspace_path = dir.join("workspace").join("workspace.json");
        let today = default_today();
        // Outside the initial previous-calendar-month window, but reachable by
        // the explicit history view below.
        let date = today - chrono::Duration::days(70 + seed);
        let daily_id = daily_queue_scheme_id(date);
        let mut workspace = Workspace::new();
        let mut daily = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
        daily.id = daily_id;
        daily
            .items
            .push(Item::new(format!("seed {seed}: durable daily content")));
        workspace.daily_queue.insert(date, daily_id);
        workspace.schemes.insert(daily_id, daily);
        workspace.ensure_sync_metadata();
        let replica_id = ReplicaId::new();
        let crdt = WorkspaceCrdtDocuments::try_new(&workspace).expect("seed CRDT");
        let crdt_states = crdt.document_states();
        let mut sync_state = LocalSyncState {
            workspace_id: Some(workspace.id),
            replica_id: Some(replica_id),
            ..LocalSyncState::default()
        };
        for document in crdt_states.keys() {
            sync_state.document_cursors.insert(
                *document,
                DocumentSyncCursor {
                    document: *document,
                    kind: if *document == workspace.sync.id {
                        SyncDocumentKind::PersonalWorkspace
                    } else {
                        SyncDocumentKind::Scheme
                    },
                    last_pulled_sequence: 41,
                    last_pushed_sequence: 41,
                    epoch: 0,
                },
            );
        }
        save_workspace(&workspace_path, &workspace).expect("seed workspace files");
        save_crdt_state(&workspace_path, &crdt_states).expect("seed CRDT files");
        save_local_sync_state(&workspace_path, &sync_state).expect("seed current cursors");

        let scheme_path = dir
            .join("workspace")
            .join("schemes")
            .join(format!("{daily_id}.knotq"));
        let clean = std::fs::read(&scheme_path).expect("read seeded daily file");
        let damaged = match seed % 4 {
            0 => clean[..clean.len() / 2].to_vec(), // interrupted publish
            1 => b"<scheme><item>unclosed".to_vec(), // malformed XML
            2 => vec![0xff, 0xfe, b'<', b'x', b'>'], // invalid UTF-8
            _ => b"<?xml version=\"1.0\"?><scheme><item></scheme".to_vec(),
        };
        std::fs::write(&scheme_path, damaged).expect("inject reproducible disk fault");

        let core = MobileCore::new(dir.display().to_string()).expect("cold open skips lazy date");
        assert!(
            !core
                .inner
                .lock()
                .unwrap()
                .workspace
                .schemes
                .contains_key(&daily_id),
            "seed {seed}: cold open must exercise the lazy-load path"
        );
        // A background save can happen before this day is ever viewed (for
        // example while completing an overdue item). It must preserve the hidden
        // daily document rather than sweeping it out of `sync-crdt-state/`.
        core.inner
            .lock()
            .unwrap()
            .save_workspace()
            .unwrap_or_else(|error| panic!("seed {seed}: save of lazy workspace failed: {error}"));
        let daily_document = workspace.scheme_sync[&daily_id].id;
        assert!(
            load_crdt_state(&workspace_path)
                .expect("read CRDT state after lazy save")
                .contains_key(&daily_document),
            "seed {seed}: lazy daily CRDT state was lost by a normal save"
        );
        assert!(
            core.snapshot_with_daily_history(Some(today.to_string()), 0, 120)
                .is_err(),
            "seed {seed}: navigating to the corrupted date must expose a recoverable parse error"
        );

        {
            let mut inner = core.inner.lock().unwrap();
            let visible_workspace = inner.workspace.clone();
            let replica_id = inner.settings.replica_id;
            let pull = batch_pull_and_apply(
                &EmptyPullTransport,
                &mut inner.crdt,
                &mut sync_state,
                visible_workspace,
                replica_id,
            )
            .expect("seed {seed}: empty pull must re-materialize durable CRDT state");
            assert!(
                pull.remote_updates_applied > 0,
                "seed {seed}: repair must be persisted"
            );
            inner.workspace = pull.workspace;
            inner.save_workspace().expect("persist repaired workspace");
        }
        drop(core);

        let repaired = MobileCore::new(dir.display().to_string()).expect("relaunch repaired core");
        let snapshot = repaired
            .snapshot_with_daily_history(Some(today.to_string()), 0, 120)
            .unwrap_or_else(|error| {
                panic!("seed {seed}: repair survived neither save nor restart: {error}")
            });
        let entry = snapshot
            .daily
            .iter()
            .find(|entry| entry.date == date.to_string())
            .unwrap_or_else(|| panic!("seed {seed}: repaired daily entry is missing"));
        assert_eq!(
            entry.scheme.items[0].text,
            format!("seed {seed}: durable daily content"),
            "seed {seed}: repair recovered the wrong content"
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[test]
fn lazy_daily_remote_update_survives_save_restart_and_caught_up_pull() {
    // This is deliberately not a byte-corruption test. It exercises the normal
    // production boundary: the startup window omits an old Daily Queue from the
    // UI workspace, even though its sync binding and CRDT document are durable.
    // A background save, remote update, and later caught-up pull must never turn
    // that lazy omission into "synced" while the UI workspace lacks the day.
    let dir = std::env::temp_dir().join(format!(
        "knotq-mobile-lazy-daily-sync-{}",
        uuid::Uuid::new_v4()
    ));
    let workspace_path = dir.join("workspace").join("workspace.json");
    let today = default_today();
    let date = today - chrono::Duration::days(70);
    let daily_id = daily_queue_scheme_id(date);

    let mut workspace = Workspace::new();
    let mut daily = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
    daily.id = daily_id;
    daily.items.push(Item::new("before remote update"));
    workspace.daily_queue.insert(date, daily_id);
    workspace.schemes.insert(daily_id, daily);
    workspace.ensure_sync_metadata();

    let replica_id = ReplicaId::new();
    let seed_crdt = WorkspaceCrdtDocuments::try_new(&workspace).expect("seed CRDT");
    let seed_states = seed_crdt.document_states();
    let daily_document = workspace.scheme_sync[&daily_id].id;
    let mut sync_state = LocalSyncState {
        workspace_id: Some(workspace.id),
        replica_id: Some(replica_id),
        ..LocalSyncState::default()
    };
    for document in seed_states.keys() {
        sync_state.document_cursors.insert(
            *document,
            DocumentSyncCursor {
                document: *document,
                kind: if *document == workspace.sync.id {
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
    save_workspace(&workspace_path, &workspace).expect("seed workspace files");
    save_crdt_state(&workspace_path, &seed_states).expect("seed CRDT files");
    save_local_sync_state(&workspace_path, &sync_state).expect("seed current cursors");

    // Build an authentic server-side merged document: restore the original
    // CRDT history, make a normal content change, and use its full state as the
    // pull response. No UI workspace or persisted file is manually altered.
    let mut remote_workspace = workspace.clone();
    remote_workspace
        .schemes
        .get_mut(&daily_id)
        .expect("daily exists")
        .items
        .push(Item::new("remote daily update"));
    let mut remote_crdt =
        WorkspaceCrdtDocuments::from_states(&workspace, ReplicaId::new(), &seed_states)
            .expect("restore remote CRDT");
    let remote_change = remote_crdt.sync_changes(
        &remote_workspace,
        &WorkspaceCrdtChangeSet::default().touch_scheme(daily_id),
    );
    assert!(
        remote_change.errors.is_empty(),
        "remote edit must encode cleanly"
    );
    let remote_daily_state = remote_crdt
        .document_states()
        .remove(&daily_document)
        .expect("remote daily document state")
        .to_vec();

    let heads_after_remote = HashMap::from([(workspace.sync.id, 1_u64), (daily_document, 2_u64)]);

    // A first-ever bootstrap is different from an established cursor pull:
    // the complete remote state is retained without hydrating an off-window
    // daily. Its old plain file must not win when that daily is later opened.
    let bootstrap_dir = std::env::temp_dir().join(format!(
        "knotq-mobile-lazy-daily-bootstrap-{}",
        uuid::Uuid::new_v4()
    ));
    let bootstrap_workspace_path = bootstrap_dir.join("workspace").join("workspace.json");
    save_workspace(&bootstrap_workspace_path, &workspace).expect("seed bootstrap workspace");
    save_crdt_state(&bootstrap_workspace_path, &seed_states).expect("seed bootstrap CRDT");
    let bootstrap_replica = ReplicaId::new();
    let mut bootstrap_state = LocalSyncState {
        workspace_id: Some(workspace.id),
        replica_id: Some(bootstrap_replica),
        ..LocalSyncState::default()
    };
    save_local_sync_state(&bootstrap_workspace_path, &bootstrap_state)
        .expect("seed bootstrap cursors");
    let mut bootstrap_inner = MobileCoreInner::open(bootstrap_dir.clone()).expect("bootstrap open");
    let bootstrap_transport = ExpectedPullTransport {
        expected_cursors: HashMap::new(),
        response: BatchPullResponse {
            documents: vec![PulledCrdtDocument {
                document: daily_document,
                kind: SyncDocumentKind::Scheme,
                seq: 2,
                epoch: 0,
                state_v1: remote_daily_state.clone(),
                state_v1_is_delta: false,
            }],
            known_documents: Some(heads_after_remote.clone()),
            ..BatchPullResponse::default()
        },
    };
    let bootstrap_pull = batch_pull_and_apply(
        &bootstrap_transport,
        &mut bootstrap_inner.crdt,
        &mut bootstrap_state,
        bootstrap_inner.workspace.clone(),
        bootstrap_inner.settings.replica_id,
    )
    .expect("apply bootstrap remote daily");
    assert!(!bootstrap_pull.workspace.schemes.contains_key(&daily_id));
    assert!(
        bootstrap_state
            .deferred_materialization_pending
            .contains(&daily_document),
        "a changed lazy bootstrap daily must be marked for materialization"
    );
    bootstrap_inner.workspace = bootstrap_pull.workspace;
    bootstrap_inner
        .save_workspace()
        .expect("persist bootstrap workspace");
    save_local_sync_state(&bootstrap_workspace_path, &bootstrap_state)
        .expect("persist bootstrap cursors");
    drop(bootstrap_inner);
    let mut bootstrap_restarted =
        MobileCoreInner::open(bootstrap_dir.clone()).expect("bootstrap restart");
    bootstrap_restarted
        .load_daily_queue_scheme_if_needed(date)
        .expect("materialize changed bootstrap daily")
        .expect("changed bootstrap daily exists");
    assert_eq!(
        bootstrap_restarted.workspace.schemes[&daily_id].items.len(),
        2,
        "opening a changed lazy daily must use the remote CRDT, not its stale plain file"
    );
    let _ = std::fs::remove_dir_all(&bootstrap_dir);

    // The cold launch naturally omits the old daily scheme. A normal full save
    // happens before the user ever opens that date (for example, another edit or
    // a background completion). It must retain the hidden CRDT document.
    let mut inner = MobileCoreInner::open(dir.clone()).expect("cold open");
    assert!(inner.workspace.daily_queue.contains_key(&date));
    assert!(
        !inner.workspace.schemes.contains_key(&daily_id),
        "old daily must be omitted by the startup lazy-load window"
    );
    inner
        .save_workspace()
        .expect("normal save of lazy workspace");
    assert!(
        load_crdt_state(&workspace_path)
            .expect("read CRDT after normal save")
            .contains_key(&daily_document),
        "a normal save must not sweep an unloaded daily CRDT document"
    );

    // Pull the remote daily update at cursor 1, then persist exactly as the
    // mobile sync driver does before it stores the advanced cursor.
    let remote_transport = ExpectedPullTransport {
        expected_cursors: HashMap::from([(workspace.sync.id, 1_u64), (daily_document, 1_u64)]),
        response: BatchPullResponse {
            documents: vec![PulledCrdtDocument {
                document: daily_document,
                kind: SyncDocumentKind::Scheme,
                seq: 2,
                epoch: 0,
                state_v1: remote_daily_state,
                state_v1_is_delta: false,
            }],
            known_documents: Some(heads_after_remote.clone()),
            ..BatchPullResponse::default()
        },
    };
    let pull = batch_pull_and_apply(
        &remote_transport,
        &mut inner.crdt,
        &mut sync_state,
        inner.workspace.clone(),
        inner.settings.replica_id,
    )
    .expect("apply remote daily update");
    inner.workspace = pull.workspace;
    inner.save_workspace().expect("persist remote daily update");
    save_local_sync_state(&workspace_path, &sync_state).expect("persist advanced cursor");
    drop(inner);

    // A restart returns to the same normal lazy state: the file exists and is
    // valid (the earlier pull's save rewrote it with the merged remote content),
    // but the UI-facing workspace has not loaded that date yet. The server is
    // now genuinely caught up and returns no documents.
    let mut restarted = MobileCoreInner::open(dir.clone()).expect("restart");
    assert!(
        !restarted.workspace.schemes.contains_key(&daily_id),
        "restart must re-enter the real lazy daily state"
    );
    assert!(
        restarted.crdt.is_deferred(daily_id),
        "the off-window daily is held as undecoded bytes after a restart"
    );
    let caught_up_transport = ExpectedPullTransport {
        expected_cursors: heads_after_remote.clone(),
        response: BatchPullResponse {
            known_documents: Some(heads_after_remote),
            ..BatchPullResponse::default()
        },
    };
    let population_before = restarted.crdt.document_population();
    let caught_up = batch_pull_and_apply(
        &caught_up_transport,
        &mut restarted.crdt,
        &mut sync_state,
        restarted.workspace.clone(),
        restarted.settings.replica_id,
    )
    .expect("caught-up empty pull");
    // The new contract: a caught-up pull does NOT eagerly decode or materialize
    // an off-window daily. It stays lazy, and its durable bytes stay owned.
    assert!(
        !caught_up.workspace.schemes.contains_key(&daily_id),
        "a caught-up pull must leave the off-window daily lazy, not materialize it"
    );
    assert!(
        restarted.crdt.is_deferred(daily_id),
        "a caught-up pull must not decode the off-window daily"
    );
    assert_eq!(
        restarted.crdt.document_population(),
        population_before,
        "a caught-up pull must not move any daily from deferred to live"
    );
    assert!(
        restarted
            .crdt
            .document_states()
            .contains_key(&daily_document),
        "the deferred daily's CRDT bytes survive a caught-up pull unchanged"
    );

    restarted.workspace = caught_up.workspace;
    restarted
        .save_workspace()
        .expect("persist caught-up repair");
    save_local_sync_state(&workspace_path, &sync_state).expect("persist caught-up cursor");
    drop(restarted);

    let repaired = MobileCore::new(dir.display().to_string()).expect("relaunch repaired core");
    let snapshot = repaired
        .snapshot_with_daily_history(Some(today.to_string()), 0, 120)
        .expect("navigate to repaired daily");
    let entry = snapshot
        .daily
        .iter()
        .find(|entry| entry.date == date.to_string())
        .expect("repaired daily visible after relaunch");
    assert!(
        entry
            .scheme
            .items
            .iter()
            .any(|item| item.text == "remote daily update"),
        "remote daily update survives the entire persisted lifecycle"
    );
    let indexed_hits = repaired
        .search("remote daily update".to_string())
        .expect("search indexes the materialized deferred daily");
    let daily_id_string = daily_id.to_string();
    assert!(
        indexed_hits
            .iter()
            .any(|hit| hit.scheme_id.as_deref() == Some(daily_id_string.as_str())),
        "a daily opened after deferred sync must participate in search indexing"
    );

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn seeded_lazy_daily_lifecycle_fuzz_converges_before_navigation() {
    // A stateful, disk-backed fuzz rather than a single regression timeline.
    // Each seed mixes real lifecycle boundaries that previously were treated in
    // isolation: cold opens with lazy daily loading, normal saves, independently
    // authored remote updates, caught-up pulls, restarts, and historical renders.
    // The oracle is deliberately pre-navigation: after a caught-up pull, every
    // server-known document must already be materialized from durable CRDT state.
    // Use the shared model fuzzer's knobs: CI can smoke-test quickly while a
    // release-hardening run raises coverage without editing source.
    let seeds = std::env::var("KNOTQ_FUZZ_SEEDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(16_u64);
    let steps = std::env::var("KNOTQ_FUZZ_STEPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(64_u64);
    for seed in 0..seeds {
        let dir = std::env::temp_dir().join(format!(
            "knotq-mobile-lazy-daily-lifecycle-fuzz-{seed}-{}",
            uuid::Uuid::new_v4()
        ));
        let workspace_path = dir.join("workspace").join("workspace.json");
        let today = default_today();
        let mut dates = (0..4_i64)
            .map(|offset| today - chrono::Duration::days(70 + offset * 9 + seed as i64))
            .collect::<Vec<_>>();
        let mut server_workspace = Workspace::new();
        for (index, date) in dates.iter().enumerate() {
            let id = daily_queue_scheme_id(*date);
            let mut daily = Scheme::new(daily_queue_scheme_name(*date), DAILY_QUEUE_COLOR_INDEX);
            daily.id = id;
            daily
                .items
                .push(Item::new(format!("seed {seed} daily {index} base")));
            server_workspace.daily_queue.insert(*date, id);
            server_workspace.schemes.insert(id, daily);
        }
        // Ordinary schemes share the same durable CRDT/cursor layers but are
        // always UI-loaded. Mixing them with lazy dailies catches accidental
        // coupling between the two populations.
        let mut ordinary_ids = Vec::new();
        for index in 0..2 {
            let mut scheme = Scheme::new(format!("seed {seed} ordinary {index}"), index);
            scheme
                .items
                .push(Item::new(format!("seed {seed} ordinary {index} base")));
            let id = scheme.id;
            server_workspace
                .folders
                .get_mut(&server_workspace.root)
                .unwrap()
                .children
                .push(NodeRef::Scheme(id));
            server_workspace.schemes.insert(id, scheme);
            ordinary_ids.push(id);
        }
        server_workspace.ensure_sync_metadata();
        let replica_id = ReplicaId::new();
        let mut server_crdt = WorkspaceCrdtDocuments::try_new(&server_workspace).unwrap();
        let initial_states = server_crdt.document_states();
        let mut heads = initial_states
            .keys()
            .map(|document| (*document, 1_u64))
            .collect::<HashMap<_, _>>();
        let mut sync_state = LocalSyncState {
            workspace_id: Some(server_workspace.id),
            replica_id: Some(replica_id),
            ..LocalSyncState::default()
        };
        for document in initial_states.keys() {
            sync_state.document_cursors.insert(
                *document,
                DocumentSyncCursor {
                    document: *document,
                    kind: if *document == server_workspace.sync.id {
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
        save_workspace(&workspace_path, &server_workspace).unwrap();
        save_crdt_state(&workspace_path, &initial_states).unwrap();
        save_local_sync_state(&workspace_path, &sync_state).unwrap();

        let mut inner = MobileCoreInner::open(dir.clone()).unwrap();
        let initial_materialized = inner
            .crdt
            .materialized_workspace_for_diagnostics(&inner.workspace)
            .unwrap();
        for date in &dates {
            let id = daily_queue_scheme_id(*date);
            assert_eq!(
                initial_materialized.schemes[&id].items, server_workspace.schemes[&id].items,
                "seed {seed}: cold-open CRDT restore lost daily {date} before fuzzing"
            );
        }
        let mut random = seed.wrapping_add(0x9e37_79b9_7f4a_7c15);
        for step in 0..steps {
            // Small deterministic PRNG: a failing seed fully reproduces the
            // operation order without a test-only RNG dependency.
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            match random % 9 {
                // A real background/edit save while some dailies are still lazy.
                0 => inner.save_workspace().unwrap(),
                // A remote device edits either an ordinary scheme or a lazy
                // daily, then this device receives a normal merged-state pull.
                1 | 2 => {
                    let ids = dates
                        .iter()
                        .map(|date| daily_queue_scheme_id(*date))
                        .chain(ordinary_ids.iter().copied())
                        .collect::<Vec<_>>();
                    let scheme_id = ids[((random >> 8) as usize) % ids.len()];
                    server_workspace
                        .schemes
                        .get_mut(&scheme_id)
                        .unwrap()
                        .items
                        .push(Item::new(format!("seed {seed} step {step} remote")));
                    let update = server_crdt.sync_changes(
                        &server_workspace,
                        &WorkspaceCrdtChangeSet::default().touch_scheme(scheme_id),
                    );
                    assert!(
                        update.errors.is_empty(),
                        "seed {seed} step {step}: remote edit"
                    );
                    let document = server_workspace.scheme_sync[&scheme_id].id;
                    let next_head = heads.get(&document).copied().unwrap_or(1) + 1;
                    heads.insert(document, next_head);
                    let expected_cursors = sync_state
                        .document_cursors
                        .iter()
                        .map(|(document, cursor)| (*document, cursor.last_pulled_sequence))
                        .collect();
                    let state_v1 = server_crdt.document_states()[&document].to_vec();
                    let transport = ExpectedPullTransport {
                        expected_cursors,
                        response: BatchPullResponse {
                            documents: vec![PulledCrdtDocument {
                                document,
                                kind: SyncDocumentKind::Scheme,
                                seq: next_head,
                                epoch: 0,
                                state_v1,
                                state_v1_is_delta: false,
                            }],
                            known_documents: Some(heads.clone()),
                            ..BatchPullResponse::default()
                        },
                    };
                    let visible = inner.workspace.clone();
                    let pull = batch_pull_and_apply(
                        &transport,
                        &mut inner.crdt,
                        &mut sync_state,
                        visible,
                        inner.settings.replica_id,
                    )
                    .unwrap();
                    inner.workspace = pull.workspace;
                    inner.save_workspace().unwrap();
                    save_local_sync_state(&workspace_path, &sync_state).unwrap();
                }
                // Create a new Daily Queue around a calendar boundary. This
                // deliberately includes yesterday/today/tomorrow and a
                // DST-adjacent date; daily ids/bindings are date-derived, so a
                // timezone/date-boundary bug shows up as a missing or wrongly
                // bound content document rather than a cosmetic label issue.
                3 => {
                    let boundary_dates = [
                        today - chrono::Duration::days(1),
                        today,
                        today + chrono::Duration::days(1),
                        NaiveDate::from_ymd_opt(2026, 3, 8).unwrap(),
                        NaiveDate::from_ymd_opt(2026, 11, 1).unwrap(),
                    ];
                    let date = boundary_dates[((random >> 16) as usize) % boundary_dates.len()];
                    if let std::collections::btree_map::Entry::Vacant(entry) =
                        server_workspace.daily_queue.entry(date)
                    {
                        let id = daily_queue_scheme_id(date);
                        let mut daily =
                            Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
                        daily.id = id;
                        daily.items.push(Item::new(format!(
                            "seed {seed} step {step} boundary daily {date}"
                        )));
                        entry.insert(id);
                        server_workspace.schemes.insert(id, daily);
                        server_workspace.ensure_sync_metadata();
                        dates.push(date);
                        let updates = server_crdt.sync_changes(
                            &server_workspace,
                            &WorkspaceCrdtChangeSet::default()
                                .workspace()
                                .touch_scheme(id),
                        );
                        assert!(
                            updates.errors.is_empty(),
                            "seed {seed} step {step}: create boundary daily"
                        );
                        let workspace_document = server_workspace.sync.id;
                        let daily_document = server_workspace.scheme_sync[&id].id;
                        let workspace_head =
                            heads.get(&workspace_document).copied().unwrap_or(1) + 1;
                        heads.insert(workspace_document, workspace_head);
                        heads.insert(daily_document, 1);
                        let expected_cursors = sync_state
                            .document_cursors
                            .iter()
                            .map(|(document, cursor)| (*document, cursor.last_pulled_sequence))
                            .collect();
                        let states = server_crdt.document_states();
                        let transport = ExpectedPullTransport {
                            expected_cursors,
                            response: BatchPullResponse {
                                documents: vec![
                                    PulledCrdtDocument {
                                        document: workspace_document,
                                        kind: SyncDocumentKind::PersonalWorkspace,
                                        seq: workspace_head,
                                        epoch: 0,
                                        state_v1: states[&workspace_document].to_vec(),
                                        state_v1_is_delta: false,
                                    },
                                    PulledCrdtDocument {
                                        document: daily_document,
                                        kind: SyncDocumentKind::Scheme,
                                        seq: 1,
                                        epoch: 0,
                                        state_v1: states[&daily_document].to_vec(),
                                        state_v1_is_delta: false,
                                    },
                                ],
                                known_documents: Some(heads.clone()),
                                ..BatchPullResponse::default()
                            },
                        };
                        let visible = inner.workspace.clone();
                        let pull = batch_pull_and_apply(
                            &transport,
                            &mut inner.crdt,
                            &mut sync_state,
                            visible,
                            inner.settings.replica_id,
                        )
                        .unwrap();
                        inner.workspace = pull.workspace;
                        inner.save_workspace().unwrap();
                        save_local_sync_state(&workspace_path, &sync_state).unwrap();
                    }
                }
                // A complete process lifecycle boundary.
                4 => {
                    inner.save_workspace().unwrap();
                    save_local_sync_state(&workspace_path, &sync_state).unwrap();
                    drop(inner);
                    inner = MobileCoreInner::open(dir.clone()).unwrap();
                    sync_state = load_local_sync_state(&workspace_path).unwrap();
                }
                // Historically viewing dates; this must remain harmless after
                // any number of earlier saves/restarts.
                5 => {
                    let _ = inner.snapshot(today, 0, 120).unwrap();
                }
                // A malformed off-window Daily Queue file: a partial write, bad
                // bytes, or truncated XML. The durable CRDT state is intact, so
                // navigating to that date must surface a recoverable error and
                // the next (even caught-up) sync must repair exactly that one
                // date from CRDT, leave every other deferred daily untouched,
                // and rewrite a good file.
                6 => {
                    let window_start = daily_queue_initial_start(today);
                    let target = dates
                        .iter()
                        .copied()
                        .filter(|date| *date < window_start)
                        .find(|date| {
                            let id = daily_queue_scheme_id(*date);
                            server_workspace.schemes.contains_key(&id)
                        });
                    if let Some(date) = target {
                        let id = daily_queue_scheme_id(date);
                        let daily_document = server_workspace.scheme_sync[&id].id;
                        // Return to the lazy state so the corruption is actually
                        // hit on the next navigation.
                        inner.save_workspace().unwrap();
                        save_local_sync_state(&workspace_path, &sync_state).unwrap();
                        drop(inner);
                        let scheme_path = dir
                            .join("workspace")
                            .join("schemes")
                            .join(format!("{id}.knotq"));
                        let clean = std::fs::read(&scheme_path).unwrap();
                        let damaged = match (random >> 20) % 4 {
                            0 => clean[..clean.len() / 2].to_vec(),
                            1 => b"<scheme><item>unterminated".to_vec(),
                            2 => vec![0xff, 0xfe, 0x00, b'<'],
                            _ => b"<?xml version=\"1.0\"?><scheme".to_vec(),
                        };
                        std::fs::write(&scheme_path, damaged).unwrap();

                        inner = MobileCoreInner::open(dir.clone()).unwrap();
                        sync_state = load_local_sync_state(&workspace_path).unwrap();
                        assert!(
                            !inner.workspace.schemes.contains_key(&id),
                            "seed {seed} step {step}: corrupted daily must be lazy on cold open"
                        );
                        let deferred_before = inner.crdt.document_population().deferred_schemes;
                        assert!(
                            inner.snapshot(today, 0, 120).is_err(),
                            "seed {seed} step {step}: navigating to a corrupted daily must error"
                        );
                        // The parse failure scheduled CRDT recovery for exactly
                        // this date and nothing else.
                        assert!(
                            !inner.crdt.is_deferred(id),
                            "seed {seed} step {step}: recovery must hydrate the corrupted daily"
                        );
                        assert_eq!(
                            inner.crdt.document_population().deferred_schemes,
                            deferred_before - 1,
                            "seed {seed} step {step}: recovery must touch only one deferred daily"
                        );

                        let expected_cursors = sync_state
                            .document_cursors
                            .iter()
                            .map(|(document, cursor)| (*document, cursor.last_pulled_sequence))
                            .collect();
                        let transport = ExpectedPullTransport {
                            expected_cursors,
                            response: BatchPullResponse {
                                known_documents: Some(heads.clone()),
                                ..BatchPullResponse::default()
                            },
                        };
                        let visible = inner.workspace.clone();
                        let pull = batch_pull_and_apply(
                            &transport,
                            &mut inner.crdt,
                            &mut sync_state,
                            visible,
                            inner.settings.replica_id,
                        )
                        .unwrap();
                        assert!(
                            pull.remote_updates_applied > 0,
                            "seed {seed} step {step}: caught-up pull must persist the recovery"
                        );
                        assert!(
                            pull.workspace.schemes.get(&id).is_some_and(
                                |scheme| scheme.items == server_workspace.schemes[&id].items
                            ),
                            "seed {seed} step {step}: recovery restored the wrong daily content"
                        );
                        assert!(
                            inner.crdt.document_states().contains_key(&daily_document),
                            "seed {seed} step {step}: recovery kept the daily CRDT bytes"
                        );
                        inner.workspace = pull.workspace;
                        inner.save_workspace().unwrap();
                        save_local_sync_state(&workspace_path, &sync_state).unwrap();

                        // The rewritten file is now readable and every other
                        // date still renders.
                        drop(inner);
                        inner = MobileCoreInner::open(dir.clone()).unwrap();
                        sync_state = load_local_sync_state(&workspace_path).unwrap();
                        let snapshot = inner.snapshot(today, 0, 120).unwrap();
                        assert!(
                            snapshot
                                .daily
                                .iter()
                                .any(|entry| entry.date == date.to_string()),
                            "seed {seed} step {step}: repaired daily is visible after relaunch"
                        );
                    }
                }
                // Server and device are genuinely caught up. This is where the
                // old code falsely returned the partial lazy workspace unchanged.
                _ => {
                    let expected_cursors = sync_state
                        .document_cursors
                        .iter()
                        .map(|(document, cursor)| (*document, cursor.last_pulled_sequence))
                        .collect();
                    let transport = ExpectedPullTransport {
                        expected_cursors,
                        response: BatchPullResponse {
                            known_documents: Some(heads.clone()),
                            ..BatchPullResponse::default()
                        },
                    };
                    let visible = inner.workspace.clone();
                    let deferred_before = inner.crdt.document_population().deferred_schemes;
                    let pull = batch_pull_and_apply(
                        &transport,
                        &mut inner.crdt,
                        &mut sync_state,
                        visible,
                        inner.settings.replica_id,
                    )
                    .unwrap();
                    // The new contract: a caught-up pull must NOT decode the
                    // whole history. Every daily that is not in the loaded UI
                    // workspace stays deferred; only its durable bytes matter.
                    assert_eq!(
                        inner.crdt.document_population().deferred_schemes,
                        deferred_before,
                        "seed {seed} step {step}: caught-up pull hydrated a deferred daily"
                    );
                    for date in &dates {
                        let id = daily_queue_scheme_id(*date);
                        if inner.workspace.schemes.contains_key(&id) {
                            // A daily the UI has loaded IS repaired by a
                            // caught-up pull (visible/touched state).
                            assert_eq!(
                                pull.workspace.schemes[&id].items,
                                server_workspace.schemes[&id].items,
                                "seed {seed} step {step}: caught-up pull left visible daily {date} stale"
                            );
                        } else {
                            assert!(
                                !pull.workspace.schemes.contains_key(&id),
                                "seed {seed} step {step}: caught-up pull eagerly materialized off-window daily {date}"
                            );
                            assert!(
                                inner
                                    .crdt
                                    .document_states()
                                    .contains_key(&server_workspace.scheme_sync[&id].id),
                                "seed {seed} step {step}: caught-up pull dropped deferred daily {date} bytes"
                            );
                        }
                    }
                    inner.workspace = pull.workspace;
                    inner.save_workspace().unwrap();
                    save_local_sync_state(&workspace_path, &sync_state).unwrap();
                }
            }
            // The exhaustive oracle: decode EVERYTHING (live + deferred) and
            // require full convergence with the server. This is where a lost or
            // corrupted deferred document, or a bad merge into a lazy daily,
            // shows up regardless of which lifecycle op produced it.
            let materialized = inner
                .crdt
                .materialized_workspace_for_diagnostics(&inner.workspace)
                .unwrap();
            for date in &dates {
                let id = daily_queue_scheme_id(*date);
                assert_eq!(
                    materialized.schemes[&id].items, server_workspace.schemes[&id].items,
                    "seed {seed} step {step}: lifecycle operation lost daily {date} from CRDT"
                );
            }
            for id in &ordinary_ids {
                assert_eq!(
                    materialized.schemes[id].items, server_workspace.schemes[id].items,
                    "seed {seed} step {step}: lifecycle operation lost ordinary scheme {id}"
                );
            }
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// An in-memory sync backend that merges pushed CRDT updates exactly the way the
/// Cloudflare Worker does (merged-state model, per-document seq, atomic batch),
/// so two real `MobileCoreInner` instances can sync through it. It reuses the
/// shared engine's merge (`apply_remote_updates`) rather than re-implementing
/// Yjs, so this stays faithful without a `yrs` dependency in the test crate.
pub(crate) struct MobileFuzzServer {
    pub(crate) crdt: RefCell<WorkspaceCrdtDocuments>,
    pub(crate) workspace: RefCell<Workspace>,
    pub(crate) seqs: RefCell<HashMap<DocumentId, u64>>,
    pub(crate) pull_calls: RefCell<usize>,
    pub(crate) push_calls: RefCell<usize>,
    pub(crate) workspace_id: knotq_model::WorkspaceId,
    /// `background_refresh_required` seen on each push that carried documents —
    /// the signal the backend gates its offline-peer FCM wake on.
    pub(crate) push_background_refresh: RefCell<Vec<bool>>,
}

impl MobileFuzzServer {
    pub(crate) fn seeded(
        initial: &Workspace,
        states: &HashMap<DocumentId, std::sync::Arc<[u8]>>,
    ) -> Self {
        let crdt = WorkspaceCrdtDocuments::from_states(initial, ReplicaId::new(), states)
            .expect("seed server crdt");
        let seqs = states.keys().map(|document| (*document, 1_u64)).collect();
        Self {
            crdt: RefCell::new(crdt),
            workspace: RefCell::new(initial.clone()),
            seqs: RefCell::new(seqs),
            pull_calls: RefCell::new(0),
            push_calls: RefCell::new(0),
            workspace_id: initial.id,
            push_background_refresh: RefCell::new(Vec::new()),
        }
    }
}

impl SyncTransport for MobileFuzzServer {
    fn pull(&self, request: &BatchPullRequest) -> anyhow::Result<BatchPullResponse> {
        *self.pull_calls.borrow_mut() += 1;
        let states = self.crdt.borrow().document_states();
        let seqs = self.seqs.borrow();
        let workspace = self.workspace.borrow();
        let kind_of = |document: DocumentId| {
            if document == workspace.sync.id {
                SyncDocumentKind::PersonalWorkspace
            } else {
                SyncDocumentKind::Scheme
            }
        };
        let documents = seqs
            .iter()
            .filter(|(document, seq)| **seq > request.cursors.get(*document).copied().unwrap_or(0))
            .filter_map(|(document, seq)| {
                states.get(document).map(|state| PulledCrdtDocument {
                    document: *document,
                    kind: kind_of(*document),
                    seq: *seq,
                    epoch: 0,
                    state_v1: state.to_vec(),
                    state_v1_is_delta: false,
                })
            })
            .collect();
        Ok(BatchPullResponse {
            documents,
            known_documents: Some(seqs.clone()),
            integrity_mismatches: None,
            integrity_check_deferred: false,
            notification_schedule_revision: 0,
            has_more: false,
        })
    }

    fn push(&self, request: &BatchPushRequest) -> anyhow::Result<BatchPushResponse> {
        *self.push_calls.borrow_mut() += 1;
        self.push_background_refresh
            .borrow_mut()
            .push(request.background_refresh_required);
        let mut crdt = self.crdt.borrow_mut();
        let workspace = self.workspace.borrow().clone();
        let mut updates = Vec::new();
        for doc in &request.documents {
            for update in &doc.updates {
                updates.push(StoredCrdtUpdate {
                    workspace_id: self.workspace_id,
                    document: doc.document,
                    kind: doc.kind,
                    replica_id: request.replica_id,
                    sequence: 0,
                    received_at: Utc::now(),
                    update_v1: update.clone(),
                });
            }
        }
        let outcome = crdt.apply_remote_updates(&workspace, &updates);
        if !outcome.workspace_errors.is_empty() {
            return Err(anyhow::Error::new(SyncPushRejected {
                code: "crdt_schema_invalid".to_string(),
            }));
        }
        for error in &outcome.document_errors {
            if !error.unknown_scheme_document {
                return Err(anyhow::Error::new(SyncPushRejected {
                    code: "crdt_schema_invalid".to_string(),
                }));
            }
        }
        *self.workspace.borrow_mut() = outcome.workspace;
        let mut seqs = self.seqs.borrow_mut();
        let mut pushed = Vec::with_capacity(request.documents.len());
        for doc in &request.documents {
            let next = seqs.get(&doc.document).copied().unwrap_or(0) + 1;
            seqs.insert(doc.document, next);
            pushed.push(PushedCrdtDocument {
                document: doc.document,
                seq: next,
                accepted: doc.updates.len(),
            });
        }
        Ok(BatchPushResponse {
            documents: pushed,
            notification_schedule_revision: 0,
            background_pushes_enqueued: 0,
        })
    }
}
