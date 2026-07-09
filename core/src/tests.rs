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
