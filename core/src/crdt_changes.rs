use knotq_commands::Command;
use knotq_sync::WorkspaceCrdtChangeSet;

// Maps a domain command to the set of CRDT documents it touches, so the mobile
// core can record exactly which documents need re-encoding after applying it.
// Not part of the UniFFI surface.

pub(crate) fn mobile_crdt_change_set_for_command(command: &Command) -> WorkspaceCrdtChangeSet {
    let mut changes = WorkspaceCrdtChangeSet::default();
    mobile_collect_crdt_changes(command, &mut changes);
    changes
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
