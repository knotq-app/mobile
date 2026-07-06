import Foundation

/// Item-level merge of a remote scheme update against the editor's unflushed
/// local edits.
///
/// A remote change can land while the user has keystrokes the live-flush
/// debounce hasn't committed to the core yet. Rebuilding the editor straight
/// from the remote list would silently drop that typing; flushing the editor
/// first would clobber the remote change (a bulk save replaces the whole item
/// list). So merge per line instead: lines the user touched since the last
/// load/flush win locally, everything else — remote edits, remote additions,
/// remote deletions — wins remotely. The caller then reloads the editor with
/// the merge and flushes it, so the core (and every other device) converges on
/// the same result.
///
/// - `remote`: the freshly pulled scheme items.
/// - `baseline`: the items as of the editor's last load/flush — what the core
///   knew from us before this remote change.
/// - `local`: the editor's current lines (`extractItemEdits`), including
///   unflushed typing. Lines the editor created and never flushed carry no id.
func mergeRemoteSchemeItems(
    remote: [MobileItem],
    baseline: [MobileItem],
    local: [MobileItemEdit]
) -> [MobileItem] {
    let baselineByID = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let localIDs = Set(local.compactMap(\.id))
    var locallyChangedIDs = Set<String>()
    for edit in local {
        guard let id = edit.id, let base = baselineByID[id] else { continue }
        if localEditDiffers(edit, from: base) {
            locallyChangedIDs.insert(id)
        }
    }

    var merged: [MobileItem] = []
    for remoteItem in remote {
        if let base = baselineByID[remoteItem.id], !localIDs.contains(remoteItem.id) {
            // The user deleted this line locally (unflushed). Honor the delete
            // unless the remote edited the item meanwhile — then keeping the
            // remote edit is the lossless resolution.
            if remoteItemDiffers(remoteItem, from: base) {
                merged.append(remoteItem)
            }
            continue
        }
        if locallyChangedIDs.contains(remoteItem.id),
           let edit = local.first(where: { $0.id == remoteItem.id }) {
            merged.append(overlayLocalEdit(edit, onto: remoteItem))
        } else {
            merged.append(remoteItem)
        }
    }

    // Re-insert local lines the remote list doesn't have, keeping their local
    // order relative to the lines that survived: brand-new typing (no id yet),
    // and remotely deleted lines the user edited (local edit wins the
    // delete/edit conflict).
    var anchor = -1
    for edit in local {
        if let id = edit.id, let position = merged.firstIndex(where: { $0.id == id }) {
            anchor = max(anchor, position)
            continue
        }
        if let id = edit.id, let base = baselineByID[id], !localEditDiffers(edit, from: base) {
            continue // remote deleted it and the user didn't touch it
        }
        let at = min(anchor + 1, merged.count)
        merged.insert(makeMobileItem(from: edit), at: at)
        anchor = at
    }
    return merged
}

/// Did the user change this line relative to what the core knew? Only the
/// fields typed/toggled in the editor participate; dates, media, and table
/// contents are edited through sheets that write straight to the model.
private func localEditDiffers(_ edit: MobileItemEdit, from base: MobileItem) -> Bool {
    edit.text != base.text
        || edit.marker != base.marker
        || edit.indent != base.indent
        || edit.done != base.done
}

private func remoteItemDiffers(_ remote: MobileItem, from base: MobileItem) -> Bool {
    remote.text != base.text
        || remote.marker != base.marker
        || remote.indent != base.indent
        || remote.done != base.done
        || remote.start != base.start
        || remote.end != base.end
        || remote.media != base.media
        || remote.tables != base.tables
        || remote.content != base.content
}

/// Local text/marker/indent/done over the remote item, keeping the remote's
/// rich metadata (dates, recurrence, media). Mirrors the core's block-preserve
/// rule: a bulk save sends empty content/media for an existing block line, so
/// the block survives the overlay instead of being clobbered by empty text.
private func overlayLocalEdit(_ edit: MobileItemEdit, onto remote: MobileItem) -> MobileItem {
    var item = remote
    let remoteIsBlock = remote.content.contains { inline in
        if case .text = inline { return false }
        return true
    }
    let preservesBlock = remoteIsBlock && edit.content.isEmpty && edit.media.isEmpty
    if !preservesBlock {
        item.text = edit.text
        if !edit.content.isEmpty {
            item.content = edit.content
            item.media = mediaInlines(from: edit.content)
            item.tables = tableInlines(from: edit.content)
        }
    }
    item.marker = edit.marker
    item.indent = edit.indent
    item.done = edit.done
    return item
}

/// A displayable item for a line the core hasn't seen yet. The minted id is
/// adopted by `replaceSchemeItems` on the next flush, so the line keeps one
/// identity instead of being re-created under a fresh id per flush.
private func makeMobileItem(from edit: MobileItemEdit) -> MobileItem {
    MobileItem(
        id: edit.id ?? UUID().uuidString.lowercased(),
        text: edit.text,
        marker: edit.marker,
        indent: edit.indent,
        kind: itemKind(for: edit),
        done: edit.done,
        start: edit.start,
        end: edit.end,
        notificationOffsetSecs: edit.notificationOffsetSecs,
        repeatRule: edit.repeatRule,
        media: edit.media.isEmpty ? mediaInlines(from: edit.content) : edit.media,
        tables: tableInlines(from: edit.content),
        content: edit.content
    )
}

/// Mirrors `Item::kind()` in the core model.
private func itemKind(for edit: MobileItemEdit) -> String {
    guard edit.marker == Marker.checkbox.rawValue else { return "procedure" }
    switch (edit.start != nil, edit.end != nil) {
    case (true, true): return "event"
    case (true, false): return "reminder"
    case (false, true): return "assignment"
    case (false, false): return "procedure"
    }
}
