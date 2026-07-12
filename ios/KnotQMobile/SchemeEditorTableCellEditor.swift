import SwiftUI
import UIKit

struct EditorTableCellHit {
    let itemID: String
    let tableIndex: Int
    let row: Int
    let column: Int
    let text: String
    /// The cell's drawn frame in the text view's content coordinate space, used
    /// to position the in-place cell editor exactly over the tapped cell.
    let frame: CGRect

    var isHeader: Bool { row < 0 }

    func withText(_ text: String) -> EditorTableCellHit {
        EditorTableCellHit(
            itemID: itemID,
            tableIndex: tableIndex,
            row: row,
            column: column,
            text: text,
            frame: frame
        )
    }
}

private final class EditorTableInputAccessoryView: UIInputView {
    init(height: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false
        insetsLayoutMarginsFromSafeArea = false
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: bounds.height > 0 ? bounds.height : 52)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearAccessoryChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearAccessoryChrome()
    }

    private func clearAccessoryChrome() {
        var next: UIView? = self
        for _ in 0..<8 {
            next?.backgroundColor = .clear
            next?.isOpaque = false
            next = next?.superview
        }
    }
}

/// How an in-place cell edit resolved, so the owning text view knows where to
/// move the caret next.
enum EditorCellCommitReason {
    /// Field resigned (tap elsewhere / keyboard dismissed): stop editing.
    case resign
    /// Explicit move-down command: commit and move to the cell directly below.
    case moveDown
    /// Tab pressed: commit and move to the next cell (left→right, wrapping rows).
    case moveNext
    /// Shift-Tab pressed: commit and move to the previous cell.
    case movePrevious
}

/// Table structure ops reachable from the cell editor's accessory bar.
enum EditorCellStructureAction {
    case insertRowAbove, insertRowBelow, deleteRow
    case insertColumnLeft, insertColumnRight, deleteColumn
}

/// A multiline editable field overlaid exactly on a drawn table cell. Replaces
/// the old full-screen `TableCellEditSheet` so cell text is edited in place. The
/// owning `EditorTextView` positions it over the cell's frame, prefills it from
/// the cell's full text, and drives Tab navigation. Commits route back
/// to the core via the view's `onCellCommit` closure.
final class EditorTableCellEditor: UIView, UITextViewDelegate {
    let field = UITextView()
    private(set) var hit: EditorTableCellHit
    /// Called with the committed text and how the edit ended. The owner persists
    /// the text and, for the move reasons, focuses the resolved neighbor cell.
    var onCommit: ((EditorTableCellHit, String, EditorCellCommitReason) -> Void)?
    /// Row/column structure ops from the accessory bar. The owner runs the op and
    /// keeps the editor mounted, retargeting it onto the resulting cell once the
    /// grid reloads (so the keyboard stays up across the change).
    var onStructureAction: ((EditorTableCellHit, EditorCellStructureAction) -> Void)?
    /// Persists the current cell text *without* ending the edit session. Used when
    /// this editor is reused for a neighboring cell (retarget) or kept alive across
    /// a structural change; the `.resign` path on `onCommit` would tear the editor
    /// down, which must not happen mid-reuse.
    var onFlush: ((EditorTableCellHit, String) -> Void)?
    /// Asks the owner to end the session (tear the editor down). The dismiss button
    /// flushes then calls this, so Done always removes the overlay — `onCommit`'s
    /// `.resign` only fires when the text changed, which used to leave a stray box.
    var onRequestEnd: (() -> Void)?
    private var committedText: String
    private var didCommit = false
    private let theme: KnotQTheme
    private weak var rowMenuButton: UIButton?
    /// The drawn cell's natural height. The overlay grows past this to fit text
    /// being typed, but never shrinks below it (the drawn table only reflows once
    /// the edit commits).
    private var baseHeight: CGFloat
    /// Cap on how tall the overlay grows before its text scrolls internally, so a
    /// long note can't push the editing surface off-screen / under the keyboard.
    private let maxGrownHeight: CGFloat = 220

