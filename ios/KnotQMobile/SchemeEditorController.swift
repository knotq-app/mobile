import Combine
import SwiftUI
import UIKit

/// Takes the caret once the screen has finished arriving, except when the
/// keyboard was safely presented on the source screen first.
///
/// Opening Daily or a scheme pushes a screen *and* focuses its editor, and
/// raising the keyboard while that push is still animating is what made the
/// keyboard's first presentation of the process render against an unresolved
/// backdrop: a flat dark panel — rgb(152) against the settled light keyboard's
/// rgb(219) — held for ~300 ms and then snapped to the real keyboard. It is a
/// race, so it only shows up on some opens (9 of 16 cold opens of Daily
/// reproduced it); waiting for the transition to end fixed 10 of 10. It is
/// invisible in the dark theme, where a dark keyboard backdrop is what you
/// expect to see anyway — which is why it survived an earlier round of this.
///
/// Nothing is lost by waiting: the pane already reserves the keyboard's height
/// up front (see `KeyboardMetrics`), so the document is laid out for a keyboard
/// that is about to arrive either way, and the caret still lands on the first
/// frame the user can actually type into.
@MainActor
enum EditorAutoFocus {
    /// Which field this open is for. The handoff has to be given to the same one
    /// the open will end on: a new note focuses its *title*, and handing the
    /// keyboard to the document first put a blinking caret in the body for ~0.5s
    /// before the title took over and select-all highlighted it.
    enum Target {
        case document
        case title
    }

    static func schedule(
        in controller: EditorController,
        target: Target = .document,
        _ action: @escaping @MainActor () -> Void
    ) {
        // One tick first: at `onAppear` the text view isn't in the window yet, so
        // there is no view controller to ask about the transition (and nothing to
        // give first responder to).
        DispatchQueue.main.async {
            let transition = controller.view?.owningViewController?.transitionCoordinator
                .map(EditorFocusPushTransition.init)
            // The handoff keyboard's first presentation already happened on a
            // settled source screen, so moving its responder to the mounted
            // editor during the push is safe. Doing this now gives prediction
            // the real document context while keyboard + navigation are still
            // moving; waiting for the completion made the suggestion row pop in
            // only after everything else had landed.
            if let editor = controller.view {
                EditorKeyboardHandoff.transfer(to: editor, target: target)
            }
            focus(after: transition) {
                action()
                // A transfer the destination refused (a still-read-only editor,
                // a title that isn't editable yet) leaves the proxy holding the
                // keyboard. Once the real focus has happened it is only litter.
                EditorKeyboardHandoff.discardIfNotFirstResponder()
            }
        }
    }

    /// Split out from `schedule` so the rule — and only the rule — is testable
    /// without staging a real navigation push.
    static func focus(after transition: EditorFocusTransition?, _ action: @escaping @MainActor () -> Void) {
        // No transition to wait for: the pane is already on screen, so focusing
        // now is both safe and what the user expects.
        guard let transition else {
            action()
            return
        }
        // A coordinator refuses new work once the transition is already ending,
        // in which case the point of waiting has passed.
        if !transition.runAfterTransition(action) {
            action()
        }
    }
}

/// The part of a running screen transition `EditorAutoFocus` depends on.
@MainActor
protocol EditorFocusTransition {
    /// Runs `completion` when the transition finishes. False if it could not be
    /// scheduled at all.
    func runAfterTransition(_ completion: @escaping @MainActor () -> Void) -> Bool
}

struct EditorFocusPushTransition: EditorFocusTransition {
    let coordinator: UIViewControllerTransitionCoordinator

    func runAfterTransition(_ completion: @escaping @MainActor () -> Void) -> Bool {
        coordinator.animate(alongsideTransition: nil) { _ in
            MainActor.assumeIsolated { completion() }
        }
    }
}

extension UIResponder {
    /// The nearest view controller up the responder chain — the one whose
    /// `transitionCoordinator` describes the push this view arrived in.
    var owningViewController: UIViewController? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

@MainActor
final class EditorController: ObservableObject {
    weak var view: EditorTextView?
    @Published var isDirty = false
    @Published var isEmpty = true
    // Fired on every keystroke/structural edit (see `markDirty`). The editor view
    // observes it to debounce a live flush of the edits into the core (so a phone
    // edit pushes within ~1 s like desktop, instead of only on blur). A plain
    // subject — deliberately NOT @Published — so typing doesn't re-render the
    // SwiftUI pane (and re-run updateUIView's layout-invalidating UIKit setters)
    // on every character.
    let editPulse = PassthroughSubject<Void, Never>()
    // Bumped on every keystroke/structural edit, alongside `editPulse`. Async core
    // writes capture it before enqueuing so their completion can tell "nothing
    // happened while I was in flight" from "the user kept typing" — `isDirty` can't
    // answer that (a flush deliberately leaves it set, see `flushLive`). A
    // completion that reloads the text view MUST check it, or it reinstalls the
    // pre-write text over keystrokes the user made during the write.
    var editEpoch: UInt64 = 0
    // The items as of the last load/flush — what the core already knows from
    // this editor. A remote change that lands mid-edit diffs the live text
    // against this to tell the user's unflushed lines from everything else
    // (see `mergeRemoteSchemeItems`).
    var baselineItems: [MobileItem] = []
    private var pendingImageLocation: Int?

