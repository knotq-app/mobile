use knotq_commands::Command;
use knotq_model::{Item, Workspace};
use knotq_sync::WorkspaceCrdtChangeSet;

// Maps a domain command to the set of CRDT documents it touches, so the mobile
// core can record exactly which documents need re-encoding after applying it.
// Not part of the UniFFI surface.

pub(crate) fn mobile_crdt_change_set_for_command(command: &Command) -> WorkspaceCrdtChangeSet {
    let mut changes = WorkspaceCrdtChangeSet::default();
    mobile_collect_crdt_changes(command, &mut changes);
    changes
}

/// Whether applying `command` can change what a *peer's* notification schedule
/// or Upcoming widget shows without necessarily changing the notification-hash
/// this device pushes — completing an already-past occurrence is the canonical
/// case (it drops out of the upcoming window, so the hash is stable, but the
/// peer still needs to cancel a delivered banner and redraw its widget).
///
/// Mirrors the desktop's `service_signals_for_command` "recompute" set. When
/// true, the mobile core sets `background_refresh_required` on the next push so
/// the backend wakes offline peers even though `notification_schedule_changed`
/// is false. Plain prose edits to undated items stay out, matching the desktop
/// gate — peers pick those up on their next foreground/socket sync.
pub(crate) fn mobile_command_requires_background_refresh(command: &Command) -> bool {
    match command {
        Command::ToggleOccurrence { .. }
        | Command::SetOccurrenceNotificationOffset { .. }
        | Command::SetItemDate { .. }
        | Command::SetItemRecurrence { .. }
        | Command::SetItemMarker { .. }
        | Command::DeleteItem { .. }
        | Command::DeleteScheme { .. }
        | Command::PermanentlyDeleteScheme { .. }
        | Command::RestoreScheme { .. }
        | Command::RestoreDeletedScheme { .. }
        | Command::DeleteFolder { .. }
        | Command::RestoreDeletedFolder { .. } => true,
        Command::InsertItem { item, .. } | Command::ReplaceItem { item, .. } => {
            item.start.is_some() || item.end.is_some()
        }
        Command::UpdateItemText { .. } => {
            // A dated item's text is its notification title; but we don't have
            // the item here, so be conservative and let the schedule-hash gate
            // handle a title change (it will differ), keeping undated prose out.
            false
        }
        Command::Batch(commands) => commands
            .iter()
            .any(mobile_command_requires_background_refresh),
        _ => false,
    }
}

/// Whether applying `command` can change the notification schedule hash. Plain
/// prose edits to procedure/undated lines do not; avoiding a full schedule
/// expansion for those edits is important because mobile sync may be triggered
/// repeatedly while a user is typing. The check is intentionally conservative:
/// if the old or new item is scheduled, invalidate the cache.
pub(crate) fn mobile_command_may_change_notification_schedule(
    workspace: &Workspace,
    command: &Command,
) -> bool {
    if mobile_command_requires_background_refresh(command) {
        return true;
    }
    match command {
        Command::UpdateItemText { scheme, item, .. } => workspace
            .scheme(*scheme)
            .and_then(|scheme| scheme.item(*item))
            .is_some_and(item_can_be_scheduled),
        Command::InsertItem { item, .. } => item_can_be_scheduled(item),
        Command::ReplaceItem { scheme, item } => {
            let old_can_be_scheduled = workspace
                .scheme(*scheme)
                .and_then(|scheme| scheme.item(item.id))
                .is_some_and(item_can_be_scheduled);
            old_can_be_scheduled || item_can_be_scheduled(item)
        }
        Command::Batch(commands) => commands
            .iter()
            .any(|command| mobile_command_may_change_notification_schedule(workspace, command)),
        _ => false,
    }
}

fn item_can_be_scheduled(item: &Item) -> bool {
    item.kind() != knotq_model::ItemKind::Procedure
}

fn mobile_collect_crdt_changes(command: &Command, out: &mut WorkspaceCrdtChangeSet) {
    match command {
        Command::CreateFolder { .. }
        | Command::RestoreFolder { .. }
        | Command::RenameFolder { .. }
        | Command::SetFolderExpanded { .. }
        | Command::DeleteFolder { .. }
        | Command::PermanentlyDeleteFolder { .. }
        | Command::CreateScheme { .. }
        | Command::RenameScheme { .. }
        | Command::SetSchemeColor { .. }
        | Command::SetSchemeGsync { .. }
        | Command::SetSchemeSource { .. }
        | Command::DeleteScheme { .. }
        | Command::PermanentlyDeleteScheme { .. }
        | Command::MoveNode { .. } => {
            out.workspace = true;
        }
        Command::RestoreScheme { scheme, .. } | Command::RestoreDeletedScheme { scheme, .. } => {
            out.workspace = true;
            out.schemes.insert(scheme.id);
        }
        Command::RestoreDeletedFolder { schemes, .. } => {
            out.workspace = true;
            for scheme in schemes {
                out.schemes.insert(scheme.id);
            }
        }
        Command::InsertItem { scheme, .. }
        | Command::UpdateItemText { scheme, .. }
        | Command::ReplaceItem { scheme, .. }
        | Command::SetItemIndent { scheme, .. }
        | Command::SetItemMarker { scheme, .. }
        | Command::SetItemMarkerFamily { scheme, .. }
        | Command::SetItemDate { scheme, .. }
        | Command::SetItemRecurrence { scheme, .. }
        | Command::SetItemPriority { scheme, .. }
        | Command::SetOccurrenceNotificationOffset { scheme, .. }
        | Command::ToggleOccurrence { scheme, .. }
        | Command::DeleteItem { scheme, .. }
        | Command::ReorderItem { scheme, .. } => {
            out.schemes.insert(*scheme);
        }
        Command::Batch(commands) => {
            for command in commands {
                mobile_collect_crdt_changes(command, out);
            }
        }
    }
}
