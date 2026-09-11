use super::*;
use chrono::{Local, TimeZone};
use knotq_model::{CalendarProvider, ImportedCalendarSource};

// Calendar import and local-day bucketing tests live here so the main mobile
// core test module can stay focused on sync and Daily Queue lifecycle behavior.

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
fn google_calendar_full_sync_updates_an_event_without_minting_a_new_item() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let mut inner = MobileCoreInner::open(dir.clone()).expect("open mobile core");
    inner.workspace = Workspace::new();
    let root = inner.workspace.root;

    let mut scheme = imported_google_scheme("Calendar", "account", "calendar");
    let scheme_id = scheme.id;
    let original_start = Utc.with_ymd_and_hms(2026, 6, 1, 10, 0, 0).unwrap();
    let updated_start = Utc.with_ymd_and_hms(2026, 6, 1, 11, 0, 0).unwrap();
    let mut existing = Item::new("Old title");
    existing.marker = ItemMarker::Checkbox;
    existing.start = Some(original_start);
    existing.external = Some(knotq_model::ExternalItemSource {
        provider: CalendarProvider::Google,
        account_id: "account".to_string(),
        calendar_id: "calendar".to_string(),
        event_id: "event-1".to_string(),
        instance_id: None,
        updated_at: None,
    });
    let item_id = existing.id;
    scheme.items.push(existing);
    inner.workspace.schemes.insert(scheme_id, scheme);
    inner
        .workspace
        .folders
        .get_mut(&root)
        .unwrap()
        .children
        .push(NodeRef::Scheme(scheme_id));

    // Build the cached calendar index on the old external event first. The
    // refresh below must invalidate this cache before the next calendar read.
    let initial = inner
        .snapshot(NaiveDate::from_ymd_opt(2026, 6, 1).unwrap(), 0, 0)
        .expect("build calendar index before external refresh");
    assert!(initial
        .calendar
        .days
        .iter()
        .flat_map(|day| day.occurrences.iter())
        .any(|occurrence| occurrence.title == "Old title"));
    assert!(inner.indexed_workspace.is_some());

    let mut imported = Item::new("New title");
    imported.marker = ItemMarker::Checkbox;
    imported.start = Some(updated_start);
    imported.external = Some(knotq_model::ExternalItemSource {
        provider: CalendarProvider::Google,
        account_id: "account".to_string(),
        calendar_id: "calendar".to_string(),
        event_id: "event-1".to_string(),
        instance_id: None,
        updated_at: Some(updated_start),
    });

    let result = inner
        .apply_imported_google_calendars(
            vec![google_calendar::ImportedGoogleCalendar {
                account_id: "account".to_string(),
                account_email: Some("user@example.com".to_string()),
                calendar_id: "calendar".to_string(),
                name: "Calendar".to_string(),
                color_index: 3,
                sync_token: Some("token-2".to_string()),
                full_sync: true,
                items: vec![imported],
                deleted: Vec::new(),
                recurrence_exdates: Vec::new(),
            }],
            false,
            root,
        )
        .expect("apply updated calendar");

    assert!(result.content_changed);
    let stored = &inner.workspace.schemes[&scheme_id].items;
    assert_eq!(stored.len(), 1);
    assert_eq!(
        stored[0].id, item_id,
        "calendar refresh must preserve local identity"
    );
    assert_eq!(stored[0].text(), "New title");
    assert_eq!(stored[0].start, Some(updated_start));

    // Run the same CRDT/save leg used by `finish_google_calendar_sync`. The
    // next calendar read must not serve the old cached occurrence.
    inner
        .record_crdt_changes(result.changes)
        .expect("record external-source changes");
    inner
        .save_workspace()
        .expect("persist external-source refresh");
    assert!(
        inner.indexed_workspace.is_none(),
        "an external-source refresh must invalidate the cached index"
    );
    let refreshed = inner
        .snapshot(NaiveDate::from_ymd_opt(2026, 6, 1).unwrap(), 0, 0)
        .expect("rebuild calendar index after refresh");
    let refreshed_occurrence = refreshed
        .calendar
        .days
        .iter()
        .flat_map(|day| day.occurrences.iter())
        .find(|occurrence| occurrence.title == "New title")
        .expect("calendar index must reflect the refreshed external event");
    let expected_start = updated_start.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    assert_eq!(
        refreshed_occurrence.start.as_deref(),
        Some(expected_start.as_str())
    );

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
