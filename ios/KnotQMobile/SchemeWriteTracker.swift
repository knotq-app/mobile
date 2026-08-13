import Foundation

/// Reference counts the core writes that are in flight for each scheme.
///
/// Every core write is async (`AppModel.mutate` hops the bridge queue), so
/// between submitting one and its completion `snapshot` — and therefore
/// `scheme(id:)` and the daily entries — still describes the PRE-write document.
/// Anything that rebuilds scheme content from the snapshot in that window shows
/// the user state they have already changed. For an editor pane that is worse
/// than a flicker: the stale list becomes `EditorController.baselineItems`, so
/// when the write finally lands the mid-edit merge treats the in-flight change as
/// something to overwrite and silently drops it.
///
/// A plain value type with no dependency on the model or the core, so the
/// bookkeeping is directly testable.
struct SchemeWriteTracker: Equatable {
    /// Outstanding writes per scheme id. Absent means none — a count is removed
    /// rather than left at zero so equality and emptiness read naturally.
    private(set) var outstanding: [String: Int] = [:]

    var isEmpty: Bool { outstanding.isEmpty }

    func isInFlight(_ schemeID: String) -> Bool {
        (outstanding[schemeID] ?? 0) > 0
    }

    mutating func begin(_ schemeID: String) {
        outstanding[schemeID, default: 0] += 1
    }

    /// Begins one write that spans several documents (e.g. moving an item between
    /// schemes). Returns the de-duplicated ids so the caller ends exactly what it
    /// began — passing the same id twice must not leave a count stranded above
    /// zero, which would make readers wait forever.
    @discardableResult
    mutating func begin(_ schemeIDs: [String]) -> [String] {
        // Preserve the caller's order. The tracker itself does not care, but a
        // stable completion order makes this little state machine easier to
        // reason about and avoids deriving externally observable work order from
        // randomized `Set` iteration.
        var seen = Set<String>()
        let unique = schemeIDs.filter { seen.insert($0).inserted }
        for schemeID in unique {
            begin(schemeID)
        }
        return unique
    }

    /// Ends one outstanding write. Ending a scheme with none outstanding is a
    /// no-op rather than an underflow: completions can outlive the state they
    /// refer to (a model torn down mid-flight), and a negative count would make
    /// `isInFlight` permanently false — or permanently true if it wrapped.
    mutating func end(_ schemeID: String) {
        guard let count = outstanding[schemeID] else { return }
        if count <= 1 {
            outstanding[schemeID] = nil
        } else {
            outstanding[schemeID] = count - 1
        }
    }

    mutating func end(_ schemeIDs: [String]) {
        for schemeID in schemeIDs {
            end(schemeID)
        }
    }

    /// The items a freshly created editor text view should be seeded with.
    ///
    /// `SchemeTextView.makeUIView` populates its text storage from this directly
    /// — deliberately, so a self-sizing Daily section measures real content on its
    /// first layout pass — which means deferring the pane's `onAppear` load is not
    /// enough on its own to keep pre-write text off the screen. Seeding empty
    /// while a write is in flight leaves the section blank for the length of one
    /// core write, after which the deferred load fills in the real document.
    /// Blank is the right choice over stale: stale text invites the user to
    /// retype, and their retyping is what the merge then resolves against a
    /// baseline that predates their own in-flight edit.
    func initialEditorItems(for scheme: MobileScheme) -> [MobileItem] {
        isInFlight(scheme.id) ? [] : scheme.items
    }
}
