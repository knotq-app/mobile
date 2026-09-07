use super::*;
use chrono::{Local, TimeZone};
use knotq_model::{
    CalendarProvider, DocumentId, ImportedCalendarSource, NodeRef, ReplicaId, SchemeSource,
    SyncDocumentKind,
};
use knotq_sync::{
    BatchPullRequest, BatchPullResponse, BatchPushRequest, BatchPushResponse, DocumentSyncCursor,
    LocalSyncState, PulledCrdtDocument, PushedCrdtDocument, StoredCrdtUpdate, SyncPushRejected,
    SyncTransport,
};
use std::cell::RefCell;
use std::collections::HashMap;

/// A caught-up server: it deliberately returns no documents. This is the exact
/// response that used to leave a device with current pull cursors but a stale
/// materialized workspace permanently claiming it was synced.
struct EmptyPullTransport;

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
struct ExpectedPullTransport {
    expected_cursors: HashMap<DocumentId, u64>,
    response: BatchPullResponse,
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
fn cold_restore_and_caught_up_pull_scale_with_visible_dailies_not_history() {
    // A structural (counter-based, not timing) guarantee: cold open and a
    // caught-up pull decode a number of scheme documents proportional to the
    // ordinary schemes plus the *visible* daily window — never the user's whole
    // Daily Queue history. Regressing lazy loading (decoding every historical
    // daily on startup, or re-materializing them on every pull) shows up here as
    // a jump in the live count / a drop in the deferred count.
    let dir = std::env::temp_dir().join(format!(
        "knotq-mobile-daily-scale-{}",
        uuid::Uuid::new_v4()
    ));
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
        scheme.items.push(Item::new(format!("ordinary {index} line")));
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

    // Cold open: only ordinary schemes and the (empty) visible daily window are
    // decoded. All 60 historical dailies stay as deferred bytes.
    let mut inner = MobileCoreInner::open(dir.clone()).unwrap();
    let population = inner.crdt.document_population();
    assert_eq!(
        population.deferred_schemes, historical_daily_count as usize,
        "every historical daily must be deferred at cold open"
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
        !pull
            .workspace
            .schemes
            .keys()
            .any(|id| inner.workspace.daily_queue.values().any(|d| d == id)
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
        for (document, _) in &crdt_states {
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
                    if !server_workspace.daily_queue.contains_key(&date) {
                        let id = daily_queue_scheme_id(date);
                        let mut daily =
                            Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
                        daily.id = id;
                        daily.items.push(Item::new(format!(
                            "seed {seed} step {step} boundary daily {date}"
                        )));
                        server_workspace.daily_queue.insert(date, id);
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
                                    },
                                    PulledCrdtDocument {
                                        document: daily_document,
                                        kind: SyncDocumentKind::Scheme,
                                        seq: 1,
                                        epoch: 0,
                                        state_v1: states[&daily_document].to_vec(),
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
                        let deferred_before =
                            inner.crdt.document_population().deferred_schemes;
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
                            .map(|(document, cursor)| {
                                (*document, cursor.last_pulled_sequence)
                            })
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
                            pull.workspace
                                .schemes
                                .get(&id)
                                .is_some_and(|scheme| scheme.items
                                    == server_workspace.schemes[&id].items),
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
struct MobileFuzzServer {
    crdt: RefCell<WorkspaceCrdtDocuments>,
    workspace: RefCell<Workspace>,
    seqs: RefCell<HashMap<DocumentId, u64>>,
    workspace_id: knotq_model::WorkspaceId,
    /// `background_refresh_required` seen on each push that carried documents —
    /// the signal the backend gates its offline-peer FCM wake on.
    push_background_refresh: RefCell<Vec<bool>>,
}

impl MobileFuzzServer {
    fn seeded(initial: &Workspace, states: &HashMap<DocumentId, std::sync::Arc<[u8]>>) -> Self {
        let crdt = WorkspaceCrdtDocuments::from_states(initial, ReplicaId::new(), states)
            .expect("seed server crdt");
        let seqs = states.keys().map(|document| (*document, 1_u64)).collect();
        Self {
            crdt: RefCell::new(crdt),
            workspace: RefCell::new(initial.clone()),
            seqs: RefCell::new(seqs),
            workspace_id: initial.id,
            push_background_refresh: RefCell::new(Vec::new()),
        }
    }
}

impl SyncTransport for MobileFuzzServer {
    fn pull(&self, request: &BatchPullRequest) -> anyhow::Result<BatchPullResponse> {
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
            .filter(|(document, seq)| {
                **seq > request.cursors.get(*document).copied().unwrap_or(0)
            })
            .filter_map(|(document, seq)| {
                states.get(document).map(|state| PulledCrdtDocument {
                    document: *document,
                    kind: kind_of(*document),
                    seq: *seq,
                    epoch: 0,
                    state_v1: state.to_vec(),
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

/// One full mobile sync cycle against `server` — drives the PRODUCTION method
/// `MobileCoreInner::run_sync_cycle` (the same code `sync_once` calls after its
/// HTTP-only prelude), so the fuzz exercises the real sync path rather than a
/// re-implementation. Media is skipped (`None`).
fn mobile_sync_cycle(inner: &mut MobileCoreInner, server: &MobileFuzzServer) -> anyhow::Result<()> {
    inner.sync_state_cache = None;
    let mut sync_state = load_local_sync_state(&inner.workspace_path).unwrap_or_default();
    let server_workspace_id = sync_state.workspace_id.unwrap_or(inner.workspace.id);
    inner.run_sync_cycle(
        server,
        &mut sync_state,
        server_workspace_id,
        false, // account_switched
        false, // prelude_workspace_changed
        None,  // media transport
    )?;
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
fn command_requires_background_refresh_covers_completion_and_schedule_edits() {
    use crate::crdt_changes::mobile_command_requires_background_refresh as needs;
    let scheme = SchemeId::new();
    let item = ItemId::new();
    let occ = OccurrenceId::Single;

    // Completions and schedule edits — a peer may need to redraw / cancel a
    // banner even if the pushed notification hash is unchanged.
    assert!(needs(&Command::ToggleOccurrence {
        scheme,
        item,
        occurrence: occ.clone()
    }));
    assert!(needs(&Command::SetOccurrenceNotificationOffset {
        scheme,
        item,
        occurrence: occ.clone(),
        offset_secs: Some(600),
    }));
    assert!(needs(&Command::DeleteItem { scheme, item }));
    assert!(needs(&Command::InsertItem {
        scheme,
        position: 0,
        item: Item::new("meeting")
            .with_start(chrono::Utc::now())
            .with_end(chrono::Utc::now() + chrono::Duration::hours(1)),
    }));

    // Plain prose edits to undated items stay out — peers pick those up on
    // their next foreground / socket sync, matching the desktop FCM gate.
    assert!(!needs(&Command::InsertItem {
        scheme,
        position: 0,
        item: Item::new("just a note"),
    }));
    assert!(!needs(&Command::UpdateItemText {
        scheme,
        item,
        text: "typing".to_string(),
    }));
    assert!(!needs(&Command::RenameScheme {
        id: scheme,
        name: "renamed".to_string(),
    }));
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
            daily.items.push(Item::new(format!("seed {seed} {date} base")));
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
                eprintln!("seed {seed} step {step}: dev {other} op {}", (roll >> 1) % 9);
            }
            match (roll >> 1) % 9 {
                // Edit an ordinary scheme, then sync.
                0 | 1 => {
                    let id = ordinary_ids[((roll >> 8) as usize) % ordinary_ids.len()];
                    append_line(dev, id, &format!("seed {seed} step {step} {}", if on_a { "a" } else { "b" }))
                        .unwrap();
                    mobile_sync_cycle(dev, &server).unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
                }
                // Edit an in-window daily (loaded), then sync.
                2 => {
                    let _ = dev.snapshot(today, 0, 5);
                    let id = daily_queue_scheme_id(in_window_date);
                    if dev.workspace.schemes.contains_key(&id) {
                        append_line(dev, id, &format!("seed {seed} step {step} daily")).unwrap();
                        mobile_sync_cycle(dev, &server).unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
                    }
                }
                // Load an off-window daily, edit it, then sync.
                3 => {
                    let date = off_window_dates[((roll >> 8) as usize) % off_window_dates.len()];
                    let _ = dev.snapshot(today, 0, 120);
                    let id = daily_queue_scheme_id(date);
                    if dev.workspace.schemes.contains_key(&id) {
                        append_line(dev, id, &format!("seed {seed} step {step} old-daily")).unwrap();
                        mobile_sync_cycle(dev, &server).unwrap_or_else(|e| panic!("seed {seed} step {step}: {e}"));
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

        let scheme_ids: Vec<SchemeId> = server_ws
            .scheme_sync
            .keys()
            .copied()
            .collect();
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
        let ws_id: knotq_model::WorkspaceId =
            resp["workspace_id"].as_str().expect("ws id").parse().expect("uuid");
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
            &WorkspaceCrdtDocuments::try_new(&workspace).unwrap().document_states(),
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
        let http = crate::media_sync::MobileSyncHttpClient {
            api_base: base_url.clone(),
            bearer_token: token.to_string(),
        };
        let ws = inner.ws_client.clone();
        let transport = crate::ws_sync::FallbackTransport::new(ws.as_deref(), &http);
        inner
            .run_sync_cycle(&transport, &mut sync_state, ws_id, false, false, Some(&http))
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
            .record_crdt_changes(WorkspaceCrdtChangeSet::default().workspace().touch_scheme(id))
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
    assert_eq!(texts_a, texts_b, "devices converged over the real websocket");
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
                recurrence_exdates: Vec::new(),
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

// Archiving an imported calendar (by hand, or as a duplicate) must not make the
// next import create a second scheme for it: that is what pushed the account's
// calendar count up by one on every reconnect.
#[test]
fn google_calendar_import_restores_an_archived_calendar_instead_of_duplicating_it() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let mut inner = MobileCoreInner::open(dir.clone()).expect("open mobile core");
    inner.workspace = Workspace::new();
    let root = inner.workspace.root;

    let archived = imported_google_scheme("Google Calendar", "account", "calendar");
    let archived_id = archived.id;
    inner.workspace.schemes.insert(archived_id, archived);
    // Archiving detaches the scheme from its folder and records where it came
    // from, which is the state the next import actually meets.
    inner
        .workspace
        .mark_scheme_deleted_from(archived_id, root, 0);
    assert!(inner.workspace.is_scheme_deleted(archived_id));

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
                recurrence_exdates: Vec::new(),
            }],
            true,
            root,
        )
        .expect("apply imported calendars");

    assert!(result.content_changed);
    // The archived scheme came back; no second scheme was minted for the same
    // calendar.
    assert!(!inner.workspace.is_scheme_deleted(archived_id));
    assert_eq!(inner.workspace.schemes.len(), 1);
    assert_eq!(result.created_count, 1);

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