    func load(items: [MobileItem], theme: KnotQTheme, timeFormat: String, placeCursorAtEnd: Bool = false) {
        view?.loadItems(items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: placeCursorAtEnd)
        baselineItems = items
        isDirty = false
        isEmpty = items.isEmpty || items.allSatisfy {
            $0.text.isEmpty
                && $0.marker == "blank"
                && $0.indent == 0
                && $0.start == nil
                && $0.end == nil
                && $0.media.isEmpty
                && $0.tables.isEmpty
        }
    }

    /// Reload the document from `items` (e.g. a remote change pulled in while the
    /// user is mid-edit) while keeping the caret and scroll where they were, so a
    /// concurrent incoming edit doesn't yank the view around. The caret re-anchors
    /// by line identity plus a UTF-16 edit-position mapping inside that line —
    /// absolute offsets go stale as soon as the change touches anything above or
    /// before the caret — falling back to the clamped absolute offset when the
    /// caret's line is gone.
    func reloadPreservingCaret(items: [MobileItem], theme: KnotQTheme, timeFormat: String) {
        guard let view else {
            load(items: items, theme: theme, timeFormat: timeFormat)
            return
        }
        let context = view.caretContext()
        let savedSelection = view.selectedRange
        let savedOffset = view.contentOffset
        let wasFirstResponder = view.isFirstResponder
        load(items: items, theme: theme, timeFormat: timeFormat)
        let length = (view.text as NSString).length
        if let location = view.caretLocation(for: context) {
            view.selectedRange = NSRange(location: location, length: 0)
        } else {
            let location = min(savedSelection.location, length)
            view.selectedRange = NSRange(
                location: location,
                length: min(savedSelection.length, max(0, length - location))
            )
        }
        if wasFirstResponder { _ = view.becomeFirstResponder() }
        if view.isScrollEnabled {
            // Re-taking first responder can autoscroll; pin the document back.
            view.setContentOffset(view.clampedContentOffset(savedOffset), animated: false)
        }
    }

    /// A table cell is being edited in place. Its edits write straight to the
    /// model, so the document reload is redundant (the cell editor already shows
    /// them) — except when a structural change is pending a retarget.
    var isEditingTableCell: Bool { view?.isEditingTableCell ?? false }
    var hasPendingCellFocus: Bool { view?.hasPendingCellFocus ?? false }

    func commit() -> [MobileItemEdit] {
        view?.endTableCellEditing(commit: true)
        return view?.extractItemEdits() ?? []
    }

    /// Adopt core-minted ids for lines this editor created, without a reload
    /// (the caret must not move mid-type). See `EditorTextView.adoptItemIDs`.
    func adoptItemIDs(from items: [MobileItem]) {
        view?.adoptItemIDs(from: items)
    }

    func flushCellEdit() {
        view?.endTableCellEditing(commit: true)
    }

    func appendTaskLine(theme: KnotQTheme) {
        view?.appendTaskLine(theme: theme)
        isEmpty = false
    }

    func currentLineItemID() -> String? {
        view?.currentLineItemID()
    }

    func setCurrentMarker(_ marker: Marker, theme: KnotQTheme) {
        view?.setCurrentMarker(marker, theme: theme)
        if marker != .blank {
            isEmpty = false
        }
    }

    func shiftCurrentIndent(_ delta: Int, theme: KnotQTheme) {
        view?.shiftCurrentIndent(delta, theme: theme)
    }

    func prepareImageUploadTarget() {
        pendingImageLocation = view?.selectedRange.location
    }

    func attachImageMedia(_ media: MobileItemMedia, theme: KnotQTheme) {
        view?.attachImageMedia(media, at: pendingImageLocation, theme: theme)
        pendingImageLocation = nil
        isEmpty = false
    }

    func insertTableBlock(itemID: String, theme: KnotQTheme) {
        view?.insertTableBlock(itemID: itemID, theme: theme)
        isEmpty = false
    }

    /// Activates the text view so the system shows the caret + keyboard.
    func focus() {
        guard let view, !view.isFirstResponder else { return }
        _ = view.becomeFirstResponder()
    }

    func blur() {
        // Flush any in-place table cell edit before the document loses focus so
        // its text isn't dropped.
        view?.endTableCellEditing(commit: true)
        _ = view?.resignFirstResponder()
    }

    @discardableResult
    func focusTitle() -> Bool {
        view?.focusTitle() ?? false
    }
}
