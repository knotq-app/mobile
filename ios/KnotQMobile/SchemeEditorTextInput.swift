import SwiftUI
import UIKit

/// Host view for the formatting toolbar above the keyboard.
final class TransparentInputAccessoryView: UIInputView {
    /// The bar's own height. Kept as a stored value rather than read back off
    /// `frame`: deriving the intrinsic size from the frame is circular, so the
    /// first frame UIKit happens to hand this view becomes its permanent
    /// intrinsic height. During keyboard presentation that frame is briefly the
    /// height of the whole keyboard.
    private let preferredHeight: CGFloat

    init(frame: CGRect) {
        preferredHeight = frame.height > 0 ? frame.height : 44
        super.init(frame: frame, inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false
        insetsLayoutMarginsFromSafeArea = false
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearAccessoryChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearAccessoryChrome()
    }

    func clearAccessoryChrome() {
        var next: UIView? = self
        for _ in 0..<8 {
            next?.backgroundColor = .clear
            next?.isOpaque = false
            next = next?.superview
        }
    }
}

/// The floating rounded bar that an input accessory draws its controls on.
///
/// A plain view with a solid fill — deliberately **not** a `UIVisualEffectView`.
/// A live material anywhere inside an input accessory makes the system keyboard
/// present wrong on the first focus of a process: instead of sliding up, it
/// zooms in from the lower-right over a flat grey backdrop — rgb(149,152,155)
/// against the settled keyboard's rgb(216,218,221) — and holds that for ~350 ms
/// before snapping to the real keyboard. Bisected on iOS 26 by swapping just the
/// effect: `UIGlassEffect` and `UIBlurEffect(.systemUltraThinMaterial)` both
/// reproduced it; `UIVisualEffectView(effect: nil)` did not (min sampled
/// backdrop 218 — no dip at all). Presumably the keyboard's own backdrop and the
/// accessory's have to resolve against each other, and the first pass has
/// nothing to resolve against yet.
///
/// Nothing is lost by giving it up: the bars already backed their glass with an
/// opaque `bgApp` view (so scrolling text underneath couldn't tint them), which
/// left the material with a flat constant colour to sample. Screenshot diff of
/// the settled bar, glass vs. flat: mean 2.8/255, max 11 — invisible. This is
/// that same flat colour, painted directly.
final class AccessoryBarPanel: UIView {
    init(theme: KnotQTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(theme.bgApp)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor(theme.borderOverlay).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}



// MARK: - Editor coordinator

@MainActor
final class EditorCoordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate, UIGestureRecognizerDelegate {
    weak var view: EditorTextView?
    weak var controller: EditorController?
    var theme: KnotQTheme = .dark
    var accentColor: UIColor = .systemBlue
    var onDateRequested: (() -> Void)?
    var onImageUploadRequested: (() -> Void)?
    var onInsertTableRequested: (() -> Void)?
    var readOnly = false
    weak var checkboxTapRecognizer: UITapGestureRecognizer?

    var suppressDelegateDepth = 0
    var autoBulletizePending = false
    var blockIsolationPending = false
    var embeddedDisplayRefreshPending = false
    var autoBulletUndo: (lineLocation: Int, originalBody: String)?

    // Toolbar marker buttons keyed by Marker, so we can tint the active one.
    var markerButtons: [Marker: UIButton] = [:]

    func suppress(_ block: () -> Void) {
        suppressDelegateDepth += 1
        defer { suppressDelegateDepth -= 1 }
        block()
    }

    func markDirty() {
        guard !readOnly else { return }
        // Guard the @Published write: markDirty runs on every keystroke, and an
        // unguarded re-assignment of an unchanged value still fires
        // objectWillChange — re-rendering the whole SwiftUI pane (and re-running
        // updateUIView, whose UIKit setters invalidate text layout) per character.
        if controller?.isDirty != true {
            controller?.isDirty = true
        }
        controller?.editEpoch &+= 1
        // Drives the editor's debounced live flush to the core (push-on-type).
        controller?.editPulse.send()
    }

