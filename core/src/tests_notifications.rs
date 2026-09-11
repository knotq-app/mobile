use super::*;

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
fn notification_schedule_cache_only_invalidates_for_scheduled_item_changes() {
    use crate::crdt_changes::mobile_command_may_change_notification_schedule as may_change;

    let mut workspace = Workspace::new();
    let mut scheme = Scheme::new("Work", 0);
    let note = Item::new("plain note");
    let note_id = note.id;
    let meeting = Item::new("meeting")
        .with_start(chrono::Utc::now())
        .with_end(chrono::Utc::now() + chrono::Duration::hours(1));
    let meeting_id = meeting.id;
    scheme.items.extend([note, meeting]);
    let scheme_id = scheme.id;
    workspace.schemes.insert(scheme_id, scheme);

    assert!(!may_change(
        &workspace,
        &Command::UpdateItemText {
            scheme: scheme_id,
            item: note_id,
            text: "plain note amended".to_string(),
        }
    ));
    assert!(may_change(
        &workspace,
        &Command::UpdateItemText {
            scheme: scheme_id,
            item: meeting_id,
            text: "meeting renamed".to_string(),
        }
    ));
    let mut replacement = Item::new("meeting replaced");
    replacement.id = meeting_id;
    assert!(may_change(
        &workspace,
        &Command::ReplaceItem {
            scheme: scheme_id,
            item: replacement,
        }
    ));
}