    init(hit: EditorTableCellHit, theme: KnotQTheme) {
        self.hit = hit
        self.committedText = hit.text
        self.theme = theme
        self.baseHeight = hit.frame.height
        super.init(frame: hit.frame)
        backgroundColor = UIColor(theme.bgModal)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(theme.accent).cgColor
        layer.cornerRadius = 3

        field.text = hit.text
        field.font = .systemFont(ofSize: 13)
        field.textColor = UIColor(theme.textPrimary)
        field.tintColor = UIColor(theme.accent)
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        field.isScrollEnabled = true
        field.alwaysBounceVertical = false
        field.autocorrectionType = .no
        field.autocapitalizationType = .sentences
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.returnKeyType = .default
        field.delegate = self
        field.inputAccessoryView = makeAccessory()
        addSubview(field)
    }

    /// Bar above the keyboard for the in-place cell editor. Keep it tight:
    /// dismiss keyboard plus row/column structure menus.
    private func makeAccessory() -> UIView {
        let height: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 56 : 50
        let container = EditorTableInputAccessoryView(height: height)

        let backdrop: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .clear
        backdrop.isOpaque = false
        backdrop.contentView.backgroundColor = .clear
        backdrop.layer.cornerRadius = 10
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        backdrop.layer.borderWidth = 1
        backdrop.layer.borderColor = UIColor(theme.borderOverlay).cgColor
        container.addSubview(backdrop)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.insetsLayoutMarginsFromSafeArea = false
        backdrop.contentView.addSubview(stack)

        let dismissButton = accessoryIconButton("keyboard.chevron.compact.down", label: L10n.t("editor.table.done_editing_cell")) { [weak self] in
            self?.flush()
            self?.onRequestEnd?()
        }

        let rowMenu = structureMenuButton(
            title: L10n.t("editor.table.rows_menu_title"),
            systemImage: "tablecells",
            actions: [
                (title: L10n.t("editor.table.insert_row_above"), systemImage: "arrow.up.to.line", action: .insertRowAbove, destructive: false),
                (title: L10n.t("editor.table.insert_row_below"), systemImage: "arrow.down.to.line", action: .insertRowBelow, destructive: false),
                (title: L10n.t("editor.context.delete_row"), systemImage: "trash", action: .deleteRow, destructive: true)
            ]
        )
        let columnMenu = structureMenuButton(
            title: L10n.t("editor.table.columns_menu_title"),
            systemImage: "tablecells",
            actions: [
                (title: L10n.t("editor.table.insert_column_left"), systemImage: "arrow.left.to.line", action: .insertColumnLeft, destructive: false),
                (title: L10n.t("editor.table.insert_column_right"), systemImage: "arrow.right.to.line", action: .insertColumnRight, destructive: false),
                (title: L10n.t("editor.context.delete_column"), systemImage: "trash", action: .deleteColumn, destructive: true)
            ]
        )
        rowMenuButton = rowMenu

        stack.addArrangedSubview(dismissButton)
        stack.addArrangedSubview(rowMenu)
        stack.addArrangedSubview(columnMenu)

        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: UIDevice.current.userInterfaceIdiom == .phone ? -10 : -6),
            stack.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor)
        ])
        updateAccessoryState()
        return container
    }

    private func accessoryIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        config.baseForegroundColor = UIColor(theme.accent)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func structureMenuButton(
        title: String,
        systemImage: String,
        actions: [(title: String, systemImage: String, action: EditorCellStructureAction, destructive: Bool)]
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        config.baseForegroundColor = UIColor(theme.textPrimary)
        var titleContainer = AttributeContainer()
        titleContainer.font = .systemFont(ofSize: 12, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: titleContainer)
        let button = UIButton(configuration: config)
        button.menu = UIMenu(children: actions.map { entry in
            let attributes: UIMenuElement.Attributes = entry.destructive ? .destructive : []
            return UIAction(
                title: entry.title,
                image: UIImage(systemName: entry.systemImage),
                attributes: attributes
            ) { [weak self] _ in
                self?.runStructure(entry.action)
            }
        })
        button.showsMenuAsPrimaryAction = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func updateAccessoryState() {
        let rowsEditable = !hit.isHeader
        rowMenuButton?.isEnabled = rowsEditable
        rowMenuButton?.alpha = rowsEditable ? 1 : 0.35
    }

    private func runStructure(_ action: EditorCellStructureAction) {
        if hit.isHeader {
            switch action {
            case .insertRowAbove, .insertRowBelow, .deleteRow:
                return
            case .insertColumnLeft, .insertColumnRight, .deleteColumn:
                break
            }
        }
        // Persist any in-progress text first so the structural change keeps it
        // (flush, not commit — committing would tear the editor down), then hand
        // off to the owner, which mutates the model and retargets us post-reload.
        flush()
        onStructureAction?(hit, action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Match `drawTableText`'s 7pt inset so the text sits where it rendered.
        field.frame = bounds.insetBy(dx: 7, dy: 7)
    }

    /// Reposition the field over a (possibly new) cell without tearing down the
    /// first responder — used when navigating between cells. Flushes (not commits)
    /// the outgoing text so reuse doesn't trip the `.resign` teardown.
    func retarget(to hit: EditorTableCellHit) {
        flush()
        self.hit = hit
        committedText = hit.text
        didCommit = false
        baseHeight = hit.frame.height
        frame = hit.frame
        field.text = hit.text
        updateAccessoryState()
        field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
        growToFitContent()
    }

    /// Grows the overlay downward so every line being typed stays visible. The
    /// drawn cell can't reflow until the edit commits, so without this the added
    /// lines just scroll out of a one-row-tall box. Capped at `maxGrownHeight`,
    /// past which `field` scrolls internally to keep the caret in view.
    private func growToFitContent() {
        // Width available to text matches `layoutSubviews`' 7pt inset on each side.
        let textWidth = max(1, bounds.width - 14)
        let fitted = field.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let desired = min(max(baseHeight, ceil(fitted) + 14), maxGrownHeight)
        if abs(desired - bounds.height) > 0.5 {
            frame.size.height = desired
        }
    }

    /// Persists the current text (if it changed) and keeps the editor alive. The
    /// owner's `onFlush` only writes to the model — unlike `commit(reason: .resign)`
    /// it never removes the editor — so it is safe to call while reusing the editor
    /// for another cell or across a structural change.
    private func flush() {
        let text = field.text ?? ""
        guard text != committedText else { return }
        committedText = text
        hit = hit.withText(text)
        didCommit = true
        onFlush?(hit, text)
    }

    func focus() {
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
    }

    /// Focus and select the whole cell, so the next keystroke replaces it. Used
    /// when Tab/arrow navigation lands on a cell (matching the desktop editor),
    /// unlike a tap-to-edit which places a caret.
    func focusSelectingAll() {
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: 0, length: (field.text as NSString).length)
    }

    /// Persists the current text if it changed. `reason` nil means "flush only"
    /// (no navigation); callers pass an explicit reason to also move.
    func commit(reason: EditorCellCommitReason?) {
        let text = field.text ?? ""
        if text != committedText {
            committedText = text
            didCommit = true
            onCommit?(hit, text, reason ?? .resign)
        } else if let reason, reason != .resign {
            // No text change but the user asked to move — let the owner navigate.
            onCommit?(hit, text, reason)
        }
    }

    /// Prevents `textViewDidEndEditing` from treating a programmatic teardown as
    /// a user resign that should commit the current draft.
    func discardOnEndEditing() {
        didCommit = true
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        growToFitContent()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Only treat as a plain resign if no explicit navigation already fired.
        if !didCommit {
            commit(reason: .resign)
        }
        didCommit = false
    }

    // Hardware-keyboard Tab / Shift-Tab navigation between cells.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTab)),
        ]
    }

    @objc private func handleTab() { commit(reason: .moveNext) }
    @objc private func handleShiftTab() { commit(reason: .movePrevious) }
}