    func refreshEmpty() {
        guard let view, let controller else { return }
        let empty = view.isEffectivelyEmpty()
        if controller.isEmpty != empty {
            controller.isEmpty = empty
        }
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        // Invariants are restored from `textStorage(_:didProcessEditing:...)`.
        markDirty()
        refreshEmpty()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // I3: the caret is never past the trailing "\n". Clamp collapsed caret
        // to length - 1 so taps at the very end stay on the last visible line.
        if textView.selectedRange.length == 0 {
            let storage = textView.textStorage
            let maxCaret = max(0, storage.length - 1)
            if textView.selectedRange.location > maxCaret {
                textView.selectedRange = NSRange(location: maxCaret, length: 0)
                textView.typingAttributes = EditorAttributes.bodyAttributes(
                    meta: lineMeta(at: maxCaret, in: storage),
                    theme: theme
                )
            }
        }
        refreshToolbarActiveMarker(in: textView)
        // Reveal markers on the line the caret just moved to, hide the rest.
        (textView as? EditorTextView)?.refreshMarkerVisibility()
    }

    /// Highlights the toolbar marker button matching the caret's line.
    func refreshToolbarActiveMarker(in textView: UITextView) {
        let storage = textView.textStorage
        let caret = clampedCaret(textView.selectedRange.location, in: storage)
        let active = lineMeta(at: caret, in: storage).marker
        for (marker, button) in markerButtons {
            button.tintColor = UIColor(marker == active ? theme.textPrimary : theme.textDim)
        }
    }

    @objc func handleEditorTap(_ recognizer: UITapGestureRecognizer) {
        guard !readOnly else { return }
        guard recognizer.state == .ended, let view else { return }
        let point = recognizer.location(in: view)
        if let hit = view.tableCellHit(at: point) {
            // Edit the cell in place rather than opening a modal sheet.
            view.beginEditingTableCell(hit)
            return
        }
        // A tap outside any cell ends in-place cell editing (and flushes it).
        if view.isEditingTableCell {
            view.endTableCellEditing(commit: true)
        }
        if view.toggleCheckboxAt(point: point) {
            return
        }
        // A tap in a block's gutter (beside it) or the seam just above/below
        // places the caret before/after the block. UITextView ignores taps in
        // that empty margin, so do it ourselves.
        _ = view.placeCaretAtBlockEdge(at: point)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === checkboxTapRecognizer, !readOnly else { return false }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === checkboxTapRecognizer, let view else { return false }
        // Our checkbox/table tap and UITextView's built-in caret-positioning tap
        // are both single-tap recognizers. Without allowing them to recognize
        // simultaneously they are mutually exclusive and ours wins, so a single
        // tap on plain text (a no-op for us) stops moving the cursor and the only
        // way to position the caret is a long-press.
        //
        // On a table cell tap we take over caret placement and focus ourselves
        // (the in-place cell editor), so stay exclusive there to keep UITextView's
        // tap from fighting for first responder. Everywhere else, let both fire so
        // a tap positions the caret (and toggles a checkbox).
        let point = gestureRecognizer.location(in: view)
        if view.tableCellHit(at: point) != nil {
            return false
        }
        // Everywhere else (plain text AND a block's gutter/seam) stay simultaneous
        // so our recognizer reliably reaches `.ended` and runs `handleEditorTap`.
        // Going exclusive here would make *our* tap lose to UITextView's built-in
        // tap (a cell tap only "wins" because it steals first responder), so the
        // explicit gutter caret placement would never fire.
        return true
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !readOnly else { return false }
        guard let view = textView as? EditorTextView else { return true }
        if text.isEmpty && range.length > 0, view.deleteSelectedBlockParagraphsIfNeeded(in: range) {
            autoBulletUndo = nil
            return false
        }
        if text == "\n" && range.length == 0 {
            return !handleEnter(in: view, at: range.location)
        }
        if text.isEmpty && range.length == 1 {
            if handleAutoBulletUndo(in: view, deletionRange: range) {
                return false
            }
            if handleClearMarkerBackspace(in: view, deletionRange: range) {
                return false
            }
            // Refuse a backspace that would merge a block (image/table) line with
            // a non-empty text line — the block stays alone on its line (I4). The
            // block's own glyph still deletes natively (it is one real character).
            if handleBlockMergeGuard(in: view, deletionRange: range) {
                return false
            }
            if handleMergeParagraphs(in: view, deletionRange: range) {
                return false
            }
        }
        // Typing a real character while the caret sits on a block line: redirect
        // it onto a fresh adjacent text line so the block keeps its own line (I4).
        if !text.isEmpty, range.length == 0, handleTypingOnBlockLine(in: view, range: range, text: text) {
            autoBulletUndo = nil
            return false
        }
        // Any non-backspace edit clears the pending auto-bullet undo.
        if !(text.isEmpty && range.length == 1) {
            autoBulletUndo = nil
        }
        return true
    }

}

// MARK: - EditorTextView
