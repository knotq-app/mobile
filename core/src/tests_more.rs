use super::*;
use crate::conversions::format_datetime;
use chrono::{Local, TimeZone};
use knotq_model::{
    CalendarProvider, ImportedCalendarSource, ReplicaId, SchemeSource, SyncDocumentKind,
};
use knotq_sync::LocalSyncState;

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
fn delivered_notifications_to_clear_targets_expired_events_and_completed_items() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");
    let now = Utc.with_ymd_and_hms(2026, 5, 27, 12, 0, 0).unwrap();

    // An event whose end time has already elapsed: its banner should be cleared.
    let past_start = now - Duration::hours(2);
    let past_end = now - Duration::hours(1);
    core.add_calendar_item(
        None,
        Some(past_start.date_naive().to_string()),
        "Past event".to_string(),
        "event".to_string(),
        Some(format_datetime(past_start)),
        Some(format_datetime(past_end)),
    )
    .expect("add past event");
    // Capture its stable id while the notification is still in the future.
    let past_event_id = core
        .pending_notifications(Some(format_datetime(past_start - Duration::hours(1))), 14)
        .expect("pending before fire")
        .into_iter()
        .find(|request| request.title == "Past event")
        .expect("past event notification")
        .id;

    // A still-live future event must NOT be cleared.
    let future_start = now + Duration::hours(5);
    let future_end = now + Duration::hours(6);
    core.add_calendar_item(
        None,
        Some(future_start.date_naive().to_string()),
        "Future event".to_string(),
        "event".to_string(),
        Some(format_datetime(future_start)),
        Some(format_datetime(future_end)),
    )
    .expect("add future event");
    let future_event_id = core
        .pending_notifications(Some(format_datetime(now)), 14)
        .expect("pending now")
        .into_iter()
        .find(|request| request.title == "Future event")
        .expect("future event notification")
        .id;

    // A reminder the user completes: its delivered banner should be cleared too.
    let reminder = {
        let reminder_start = now + Duration::hours(1);
        core.add_calendar_item(
            None,
            Some(reminder_start.date_naive().to_string()),
            "Done reminder".to_string(),
            "reminder".to_string(),
            Some(format_datetime(reminder_start)),
            None,
        )
        .expect("add reminder");
        core.pending_notifications(Some(format_datetime(now)), 14)
            .expect("pending now")
            .into_iter()
            .find(|request| request.title == "Done reminder")
            .expect("reminder notification")
    };
    let reminder_id = reminder.id.clone();
    assert!(core
        .apply_notification_action(
            ACTION_MARK_DONE.to_string(),
            reminder.scheme_id,
            reminder.item_id,
            reminder.occurrence_json,
            reminder.trigger_at,
        )
        .expect("mark reminder done"));

    let clear = core
        .delivered_notifications_to_clear(Some(format_datetime(now)))
        .expect("clear list");

    assert!(
        clear.contains(&past_event_id),
        "an event past its end time should be cleared"
    );
    assert!(
        clear.contains(&reminder_id),
        "a completed reminder should be cleared"
    );
    assert!(
        !clear.contains(&future_event_id),
        "a still-live future event must not be cleared"
    );

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
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
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
            occurrence.title == "Standup" && occurrence.local_date.as_deref() == Some("2026-01-07")
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
            occurrence.title == "Standup" && occurrence.local_date.as_deref() == Some("2026-01-07")
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
            occurrence.title == "Standup" && occurrence.local_date.as_deref() == Some("2026-01-07")
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
            occurrence.title == "Standup" && occurrence.local_date.as_deref() == Some("2026-01-07")
        }));

    let _ = std::fs::remove_dir_all(dir);
}
