import SwiftUI
import UIKit

// MARK: - Theme helpers

private extension KnotQTheme {
    var editorChromeColor: UIColor {
        UIColor(hex: isDark ? 0xb8c9e8 : 0x536a8f)
    }
}

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
}

enum EditorTableBoundarySide {
    case before, after
}

struct EditorTableBoundaryHit {
    let paragraphRange: NSRange
    let side: EditorTableBoundarySide
}

private struct EditorTableCellHitRect {
    let rect: CGRect
    let hit: EditorTableCellHit
}

private struct EditorTableBlockHitRect {
    let rect: CGRect
    let paragraphRange: NSRange
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
    /// Return pressed: commit and move to the cell directly below.
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

/// A single-line editable field overlaid exactly on a drawn table cell. Replaces
/// the old full-screen `TableCellEditSheet` so cell text is edited in place. The
/// owning `EditorTextView` positions it over the cell's frame, prefills it from
/// the cell's first line, and drives Tab / Return navigation. Commits route back
/// to the core via the view's `onCellCommit` closure.
final class EditorTableCellEditor: UIView, UITextFieldDelegate {
    let field = UITextField()
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

    init(hit: EditorTableCellHit, theme: KnotQTheme) {
        self.hit = hit
        self.committedText = hit.text
        self.theme = theme
        super.init(frame: hit.frame)
        backgroundColor = UIColor(theme.bgModal)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(theme.accent).cgColor
        layer.cornerRadius = 3

        field.text = hit.text
        field.font = .systemFont(ofSize: 13)
        field.textColor = UIColor(theme.textPrimary)
        field.tintColor = UIColor(theme.accent)
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .sentences
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.clearButtonMode = .never
        field.returnKeyType = .next
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

        let dismissButton = accessoryIconButton("keyboard.chevron.compact.down", label: "Done editing cell") { [weak self] in
            self?.flush()
            self?.onRequestEnd?()
        }

        let rowMenu = structureMenuButton(
            title: "Rows",
            systemImage: "tablecells",
            actions: [
                (title: "Insert Row Above", systemImage: "arrow.up.to.line", action: .insertRowAbove, destructive: false),
                (title: "Insert Row Below", systemImage: "arrow.down.to.line", action: .insertRowBelow, destructive: false),
                (title: "Delete Row", systemImage: "trash", action: .deleteRow, destructive: true)
            ]
        )
        let columnMenu = structureMenuButton(
            title: "Columns",
            systemImage: "tablecells",
            actions: [
                (title: "Insert Column Left", systemImage: "arrow.left.to.line", action: .insertColumnLeft, destructive: false),
                (title: "Insert Column Right", systemImage: "arrow.right.to.line", action: .insertColumnRight, destructive: false),
                (title: "Delete Column", systemImage: "trash", action: .deleteColumn, destructive: true)
            ]
        )
        rowMenuButton = rowMenu
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(dismissButton)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(rowMenu)
        stack.addArrangedSubview(columnMenu)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
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
        frame = hit.frame
        field.text = hit.text
        updateAccessoryState()
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
    }

    /// Persists the current text (if it changed) and keeps the editor alive. The
    /// owner's `onFlush` only writes to the model — unlike `commit(reason: .resign)`
    /// it never removes the editor — so it is safe to call while reusing the editor
    /// for another cell or across a structural change.
    private func flush() {
        let text = field.text ?? ""
        guard text != committedText else { return }
        committedText = text
        didCommit = true
        onFlush?(hit, text)
    }

    func focus() {
        field.becomeFirstResponder()
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
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

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commit(reason: .moveDown)
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
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

private final class EditorInlineTitleView: UIView, UITextFieldDelegate {
    private let textField = UITextField()
    private let errorLabel = UILabel()
    private var committedTitle = ""
    private var validator: ((String) -> String?)?
    private var onCommit: ((String) -> Void)?
    private var normalTintColor: UIColor = .systemBlue
    private var errorTintColor: UIColor = .systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        textField.borderStyle = .none
        textField.font = .systemFont(ofSize: DesktopEditorMetrics.titleFontSize, weight: .bold)
        textField.returnKeyType = .done
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .never
        textField.autocorrectionType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        addSubview(textField)

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.numberOfLines = 1
        addSubview(errorLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, theme: KnotQTheme, visible: Bool, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        self.validator = validator
        self.onCommit = onCommit
        isHidden = !visible
        textField.textColor = UIColor(theme.textPrimary)
        normalTintColor = UIColor(theme.accent)
        errorTintColor = UIColor(theme.danger)
        errorLabel.textColor = errorTintColor
        textField.isUserInteractionEnabled = visible && editable
        if !textField.isFirstResponder {
            committedTitle = title
            textField.text = title
        }
        if (!visible || !editable), textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        updateError()
    }

    func focusAndSelectTitle() {
        guard textField.isUserInteractionEnabled else { return }
        textField.becomeFirstResponder()
        textField.selectAll(nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textField.frame = CGRect(x: 0, y: 0, width: bounds.width, height: DesktopEditorMetrics.titleLineHeight)
        errorLabel.frame = CGRect(x: 0, y: DesktopEditorMetrics.titleLineHeight - 1, width: bounds.width, height: 13)
    }

    @objc private func textDidChange() {
        updateError()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitTitle()
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitTitle()
    }

    private func commitTitle() {
        let draft = textField.text ?? ""
        let validationError = validator?(draft)
        updateError(validationError)
        guard validationError == nil, draft != committedTitle else { return }
        committedTitle = draft
        onCommit?(draft)
    }

    private func updateError(_ validationError: String? = nil) {
        let error = validationError ?? validator?(textField.text ?? "")
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        textField.tintColor = error == nil ? normalTintColor : errorTintColor
    }
}

final class EditorTextView: UITextView {
    var theme: KnotQTheme = .dark { didSet { setNeedsDisplay() } }
    var accentColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
    var timeFormat = "twelve_hour"
    weak var coordinator: EditorCoordinator?

    private let inlineTitleView = EditorInlineTitleView()
    private let editorLayoutManager: EditorLayoutManager
    private var imageCache: [String: UIImage] = [:]
    private var renderedTableCellHits: [EditorTableCellHitRect] = []
    private var renderedTableBlockHits: [EditorTableBlockHitRect] = []
    /// The in-place table cell editor, present only while a cell is being edited.
    private var activeCellEditor: EditorTableCellEditor?
    /// A cell to re-focus once the next document reload settles. Set right before a
    /// model mutation that reloads the document and changes table geometry (a
    /// row/column structural change). `loadItems` consumes it after layout so the
    /// in-place editor lands on the freshly drawn cell instead of a stale rect —
    /// and the keyboard stays up across the change.
    private var pendingCellFocus: (itemID: String, tableIndex: Int, row: Int, column: Int)?
    /// Persists a committed cell-line edit (wired by the coordinator to the
    /// model's `setTableCellLineText`).
    var onTableCellCommit: ((EditorTableCellHit, String) -> Void)?
    /// Table structure ops invoked from the cell editor's keyboard accessory
    /// (row/column at the edited cell). Each takes the active cell hit.
    var onTableInsertRow: ((EditorTableCellHit, Int) -> Void)?
    var onTableDeleteRow: ((EditorTableCellHit) -> Void)?
    var onTableInsertColumn: ((EditorTableCellHit, Int) -> Void)?
    var onTableDeleteColumn: ((EditorTableCellHit) -> Void)?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        editorLayoutManager = layoutManager
        super.init(frame: .zero, textContainer: textContainer)
        layoutManager.editorTextView = self
        addSubview(inlineTitleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var lastIntrinsicWidth: CGFloat = 0
    private var measurementWidth: CGFloat?
    private var cachedFitSize = CGSize(width: -1, height: -1)

    override func invalidateIntrinsicContentSize() {
        cachedFitSize = CGSize(width: -1, height: -1)
        super.invalidateIntrinsicContentSize()
    }

    /// Exact content height for a proposed layout width; drives the Daily
    /// feed's self-sizing sections. Media/annotation spacing is routed through
    /// `measurementWidth` so image scaling matches the width being proposed
    /// rather than the (possibly stale or zero) current bounds.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if cachedFitSize.width == width { return cachedFitSize.height }
        measurementWidth = width
        defer { measurementWidth = nil }
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitted.height)
        cachedFitSize = CGSize(width: width, height: height)
        return height
    }

    override func becomeFirstResponder() -> Bool {
        // The formatting toolbar is built on demand: the Daily feed mounts an
        // editor per day while scrolling, and only a focused one shows it.
        if isEditable, inputAccessoryView == nil, let coordinator {
            inputAccessoryView = coordinator.makeToolbar(for: self)
        }
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.refreshToolbarActiveMarker(in: self)
            refreshMarkerVisibility(force: true)
            refreshEmbeddedLayoutIfNeeded(deferred: true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Collapse every marker once editing ends for a clean preview.
            refreshMarkerVisibility(force: true)
        }
        return resigned
    }

    /// Reveals markdown markers on the caret's line(s) and collapses them
    /// elsewhere (all markers when not editing). Re-renders only the lines whose
    /// visibility changed unless `force` is set.
    func refreshMarkerVisibility(force: Bool = false) {
        guard textStorage.length > 0 else { return }
        let revealed: NSRange
        if isFirstResponder {
            let ns = textStorage.string as NSString
            let sel = selectedRange
            let startLoc = clampedCaret(sel.location, in: textStorage)
            let endProbe = NSMaxRange(sel) > sel.location ? NSMaxRange(sel) - 1 : sel.location
            let endLoc = clampedCaret(endProbe, in: textStorage)
            let startPara = editableParagraphRange(in: ns, at: startLoc)
            let endPara = editableParagraphRange(in: ns, at: endLoc)
            revealed = NSUnionRange(startPara, endPara)
        } else {
            revealed = NSRange(location: 0, length: 0)
        }
        if editorLayoutManager.setRevealedRange(revealed, force: force) {
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineTitleView()
        // With scrolling disabled (Daily feed), recompute intrinsic height after
        // the parent grants a width — otherwise wrapping is calculated against
        // an unbounded container and the text never breaks.
        if !isScrollEnabled, bounds.width != lastIntrinsicWidth {
            lastIntrinsicWidth = bounds.width
            refreshEmbeddedLayoutIfNeeded()
        }
    }

    func refreshEmbeddedLayoutIfNeeded(deferred: Bool = false) {
        guard !isScrollEnabled else { return }
        if deferred {
            DispatchQueue.main.async { [weak self] in
                self?.refreshEmbeddedLayoutIfNeeded()
            }
            return
        }
        invalidateIntrinsicContentSize()
        layoutManager.ensureLayout(for: textContainer)
        if contentOffset != .zero {
            setContentOffset(.zero, animated: false)
        }
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Defer width to the parent layout; only height is meaningful here.
        return CGSize(width: UIView.noIntrinsicMetric, height: fitted.height)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        // Image/annotation space is reserved *below* the text (as line spacing
        // after the glyph), which inflates the line fragment. Clamp the caret to
        // the line's text height and keep it pinned to the top of the fragment —
        // sitting on the text — instead of stretching down into the image or
        // centering in the gap. Headings keep their taller caret.
        let offset = offset(from: beginningOfDocument, to: position)
        let textHeight = caretLineIsHeading(at: offset)
            ? DesktopEditorMetrics.headingLineHeight
            : DesktopEditorMetrics.textLineHeight
        if rect.height > textHeight {
            rect.size.height = textHeight
        }
        rect.size.width = 2
        return rect
    }

    /// A line is a heading when its run carries the enlarged heading font.
    /// Probe both sides of the caret so it is detected at either line edge.
    private func caretLineIsHeading(at offset: Int) -> Bool {
        let length = textStorage.length
        guard length > 0 else { return false }
        for probe in [offset, offset - 1] where probe >= 0 && probe < length {
            if let font = textStorage.attribute(.font, at: probe, effectiveRange: nil) as? UIFont,
               font.pointSize >= DesktopEditorMetrics.headingFontSize - 0.5 {
                return true
            }
        }
        return false
    }

    func configureTitle(title: String, theme: KnotQTheme, visible: Bool, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        inlineTitleView.configure(title: title, theme: theme, visible: visible, editable: editable, validator: validator, onCommit: onCommit)
        setNeedsLayout()
    }

    func focusTitle() {
        inlineTitleView.focusAndSelectTitle()
    }

    private func layoutInlineTitleView() {
        let left = max(18, textContainerInset.left)
        let right = max(18, textContainerInset.right)
        let top = max(0, textContainerInset.top - DesktopEditorMetrics.titleBlockHeight + 4)
        inlineTitleView.frame = CGRect(
            x: left,
            y: top,
            width: max(0, bounds.width - left - right),
            height: DesktopEditorMetrics.titleBlockHeight
        )
    }

    func loadItems(_ items: [MobileItem], theme: KnotQTheme, timeFormat: String, placeCursorAtEnd: Bool) {
        let savedSelection = selectedRange
        self.theme = theme
        self.timeFormat = timeFormat
        coordinator?.suppress {
            let attributed = buildAttributedString(items: items, theme: theme, timeFormat: timeFormat)
            textStorage.setAttributedString(attributed)
            ensureWellFormed(textStorage, theme: theme)
        }
        let length = textStorage.length
        // I3: caret never past length - 1 (the trailing "\n").
        let targetLocation = placeCursorAtEnd
            ? max(0, length - 1)
            : clampedCaret(savedSelection.location, in: textStorage)
        selectedRange = NSRange(location: targetLocation, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: targetLocation, in: textStorage),
            theme: theme
        )
        layoutManager.ensureLayout(for: textContainer)
        refreshMarkerVisibility(force: true)
        if placeCursorAtEnd {
            if isScrollEnabled {
                scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
                // On first open the text view often has no real bounds yet, so the
                // initial scroll lands nowhere. Re-scroll to the end once layout has
                // settled so we reliably open at the very bottom of the document.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isScrollEnabled else { return }
                    self.scrollRangeToVisible(NSRange(location: max(0, self.textStorage.length - 1), length: 0))
                }
            }
        }
        refreshEmbeddedLayoutIfNeeded(deferred: true)
        setNeedsDisplay()
        coordinator?.markClean()
        consumePendingCellFocusIfNeeded()
    }

    func extractItemEdits() -> [MobileItemEdit] {
        coordinator?.suppress {
            textStorage.beginEditing()
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        return extractEdits(from: textStorage)
    }

    func isEffectivelyEmpty() -> Bool {
        // With invariant I1, "empty" = one paragraph (the trailing "\n") with
        // blank marker and zero indent.
        let ns = textStorage.string as NSString
        let paragraphs = paragraphRanges(in: ns)
        guard paragraphs.count <= 1 else { return false }
        guard let only = paragraphs.first else { return true }
        let body = bodyText(paragraphRange: only.fullRange, in: textStorage)
        let m = lineMeta(at: only.fullRange.location, in: textStorage)
        return body.isEmpty
            && m.marker == .blank
            && m.indent == 0
            && m.annotation == nil
            && m.media.isEmpty
            && m.tables.isEmpty
    }

    func appendTaskLine(theme: KnotQTheme) {
        let storage = textStorage
        let meta = LineMeta(marker: .checkbox)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        var lineStart = storage.length
        coordinator?.suppress {
            storage.beginEditing()
            ensureWellFormed(storage, theme: theme)
            // Append a new line just before the final trailing "\n" so it lives
            // as its own paragraph with the new marker.
            lineStart = storage.length
            storage.replaceCharacters(
                in: NSRange(location: storage.length, length: 0),
                with: NSAttributedString(string: "\n", attributes: attrs)
            )
            let para = editableParagraphRange(in: storage.string as NSString, at: lineStart)
            setLineMeta(meta, onParagraph: para, in: storage, theme: theme)
            storage.endEditing()
        }
        selectedRange = NSRange(location: lineStart, length: 0)
        typingAttributes = attrs
        coordinator?.markDirty()
        if !isFirstResponder {
            becomeFirstResponder()
        }
        setNeedsDisplay()
    }

    func currentLineItemID() -> String? {
        lineMeta(at: clampedCaret(selectedRange.location, in: textStorage), in: textStorage).itemID
    }

    func attachImageMedia(_ media: MobileItemMedia, at location: Int?, theme: KnotQTheme) {
        let caret = clampedCaret(location ?? selectedRange.location, in: textStorage)
        let paragraph = editableParagraphRange(in: textStorage.string as NSString, at: caret)
        let old = lineMeta(at: paragraph.location, in: textStorage)
        applyMeta(old.with(media: old.media + [media]), paragraphRange: paragraph, theme: theme)
        selectedRange = NSRange(location: caret, length: 0)
        invalidateIntrinsicContentSize()
    }

    override func copy(_ sender: Any?) {
        if copyRichSelectionToPasteboard() {
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else {
            copy(sender)
            return
        }
        if let paragraphs = richSelectedParagraphs(), copyRichSelectionToPasteboard(paragraphs: paragraphs) {
            deleteWholeParagraphs(paragraphs)
            return
        }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if pasteRichItemsFromPasteboard() {
            return
        }
        super.paste(sender)
    }

    override func deleteBackward() {
        // Backspace at column 0 of the first line: UITextView won't fire
        // shouldChangeTextIn here (nothing precedes the caret), so clear the
        // first line's marker directly instead of silently doing nothing.
        if coordinator?.handleClearMarkerAtDocumentStart(in: self) == true {
            return
        }
        super.deleteBackward()
    }

    func setCurrentMarker(_ marker: Marker, theme: KnotQTheme) {
        let para = editableParagraphRange(in: textStorage.string as NSString, at: selectedRange.location)
        let old = lineMeta(at: para.location, in: textStorage)
        let newDone = (marker == .checkbox && old.marker == .checkbox) ? !old.done : false
        let new = LineMeta(
            marker: marker,
            indent: old.indent,
            done: newDone,
            itemID: old.itemID,
            annotation: marker == .checkbox ? old.annotation : nil,
            start: marker == .checkbox ? old.start : nil,
            end: marker == .checkbox ? old.end : nil,
            notificationOffsetSecs: marker == .checkbox ? old.notificationOffsetSecs : nil,
            repeatRule: marker == .checkbox ? old.repeatRule : nil,
            media: old.media,
            tables: old.tables
        )
        applyMeta(new, paragraphRange: para, theme: theme)
    }

    private func copyRichSelectionToPasteboard(paragraphs: [EditorParagraphRange]? = nil) -> Bool {
        guard let paragraphs = paragraphs ?? richSelectedParagraphs(), !paragraphs.isEmpty else {
            return false
        }
        let ns = textStorage.string as NSString
        let items = paragraphs.map { paragraph in
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            return EditorRichClipboardItem(text: bodyText(paragraphRange: paragraph.fullRange, in: textStorage), meta: meta)
        }
        let plain = paragraphs
            .map { paragraph in
                paragraph.lineRange.length > 0 ? ns.substring(with: paragraph.lineRange) : ""
            }
            .joined(separator: "\n")
        guard !items.isEmpty,
              let data = try? JSONEncoder().encode(EditorRichClipboardPayload(items: items)) else {
            return false
        }
        UIPasteboard.general.setItems([[
            "public.utf8-plain-text": plain,
            editorRichClipboardType: data
        ]])
        return true
    }

    private func pasteRichItemsFromPasteboard() -> Bool {
        guard let data = UIPasteboard.general.data(forPasteboardType: editorRichClipboardType),
              let payload = try? JSONDecoder().decode(EditorRichClipboardPayload.self, from: data),
              payload.format == editorRichClipboardFormat,
              !payload.items.isEmpty else {
            return false
        }
        if selectedRange.length > 0, richSelectedParagraphs() == nil {
            return false
        }

        let replaceRange = richPasteReplacementRange()
        let attributed = attributedString(forRichItems: payload.items)
        guard attributed.length > 0 else { return false }
        coordinator?.suppress {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: replaceRange, with: attributed)
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        let caret = clampedCaret(replaceRange.location + max(0, attributed.length - 1), in: textStorage)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: caret, in: textStorage),
            theme: theme
        )
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        setNeedsDisplay()
        return true
    }

    private func attributedString(forRichItems items: [EditorRichClipboardItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for item in items {
            let meta = item.lineMeta(timeFormat: timeFormat)
            let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
            let bodyLocation = result.length
            result.append(NSAttributedString(string: item.text, attributes: attrs))
            let bodyRange = NSRange(location: bodyLocation, length: (item.text as NSString).length)
            result.append(NSAttributedString(string: "\n", attributes: attrs))
            applyInlineMarkdownStyling(body: item.text, bodyRange: bodyRange, in: result)
        }
        return result
    }

    private func richSelectedParagraphs() -> [EditorParagraphRange]? {
        let range = selectedRange
        guard range.length > 0 else { return nil }
        let ns = textStorage.string as NSString
        guard ns.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= ns.length else {
            return nil
        }
        let all = paragraphRanges(in: ns)
        guard let startIndex = all.firstIndex(where: { $0.fullRange.location == range.location }) else {
            return nil
        }
        let end = NSMaxRange(range)
        for index in startIndex..<all.count {
            let paragraph = all[index]
            if end == NSMaxRange(paragraph.lineRange) || end == NSMaxRange(paragraph.fullRange) {
                return Array(all[startIndex...index])
            }
            if end < NSMaxRange(paragraph.fullRange) {
                return nil
            }
        }
        return nil
    }

    private func richPasteReplacementRange() -> NSRange {
        if let paragraphs = richSelectedParagraphs(),
           let first = paragraphs.first,
           let last = paragraphs.last {
            return NSRange(location: first.fullRange.location, length: NSMaxRange(last.fullRange) - first.fullRange.location)
        }

        let ns = textStorage.string as NSString
        let caret = clampedCaret(selectedRange.location, in: textStorage)
        let paragraph = editableParagraphRange(in: ns, at: caret)
        let line = lineRange(from: paragraph, in: ns)
        if line.length == 0 {
            return paragraph
        }
        if caret <= paragraph.location {
            return NSRange(location: paragraph.location, length: 0)
        }
        return NSRange(location: NSMaxRange(paragraph), length: 0)
    }

    private func deleteWholeParagraphs(_ paragraphs: [EditorParagraphRange]) {
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let deleteRange = NSRange(
            location: first.fullRange.location,
            length: NSMaxRange(last.fullRange) - first.fullRange.location
        )
        coordinator?.suppress {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: deleteRange, with: NSAttributedString(string: ""))
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        let caret = clampedCaret(deleteRange.location, in: textStorage)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(meta: lineMeta(at: caret, in: textStorage), theme: theme)
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        setNeedsDisplay()
    }

    func shiftCurrentIndent(_ delta: Int, theme: KnotQTheme) {
        let para = editableParagraphRange(in: textStorage.string as NSString, at: selectedRange.location)
        let old = lineMeta(at: para.location, in: textStorage)
        let new = old.with(indent: max(0, min(8, old.indent + delta)))
        applyMeta(new, paragraphRange: para, theme: theme)
    }

    func toggleWrappedMarkdown(_ delimiter: String, theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let target: NSRange
        if selectedRange.length > 0 {
            target = selectedRange
        } else {
            let para = editableParagraphRange(in: ns, at: selectedRange.location)
            target = lineRange(from: para, in: ns)
        }
        guard target.location <= ns.length, NSMaxRange(target) <= ns.length else { return }
        let selected = target.length > 0 ? ns.substring(with: target) : ""
        let dlen = delimiter.count
        let wasWrapped = selected.count >= dlen * 2
            && selected.hasPrefix(delimiter)
            && selected.hasSuffix(delimiter)
        let replacement = wasWrapped
            ? String(selected.dropFirst(dlen).dropLast(dlen))
            : "\(delimiter)\(selected)\(delimiter)"
        let meta = lineMeta(at: target.location, in: textStorage)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        textStorage.replaceCharacters(
            in: target,
            with: NSAttributedString(string: replacement, attributes: attrs)
        )
        let newLength = (replacement as NSString).length
        let caret: NSRange
        if selectedRange.length > 0 {
            caret = NSRange(location: target.location, length: newLength)
        } else if !wasWrapped {
            caret = NSRange(location: target.location + (delimiter as NSString).length, length: 0)
        } else {
            caret = NSRange(location: target.location + newLength, length: 0)
        }
        selectedRange = caret
        coordinator?.markDirty()
        setNeedsDisplay()
    }

    func toggleHeading(theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let para = editableParagraphRange(in: ns, at: selectedRange.location)
        let lineText = bodyText(paragraphRange: para, in: textStorage)
        let leading = lineText.prefix { $0 == " " || $0 == "\t" }
        let afterLeading = String(lineText.dropFirst(leading.count))
        let hashes = afterLeading.prefix { $0 == "#" }.count
        let isHeading: Bool = {
            guard hashes > 0 else { return false }
            if afterLeading.count == hashes { return true }
            let idx = afterLeading.index(afterLeading.startIndex, offsetBy: hashes)
            return afterLeading[idx].isWhitespace
        }()
        let meta = lineMeta(at: para.location, in: textStorage)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        let savedSelection = selectedRange
        let leadingLen = (leading as NSString).length
        if isHeading {
            var removeLen = hashes
            let nsAfter = afterLeading as NSString
            if nsAfter.length > hashes {
                let ch = nsAfter.character(at: hashes)
                if ch == 32 || ch == 9 { removeLen += 1 }
            }
            textStorage.replaceCharacters(
                in: NSRange(location: para.location + leadingLen, length: removeLen),
                with: NSAttributedString(string: "", attributes: attrs)
            )
            selectedRange = NSRange(
                location: max(para.location, savedSelection.location - removeLen),
                length: savedSelection.length
            )
        } else {
            let insertion = "# "
            textStorage.replaceCharacters(
                in: NSRange(location: para.location + leadingLen, length: 0),
                with: NSAttributedString(string: insertion, attributes: attrs)
            )
            selectedRange = NSRange(
                location: savedSelection.location + (insertion as NSString).length,
                length: savedSelection.length
            )
        }
        coordinator?.markDirty()
        setNeedsDisplay()
    }

    /// Single internal entry point used by every "change just the meta" action
    /// (set marker, shift indent, toggle checkbox). Suppresses the textStorage
    /// delegate because we already maintain the invariants here.
    private func applyMeta(_ meta: LineMeta, paragraphRange: NSRange, theme: KnotQTheme) {
        coordinator?.suppress {
            textStorage.beginEditing()
            setLineMeta(meta, onParagraph: paragraphRange, in: textStorage, theme: theme)
            textStorage.endEditing()
        }
        typingAttributes = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        coordinator?.markDirty()
        coordinator?.refreshToolbarActiveMarker(in: self)
        setNeedsDisplay()
    }

    @discardableResult
    func toggleCheckboxAt(point: CGPoint) -> Bool {
        let ns = textStorage.string as NSString
        guard let lineRange = checkboxLineRange(at: point) else { return false }
        let para = ns.paragraphRange(for: lineRange)
        let old = lineMeta(at: para.location, in: textStorage)
        applyMeta(old.with(done: !old.done), paragraphRange: para, theme: theme)
        return true
    }

    func checkboxLineRange(at point: CGPoint) -> NSRange? {
        let ns = textStorage.string as NSString
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        for paragraph in paragraphRanges(in: ns) {
            let characterRange = paragraph.lineRange.length > 0 ? paragraph.lineRange : paragraph.fullRange
            guard characterRange.length > 0 else { continue }
            let glyphRange = self.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard self.layoutManager.numberOfGlyphs > 0, glyphRange.location < self.layoutManager.numberOfGlyphs else { continue }
            let fragment = self.layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let meta = metaForLine(storage: self.textStorage, lineRange: paragraph.lineRange)
            guard meta.marker == .checkbox else { continue }
            let rect = self.markerRect(for: meta, fragment: fragment).insetBy(dx: -8, dy: -8)
            if rect.contains(point) {
                return paragraph.lineRange
            }
        }
        return nil
    }

    fileprivate func drawChrome(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        renderedTableCellHits.removeAll()
        renderedTableBlockHits.removeAll()
        let storage = textStorage
        let ns = storage.string as NSString
        let paragraphs = paragraphRanges(in: ns)
        let metas: [LineMeta] = paragraphs.map { lineMeta(at: $0.fullRange.location, in: storage) }
        for index in paragraphs.indices {
            let paragraph = paragraphs[index]
            guard let geometry = paragraphGeometry(for: paragraph, origin: origin) else { continue }
            let glyphRange = geometry.glyphRange
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { continue }
            let firstFragment = geometry.fragments[0]
            let visualBounds = geometry.bounds
            let meta = metas[index]
            let previousMeta = index > 0 ? metas[index - 1] : nil
            let nextMeta = index + 1 < metas.count ? metas[index + 1] : nil
            let previousAnnotated = previousMeta?.annotation != nil
            let nextAnnotated = nextMeta?.annotation != nil
            let contentMaxWidth = editorInlineBlockMaxWidth(textLeft: firstFragment.minX)
            let blockExtraHeight = orderedBlockStackHeight(for: meta, maxWidth: contentMaxWidth)
            let annotationHeight = meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight
            let rowExtraHeight = annotationHeight + blockExtraHeight
            let ordinal = meta.marker == .numbered ? numberedOrdinal(at: index, in: metas) : 1
            drawIndentGuides(
                meta: meta, previousMeta: previousMeta, nextMeta: nextMeta,
                firstFragment: firstFragment, visualBounds: visualBounds,
                rowExtraHeight: rowExtraHeight, context: context
            )
            drawMarker(meta: meta, ordinal: ordinal, fragment: firstFragment, context: context)
            if let annotation = meta.annotation {
                drawAnnotationBar(meta: meta, firstFragment: firstFragment, visualBounds: visualBounds, rowExtraHeight: rowExtraHeight, connectsToPrevious: previousAnnotated, connectsToNext: nextAnnotated, context: context)
                drawAnnotation(annotation, meta: meta, visualBounds: visualBounds, context: context)
            }
            // Images + tables render below the (possibly collapsed) text band in
            // document order. With a block-only line the band is ~2px, so the
            // block effectively sits in place at the paragraph top.
            drawOrderedBlockStack(
                for: meta,
                itemID: meta.itemID,
                paragraphRange: paragraph.fullRange,
                textLeft: firstFragment.minX,
                top: visualBounds.maxY + annotationHeight,
                context: context
            )
        }
    }

    /// Counts the current line as Nth where N = 1 + the number of consecutive
    /// prior Numbered siblings at the same indent (nested-deeper lines are
    /// transparent; anything at a shallower indent or a non-Numbered at the
    /// same indent ends the run). Mirrors desktop's `numbered_marker_ordinal`.
    private func numberedOrdinal(at index: Int, in metas: [LineMeta]) -> Int {
        let currentIndent = metas[index].indent
        var ordinal = 1
        var i = index - 1
        while i >= 0 {
            let prev = metas[i]
            if prev.indent > currentIndent { i -= 1; continue }
            if prev.indent < currentIndent { break }
            if prev.marker != .numbered { break }
            ordinal += 1
            i -= 1
        }
        return ordinal
    }

    private func drawIndentGuides(meta: LineMeta, previousMeta: LineMeta?, nextMeta: LineMeta?, firstFragment: CGRect, visualBounds: CGRect, rowExtraHeight: CGFloat, context: CGContext) {
        let indent = min(meta.indent, 8)
        guard indent > 0 else { return }
        context.setFillColor(UIColor(theme.dividerSoft).cgColor)
        let marker = markerRect(for: meta, fragment: firstFragment)
        let ownBarX = marker.minX - (DesktopEditorMetrics.annotationBarGap + DesktopEditorMetrics.indentGuideXShift)
        let rowHeight = visualBounds.maxY - firstFragment.minY + rowExtraHeight
        let guideMargin: CGFloat = 3
        for guideIndent in 1...indent {
            let previousHasGuide = min(previousMeta?.indent ?? 0, 8) >= guideIndent
            let nextHasGuide = min(nextMeta?.indent ?? 0, 8) >= guideIndent
            let topMargin = previousHasGuide ? 0 : guideMargin
            let bottomMargin = nextHasGuide ? 0 : guideMargin
            let levelOffset = CGFloat(indent - guideIndent) * DesktopEditorMetrics.indentWidth
            context.fill(CGRect(
                x: ownBarX - levelOffset,
                y: firstFragment.minY + topMargin,
                width: 1,
                height: max(1, rowHeight - topMargin - bottomMargin)
            ))
        }
    }

    private func drawMarker(meta: LineMeta, ordinal: Int, fragment: CGRect, context: CGContext) {
        let rect = markerRect(for: meta, fragment: fragment)
        let chrome = theme.editorChromeColor
        switch meta.marker {
        case .blank:
            return
        case .bullet:
            context.setFillColor(chrome.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
        case .numbered:
            let label = "\(ordinal)." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: chrome
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        case .checkbox:
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            (meta.done ? chrome : UIColor(theme.buttonBg)).setFill()
            path.fill()
            chrome.setStroke()
            path.lineWidth = 1
            path.stroke()
            if meta.done {
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + 3.2, y: rect.minY + 7.2))
                check.addLine(to: CGPoint(x: rect.minX + 5.8, y: rect.minY + 9.7))
                check.addLine(to: CGPoint(x: rect.maxX - 3.0, y: rect.minY + 4.3))
                UIColor(theme.bgApp).setStroke()
                check.lineWidth = 1.8
                check.stroke()
            }
        }
    }

    private func drawAnnotationBar(meta: LineMeta, firstFragment: CGRect, visualBounds: CGRect, rowExtraHeight: CGFloat, connectsToPrevious: Bool, connectsToNext: Bool, context: CGContext) {
        let marker = markerRect(for: meta, fragment: firstFragment)
        let x = annotationGuideX(marker: marker)
        let top = connectsToPrevious ? firstFragment.minY : marker.minY
        let bottom = visualBounds.maxY + rowExtraHeight - (connectsToNext ? 0 : 3)
        context.setFillColor(theme.editorChromeColor.cgColor)
        context.fill(CGRect(x: x, y: top, width: 1, height: max(1, bottom - top)))
    }

    private func drawAnnotation(_ annotation: String, meta: LineMeta, visualBounds: CGRect, context: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: DesktopEditorMetrics.annotationFontSize, weight: .medium),
            .foregroundColor: theme.editorChromeColor
        ]
        let marker = markerRect(for: meta, fragment: visualBounds)
        let x = annotationGuideX(marker: marker) + DesktopEditorMetrics.annotationTextGap
        let y = visualBounds.maxY - 1
        (annotation as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: - Ordered inline blocks
    //
    // A line's images and tables render below its text band in document order.
    // `orderedBlocks(for:)` is the single source of truth for that order: it
    // walks `meta.content` (text/image/table) so an image typed before a table
    // draws above it, and a block that leads the content sits in the collapsed
    // text band's place. When `content` is empty (clipboard- or edit-built metas
    // that predate inline content) it falls back to the legacy media-then-tables
    // ordering so nothing regresses.

    private enum EditorBlock {
        case image(MobileItemMedia)
        case table(MobileTable)
    }

    private func orderedBlocks(for meta: LineMeta) -> [EditorBlock] {
        if !meta.content.isEmpty {
            return meta.content.compactMap { inline in
                switch inline {
                case let .image(media): return .image(media)
                case let .table(table): return .table(table)
                case .text: return nil
                }
            }
        }
        // Legacy fallback: all images first, then all tables.
        return meta.media.filter { $0.kind == "image" }.map(EditorBlock.image)
            + meta.tables.map(EditorBlock.table)
    }

    /// Total height of a line's ordered block stack (images + tables, in order),
    /// including the leading gap before the first block. Used both to reserve
    /// space below the paragraph and to position later blocks.
    private func orderedBlockStackHeight(for meta: LineMeta, maxWidth: CGFloat) -> CGFloat {
        let blocks = orderedBlocks(for: meta)
        guard !blocks.isEmpty, maxWidth > 0 else { return 0 }
        var height: CGFloat = 0
        var previous: EditorBlock?
        for block in blocks {
            height += blockLeadingGap(block, previous: previous)
            height += blockHeight(block, maxWidth: maxWidth)
            previous = block
        }
        return height
    }

    /// Gap above `block` given the block that precedes it (nil for the first).
    /// Mirrors the per-kind gaps the legacy stacks used so spacing is unchanged
    /// for media-only / table-only lines.
    private func blockLeadingGap(_ block: EditorBlock, previous: EditorBlock?) -> CGFloat {
        switch block {
        case .image:
            // First block: top gap. Image after another image: tight stack gap.
            // Image after a table: use the table stack gap so kinds don't crowd.
            switch previous {
            case .none: return DesktopEditorMetrics.imageTopGap
            case .image: return DesktopEditorMetrics.imageStackGap
            case .table: return DesktopEditorMetrics.tableStackGap
            }
        case .table:
            switch previous {
            case .none: return DesktopEditorMetrics.tableTopGap
            default: return DesktopEditorMetrics.tableStackGap
            }
        }
    }

    private func blockHeight(_ block: EditorBlock, maxWidth: CGFloat) -> CGFloat {
        switch block {
        case let .image(media):
            return mediaDisplaySize(media, maxWidth: maxWidth).height
        case let .table(table):
            return tableHeight(table)
        }
    }

    /// Draws a line's ordered block stack starting at `top`, recording table
    /// cell hit rects for `itemID`. `tableIndex` is assigned per table so cell
    /// edits address the correct table on the line.
    private func drawOrderedBlockStack(
        for meta: LineMeta,
        itemID: String?,
        paragraphRange: NSRange,
        textLeft: CGFloat,
        top: CGFloat,
        context: CGContext
    ) {
        let maxWidth = editorInlineBlockMaxWidth(textLeft: textLeft)
        guard maxWidth > 0 else { return }
        var y = top
        var previous: EditorBlock?
        var tableIndex = 0
        for block in orderedBlocks(for: meta) {
            y += blockLeadingGap(block, previous: previous)
            switch block {
            case let .image(media):
                let size = mediaDisplaySize(media, maxWidth: maxWidth)
                if size.width > 0, size.height > 0 {
                    drawImageMedia(media, in: CGRect(x: textLeft, y: y, width: size.width, height: size.height), context: context)
                }
                y += size.height
            case let .table(table):
                let height = tableHeight(table)
                let tableRect = CGRect(x: textLeft, y: y, width: maxWidth, height: height)
                if bodyText(paragraphRange: paragraphRange, in: textStorage).isEmpty {
                    renderedTableBlockHits.append(EditorTableBlockHitRect(
                        rect: tableRect,
                        paragraphRange: paragraphRange
                    ))
                }
                drawTable(
                    table,
                    itemID: itemID,
                    tableIndex: tableIndex,
                    in: tableRect,
                    context: context
                )
                y += height
                tableIndex += 1
            }
            previous = block
        }
    }

    private func drawImageMedia(_ media: MobileItemMedia, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
        UIColor(theme.buttonBg).setFill()
        path.fill()
        UIColor(theme.divider).setStroke()
        path.lineWidth = 1
        path.stroke()

        path.addClip()
        if let image = imageForMedia(media), image.size.width > 2, image.size.height > 2 {
            image.draw(in: rect)
        } else {
            drawImageFallback(in: rect)
        }
    }

    private func drawImageFallback(in rect: CGRect) {
        let inner = rect.insetBy(dx: 1, dy: 1)
        let size = inner.size
        UIColor(theme.bgModal).setFill()
        UIBezierPath(rect: inner).fill()

        UIColor(theme.accent).withAlphaComponent(0.16).setFill()
        UIBezierPath(ovalIn: CGRect(
            x: inner.maxX - size.width * 0.32,
            y: inner.minY + size.height * 0.12,
            width: size.width * 0.18,
            height: size.width * 0.18
        )).fill()

        UIColor(theme.divider).setFill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.16,
            width: size.width * 0.40,
            height: max(6, size.height * 0.07)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.32,
            width: size.width * 0.62,
            height: max(5, size.height * 0.05)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.45,
            width: size.width * 0.50,
            height: max(5, size.height * 0.05)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.maxY - size.height * 0.29,
            width: size.width * 0.70,
            height: max(18, size.height * 0.13)
        ), cornerRadius: 6).fill()

        let label = "Image" as NSString
        label.draw(
            at: CGPoint(x: inner.minX + size.width * 0.10, y: inner.maxY - size.height * 0.27),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: max(11, size.height * 0.07), weight: .semibold),
                .foregroundColor: UIColor(theme.textPrimary)
            ]
        )
    }

    private func mediaDisplaySize(_ media: MobileItemMedia, maxWidth: CGFloat) -> CGSize {
        let rawWidth = media.width.map(CGFloat.init) ?? DesktopEditorMetrics.imageFallbackWidth
        let rawHeight = media.height.map(CGFloat.init) ?? DesktopEditorMetrics.imageFallbackHeight
        guard rawWidth > 0, rawHeight > 0, maxWidth > 0 else { return .zero }
        let scale = min(maxWidth / rawWidth, DesktopEditorMetrics.imageMaxHeight / rawHeight)
        let clampedScale = min(max(scale, 0.05), 1)
        return CGSize(width: rawWidth * clampedScale, height: rawHeight * clampedScale)
    }

    private func imageForMedia(_ media: MobileItemMedia) -> UIImage? {
        guard let path = media.path, !path.isEmpty else { return nil }
        if let cached = imageCache[path] {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        imageCache[path] = image
        return image
    }

    private func editorInlineBlockMaxWidth(textLeft: CGFloat) -> CGFloat {
        let referenceWidth = measurementWidth ?? bounds.width
        return max(120, referenceWidth - textLeft - textContainerInset.right - 8)
    }

    private func editorImageMaxWidth(meta: LineMeta) -> CGFloat {
        let textLeft = textContainerInset.left
            + CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth
            + (meta.marker == .blank ? 0 : DesktopEditorMetrics.markerSlot)
        return editorInlineBlockMaxWidth(textLeft: textLeft)
    }

    private func tableHeight(_ table: MobileTable) -> CGFloat {
        let rowCount = max(1, table.rows.count)
        return DesktopEditorMetrics.tableHeaderHeight + CGFloat(rowCount) * DesktopEditorMetrics.tableCellHeight
    }

    private func drawTable(_ table: MobileTable, itemID: String?, tableIndex: Int, in rect: CGRect, context: CGContext) {
        let columnCount = tableColumnCount(table)
        guard columnCount > 0, rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        UIColor(theme.buttonBg).setFill()
        path.fill()
        UIColor(theme.divider).setStroke()
        path.lineWidth = 1
        path.stroke()
        path.addClip()

        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: DesktopEditorMetrics.tableHeaderHeight)
        UIColor(theme.bgModal).setFill()
        UIBezierPath(rect: headerRect).fill()

        let colWidth = rect.width / CGFloat(columnCount)
        let headerTextColor = UIColor(theme.isDark ? theme.textSoft : theme.textDim)
        let headerAttributes = tableTextAttributes(weight: .semibold, color: headerTextColor)
        let bodyAttributes = tableTextAttributes(weight: .regular, color: UIColor(theme.textPrimary))

        for column in 0..<columnCount {
            let cellRect = CGRect(
                x: rect.minX + CGFloat(column) * colWidth,
                y: rect.minY,
                width: colWidth,
                height: DesktopEditorMetrics.tableHeaderHeight
            )
            let title = column < table.columns.count ? table.columns[column].name : "Column \(column + 1)"
            drawTableText(title, in: cellRect, attributes: headerAttributes)
            if let itemID {
                renderedTableCellHits.append(EditorTableCellHitRect(
                    rect: cellRect,
                    hit: EditorTableCellHit(
                        itemID: itemID,
                        tableIndex: tableIndex,
                        row: -1,
                        column: column,
                        text: title,
                        frame: cellRect
                    )
                ))
            }
        }

        for row in 0..<max(1, table.rows.count) {
            let rowData = row < table.rows.count ? table.rows[row] : nil
            for column in 0..<columnCount {
                let cellRect = CGRect(
                    x: rect.minX + CGFloat(column) * colWidth,
                    y: rect.minY + DesktopEditorMetrics.tableHeaderHeight + CGFloat(row) * DesktopEditorMetrics.tableCellHeight,
                    width: colWidth,
                    height: DesktopEditorMetrics.tableCellHeight
                )
                let cell = rowData.flatMap { column < $0.cells.count ? $0.cells[column] : nil }
                let text = cell?.text ?? ""
                drawTableText(text, in: cellRect, attributes: bodyAttributes)
                if let itemID, row < table.rows.count {
                    // The in-place editor edits the cell's first line; prefill
                    // from it (not the multi-line summary `cell.text`).
                    let editText = cell?.lines.first?.text ?? text
                    renderedTableCellHits.append(EditorTableCellHitRect(
                        rect: cellRect,
                        hit: EditorTableCellHit(
                            itemID: itemID,
                            tableIndex: tableIndex,
                            row: row,
                            column: column,
                            text: editText,
                            frame: cellRect
                        )
                    ))
                }
            }
        }

        UIColor(theme.divider).setStroke()
        context.setLineWidth(1)
        for column in 1..<columnCount {
            let x = rect.minX + CGFloat(column) * colWidth
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        let rowLines = max(1, table.rows.count)
        for row in 0...rowLines {
            let y = rect.minY + DesktopEditorMetrics.tableHeaderHeight + CGFloat(row) * DesktopEditorMetrics.tableCellHeight
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    private func tableTextAttributes(weight: UIFont.Weight, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: UIFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func drawTableText(_ text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        let inset = rect.insetBy(dx: 7, dy: 7)
        let value = (text.isEmpty ? " " : text) as NSString
        value.draw(in: inset, withAttributes: attributes)
    }

    private func tableColumnCount(_ table: MobileTable) -> Int {
        max(1, max(table.columns.count, table.rows.map { $0.cells.count }.max() ?? 0))
    }

    /// Row/column counts for the table identified by `itemID`/`tableIndex`,
    /// used to clamp Tab / arrow navigation to the grid.
    func tableDimensions(itemID: String, tableIndex: Int) -> (rows: Int, columns: Int)? {
        let meta = metaForItem(itemID)
        var index = 0
        for block in orderedBlocks(for: meta ?? LineMeta()) {
            if case let .table(table) = block {
                if index == tableIndex {
                    return (table.rows.count, tableColumnCount(table))
                }
                index += 1
            }
        }
        return nil
    }

    private func metaForItem(_ itemID: String) -> LineMeta? {
        let ns = textStorage.string as NSString
        for paragraph in paragraphRanges(in: ns) {
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            if meta.itemID == itemID { return meta }
        }
        return nil
    }

    func tableBoundaryHit(at point: CGPoint) -> EditorTableBoundaryHit? {
        let horizontalSlop: CGFloat = 10
        let beforeHeight = max(18, DesktopEditorMetrics.tableTopGap + 10)
        let afterHeight: CGFloat = 22

        for recorded in renderedTableBlockHits.reversed() {
            let x = recorded.rect.minX - horizontalSlop
            let width = recorded.rect.width + horizontalSlop * 2
            let beforeRect = CGRect(
                x: x,
                y: recorded.rect.minY - beforeHeight,
                width: width,
                height: beforeHeight
            )
            if beforeRect.contains(point) {
                return EditorTableBoundaryHit(paragraphRange: recorded.paragraphRange, side: .before)
            }

            let afterRect = CGRect(
                x: x,
                y: recorded.rect.maxY,
                width: width,
                height: afterHeight
            )
            if afterRect.contains(point), shouldUseAfterTableBoundary(for: recorded.paragraphRange) {
                return EditorTableBoundaryHit(paragraphRange: recorded.paragraphRange, side: .after)
            }
        }
        return nil
    }

    @discardableResult
    func placeCaretAtTableBoundary(_ hit: EditorTableBoundaryHit, theme: KnotQTheme) -> Bool {
        guard isEditable else { return false }
        endTableCellEditing(commit: true)

        let targetLocation: Int
        var inserted = false
        if let reusable = reusableBoundaryParagraph(relativeTo: hit.paragraphRange, side: hit.side) {
            targetLocation = reusable.fullRange.location
        } else {
            targetLocation = insertBlankBoundaryLine(relativeTo: hit.paragraphRange, side: hit.side, theme: theme)
            inserted = true
        }

        let clampedTarget = clampedCaret(targetLocation, in: textStorage)
        selectedRange = NSRange(location: clampedTarget, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: clampedTarget, in: textStorage),
            theme: theme
        )
        if !isFirstResponder {
            becomeFirstResponder()
        }
        refreshMarkerVisibility(force: true)
        scrollRangeToVisible(NSRange(location: clampedTarget, length: 0))
        if inserted {
            coordinator?.markDirty()
            coordinator?.refreshEmpty()
            invalidateIntrinsicContentSize()
        }
        setNeedsDisplay()
        return true
    }

    private func shouldUseAfterTableBoundary(for paragraphRange: NSRange) -> Bool {
        let paragraphs = paragraphRanges(in: textStorage.string as NSString)
        guard let index = paragraphs.firstIndex(where: { $0.fullRange.location == paragraphRange.location }) else {
            return false
        }
        guard index + 1 < paragraphs.count else { return true }
        return isReusableBoundaryParagraph(paragraphs[index + 1], tableParagraph: paragraphs[index])
    }

    private func reusableBoundaryParagraph(relativeTo paragraphRange: NSRange, side: EditorTableBoundarySide) -> EditorParagraphRange? {
        let paragraphs = paragraphRanges(in: textStorage.string as NSString)
        guard let index = paragraphs.firstIndex(where: { $0.fullRange.location == paragraphRange.location }) else {
            return nil
        }
        let candidateIndex: Int
        switch side {
        case .before:
            guard index > 0 else { return nil }
            candidateIndex = index - 1
        case .after:
            guard index + 1 < paragraphs.count else { return nil }
            candidateIndex = index + 1
        }
        let tableParagraph = paragraphs[index]
        let candidate = paragraphs[candidateIndex]
        return isReusableBoundaryParagraph(candidate, tableParagraph: tableParagraph) ? candidate : nil
    }

    private func isReusableBoundaryParagraph(_ paragraph: EditorParagraphRange, tableParagraph: EditorParagraphRange) -> Bool {
        let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
        let tableMeta = lineMeta(at: tableParagraph.fullRange.location, in: textStorage)
        return bodyText(paragraphRange: paragraph.fullRange, in: textStorage).isEmpty
            && meta.marker == .blank
            && meta.indent == tableMeta.indent
            && meta.annotation == nil
            && meta.media.isEmpty
            && meta.tables.isEmpty
    }

    private func insertBlankBoundaryLine(relativeTo paragraphRange: NSRange, side: EditorTableBoundarySide, theme: KnotQTheme) -> Int {
        let tableMeta = lineMeta(at: paragraphRange.location, in: textStorage)
        let blankMeta = LineMeta(marker: .blank, indent: tableMeta.indent)
        let attrs = EditorAttributes.bodyAttributes(meta: blankMeta, theme: theme)
        let insertionLocation = min(
            max(0, side == .before ? paragraphRange.location : NSMaxRange(paragraphRange)),
            textStorage.length
        )

        let edit = {
            self.textStorage.beginEditing()
            self.textStorage.replaceCharacters(
                in: NSRange(location: insertionLocation, length: 0),
                with: NSAttributedString(string: "\n", attributes: attrs)
            )
            self.textStorage.endEditing()
        }
        if let coordinator {
            coordinator.suppress(edit)
        } else {
            edit()
        }

        return insertionLocation
    }

    func tableCellHit(at point: CGPoint) -> EditorTableCellHit? {
        if let recorded = renderedTableCellHits.last(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }) {
            return recorded.hit
        }
        // Fallback: recompute geometry in document order when the cell hasn't
        // been drawn yet (e.g. off-screen). Mirrors `drawOrderedBlockStack`.
        return enumerateTableCells { hit in
            hit.frame.insetBy(dx: -4, dy: -4).contains(point) ? hit : nil
        }
    }

    /// Looks up a specific cell's current hit (with its frame) for Tab / arrow
    /// navigation. Prefers a recorded rect; recomputes geometry otherwise.
    func tableCellHit(itemID: String, tableIndex: Int, row: Int, column: Int) -> EditorTableCellHit? {
        if let recorded = renderedTableCellHits.last(where: {
            $0.hit.itemID == itemID && $0.hit.tableIndex == tableIndex && $0.hit.row == row && $0.hit.column == column
        }) {
            return recorded.hit
        }
        return enumerateTableCells { hit in
            (hit.itemID == itemID && hit.tableIndex == tableIndex && hit.row == row && hit.column == column) ? hit : nil
        }
    }

    /// Walks every table cell in document order, invoking `match` with each
    /// cell's hit (frame in content coordinates); returns the first non-nil
    /// result. The geometry here is the authoritative fallback that mirrors
    /// `drawOrderedBlockStack`, so a hit found this way lands on the same rect
    /// the cell is drawn at.
    private func enumerateTableCells(_ match: (EditorTableCellHit) -> EditorTableCellHit?) -> EditorTableCellHit? {
        let ns = textStorage.string as NSString
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        for paragraph in paragraphRanges(in: ns) {
            guard let geometry = paragraphGeometry(for: paragraph, origin: origin) else { continue }
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            guard let itemID = meta.itemID, !meta.tables.isEmpty else { continue }
            let firstFragment = geometry.fragments[0]
            let textLeft = firstFragment.minX
            let maxWidth = editorInlineBlockMaxWidth(textLeft: textLeft)
            guard maxWidth > 0 else { continue }
            let annotationHeight = meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight
            var y = geometry.bounds.maxY + annotationHeight
            var previous: EditorBlock?
            var tableIndex = 0
            for block in orderedBlocks(for: meta) {
                y += blockLeadingGap(block, previous: previous)
                switch block {
                case let .image(media):
                    y += mediaDisplaySize(media, maxWidth: maxWidth).height
                case let .table(table):
                    let columnCount = tableColumnCount(table)
                    let colWidth = maxWidth / CGFloat(columnCount)
                    for column in 0..<columnCount {
                        let rect = CGRect(
                            x: textLeft + CGFloat(column) * colWidth,
                            y: y,
                            width: colWidth,
                            height: DesktopEditorMetrics.tableHeaderHeight
                        )
                        let title = column < table.columns.count ? table.columns[column].name : "Column \(column + 1)"
                        let hit = EditorTableCellHit(
                            itemID: itemID,
                            tableIndex: tableIndex,
                            row: -1,
                            column: column,
                            text: title,
                            frame: rect
                        )
                        if let result = match(hit) { return result }
                    }
                    let bodyY = y + DesktopEditorMetrics.tableHeaderHeight
                    for row in 0..<table.rows.count {
                        for column in 0..<columnCount {
                            let rect = CGRect(
                                x: textLeft + CGFloat(column) * colWidth,
                                y: bodyY + CGFloat(row) * DesktopEditorMetrics.tableCellHeight,
                                width: colWidth,
                                height: DesktopEditorMetrics.tableCellHeight
                            )
                            let cell = column < table.rows[row].cells.count ? table.rows[row].cells[column] : nil
                            let hit = EditorTableCellHit(
                                itemID: itemID,
                                tableIndex: tableIndex,
                                row: row,
                                column: column,
                                text: cell?.lines.first?.text ?? cell?.text ?? "",
                                frame: rect
                            )
                            if let result = match(hit) { return result }
                        }
                    }
                    y += tableHeight(table)
                    tableIndex += 1
                }
                previous = block
            }
        }
        return nil
    }

    // MARK: - In-place table cell editing

    var isEditingTableCell: Bool { activeCellEditor != nil }

    /// Starts (or moves) the in-place editor over `hit`. Resigns the document's
    /// own keyboard so the cell field owns input, and focuses it.
    func beginEditingTableCell(_ hit: EditorTableCellHit) {
        guard isEditable else { return }
        // The cell field becoming first responder hands input off from the
        // document automatically; no manual resign needed.
        if let editor = activeCellEditor {
            editor.retarget(to: hit)
            editor.focus()
            return
        }
        let editor = EditorTableCellEditor(hit: hit, theme: theme)
        editor.onCommit = { [weak self] hit, text, reason in
            self?.handleCellCommit(hit, text: text, reason: reason)
        }
        editor.onFlush = { [weak self] hit, text in
            // Persist only — never tears the editor down (the caller is reusing it).
            self?.onTableCellCommit?(hit, text)
        }
        editor.onRequestEnd = { [weak self] in
            // Dismiss already flushed; tear the overlay down without re-committing.
            self?.endTableCellEditing(commit: false)
        }
        editor.onStructureAction = { [weak self] hit, action in
            self?.handleCellStructureAction(hit, action: action)
        }
        addSubview(editor)
        activeCellEditor = editor
        editor.focus()
    }

    /// Tears down the active cell editor. Pass `commit: true` to flush its text
    /// first (used when the document is committed / loses focus).
    func endTableCellEditing(commit: Bool) {
        guard let editor = activeCellEditor else { return }
        // Editing is ending for real, so any queued post-reload retarget is moot.
        pendingCellFocus = nil
        if commit {
            editor.commit(reason: nil)
        }
        activeCellEditor = nil
        editor.field.resignFirstResponder()
        editor.removeFromSuperview()
    }

    private func handleCellStructureAction(_ hit: EditorTableCellHit, action: EditorCellStructureAction) {
        // Queue the cell to land on once the grid reloads, then run the op. The
        // editor stays mounted; `loadItems` retargets it via `pendingCellFocus`
        // so the keyboard never collapses between structural edits.
        pendingCellFocus = structureFocusTarget(for: hit, action: action)
        switch action {
        case .insertRowAbove:
            onTableInsertRow?(hit, hit.row)
        case .insertRowBelow:
            onTableInsertRow?(hit, hit.row + 1)
        case .deleteRow: onTableDeleteRow?(hit)
        case .insertColumnLeft:
            onTableInsertColumn?(hit, hit.column)
        case .insertColumnRight:
            onTableInsertColumn?(hit, hit.column + 1)
        case .deleteColumn: onTableDeleteColumn?(hit)
        }
    }

    /// Which cell the editor should occupy after `action` reshapes the grid.
    /// Inserts land on the freshly created row/column; deletes land on the cell
    /// that slides into the deleted one's place. If the target no longer exists
    /// (e.g. the last row/column was deleted) `consumePendingCellFocusIfNeeded`
    /// resolves to nil and ends editing gracefully.
    private func structureFocusTarget(for hit: EditorTableCellHit, action: EditorCellStructureAction) -> (itemID: String, tableIndex: Int, row: Int, column: Int) {
        switch action {
        case .insertRowAbove:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .insertRowBelow:
            return (hit.itemID, hit.tableIndex, hit.row + 1, hit.column)
        case .insertColumnLeft:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .insertColumnRight:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column + 1)
        case .deleteRow:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .deleteColumn:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        }
    }

    /// After a reload triggered by a structural change, move the still-mounted
    /// cell editor onto the queued target using freshly computed geometry. The
    /// recorded hit rects predate the change, so drop them and let the lookup fall
    /// back to the document-order recompute. Ends editing if the target is gone.
    private func consumePendingCellFocusIfNeeded() {
        guard let target = pendingCellFocus else { return }
        pendingCellFocus = nil
        guard activeCellEditor != nil else { return }
        layoutManager.ensureLayout(for: textContainer)
        renderedTableCellHits.removeAll()
        if let hit = tableCellHit(itemID: target.itemID, tableIndex: target.tableIndex, row: target.row, column: target.column) {
            activeCellEditor?.retarget(to: hit)
            activeCellEditor?.focus()
        } else {
            endTableCellEditing(commit: false)
        }
    }

    private func handleCellCommit(_ hit: EditorTableCellHit, text: String, reason: EditorCellCommitReason) {
        if text != hit.text {
            onTableCellCommit?(hit, text)
        }
        switch reason {
        case .resign:
            // The model write reloads the document; just drop the editor.
            activeCellEditor?.removeFromSuperview()
            activeCellEditor = nil
        case .moveDown:
            moveCellEditor(from: hit, rowDelta: 1, columnDelta: 0, textChanged: text != hit.text)
        case .moveNext:
            moveCellEditor(from: hit, rowDelta: 0, columnDelta: 1, textChanged: text != hit.text)
        case .movePrevious:
            moveCellEditor(from: hit, rowDelta: 0, columnDelta: -1, textChanged: text != hit.text)
        }
    }

    /// Moves the editor to a neighboring cell, wrapping across rows for Tab and
    /// clamping at the grid edges. When the text changed, the model write will
    /// reload the document and recompute geometry; we re-resolve the target hit
    /// on the next runloop so it lands on the freshly drawn rect.
    private func moveCellEditor(from hit: EditorTableCellHit, rowDelta: Int, columnDelta: Int, textChanged: Bool) {
        guard let dims = tableDimensions(itemID: hit.itemID, tableIndex: hit.tableIndex), dims.rows > 0, dims.columns > 0 else {
            endTableCellEditing(commit: false)
            return
        }
        var row = hit.row
        var column = hit.column
        if columnDelta != 0 {
            // Tab / Shift-Tab: advance linearly across the grid, wrapping rows.
            var linear = (row + 1) * dims.columns + column + columnDelta
            let total = (dims.rows + 1) * dims.columns
            if linear < 0 || linear >= total {
                // Past either end — stop editing rather than wrap out of bounds.
                endTableCellEditing(commit: false)
                return
            }
            linear = max(0, min(total - 1, linear))
            row = linear / dims.columns - 1
            column = linear % dims.columns
        } else {
            row += rowDelta
            if row < -1 || row >= dims.rows {
                endTableCellEditing(commit: false)
                return
            }
        }

        let targetRow = row
        let targetColumn = column
        let focusNeighbor: () -> Void = { [weak self] in
            guard let self, let editor = self.activeCellEditor else { return }
            if let next = self.tableCellHit(itemID: hit.itemID, tableIndex: hit.tableIndex, row: targetRow, column: targetColumn) {
                editor.retarget(to: next)
                editor.focus()
            } else {
                self.endTableCellEditing(commit: false)
            }
        }

        if textChanged {
            // Defer until the model write + reload settle so geometry is current.
            DispatchQueue.main.async(execute: focusNeighbor)
        } else {
            focusNeighbor()
        }
    }

    private func annotationGuideX(marker: CGRect) -> CGFloat {
        marker.minX - (DesktopEditorMetrics.annotationBarGap + DesktopEditorMetrics.indentGuideXShift)
    }

    private func markerRect(for meta: LineMeta, fragment: CGRect) -> CGRect {
        CGRect(
            x: textContainerInset.left + CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth,
            y: fragment.minY + (fragment.height - DesktopEditorMetrics.checkboxSize) / 2
                + DesktopEditorMetrics.markerVerticalNudge,
            width: DesktopEditorMetrics.checkboxSize,
            height: DesktopEditorMetrics.checkboxSize
        )
    }

    fileprivate func annotationSpacingAfterGlyph(at glyphIndex: Int) -> CGFloat {
        let ns = textStorage.string as NSString
        guard glyphIndex >= 0,
              glyphIndex < layoutManager.numberOfGlyphs,
              ns.length > 0 else { return 0 }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < ns.length else { return 0 }
        let paragraphRange = ns.paragraphRange(for: NSRange(location: characterIndex, length: 0))
        let line = lineRange(from: paragraphRange, in: ns)
        let meta = metaForLine(storage: textStorage, lineRange: line)
        var spacing: CGFloat = 0
        if meta.annotation != nil {
            spacing += DesktopEditorMetrics.annotationHeight
        }
        let maxWidth = editorImageMaxWidth(meta: meta)
        spacing += orderedBlockStackHeight(for: meta, maxWidth: maxWidth)
        guard spacing > 0 else { return 0 }

        let lastContentCharacter = line.length > 0 ? NSMaxRange(line) - 1 : paragraphRange.location
        return characterIndex >= lastContentCharacter ? spacing : 0
    }

    private func paragraphGeometry(for paragraph: EditorParagraphRange, origin: CGPoint) -> (glyphRange: NSRange, fragments: [CGRect], bounds: CGRect)? {
        let characterRange = paragraph.lineRange.length > 0 ? paragraph.lineRange : paragraph.fullRange
        guard characterRange.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard layoutManager.numberOfGlyphs > 0, glyphRange.location < layoutManager.numberOfGlyphs else { return nil }
        var fragments: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            guard NSIntersectionRange(fragmentGlyphRange, glyphRange).length > 0 else { return }
            fragments.append(usedRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard let first = fragments.first else { return nil }
        let bounds = fragments.dropFirst().reduce(first) { $0.union($1) }
        return (glyphRange, fragments, bounds)
    }
}

extension EditorCoordinator {
    fileprivate func markClean() {
        // Skip the redundant write: loadItems now also runs inside makeUIView,
        // and publishing an unchanged @Published value there would trip
        // "publishing changes from within view updates".
        if controller?.isDirty == true {
            controller?.isDirty = false
        }
    }
}

// MARK: - NSLayoutManager subclass

final class EditorLayoutManager: NSLayoutManager {
    weak var editorTextView: EditorTextView?
    /// Character range whose markdown markers are revealed (the caret's line(s));
    /// markers elsewhere collapse to zero width for an Obsidian-style preview.
    private(set) var revealedRange = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    /// Reveals the markdown markers inside `range` (collapsing all others) and
    /// rebuilds every line whose marker visibility changed — the whole document
    /// when `force` is set, otherwise just the union of the old and new revealed
    /// ranges. Returns whether anything actually changed.
    ///
    /// Both invalidations below are required. Regenerating glyphs re-tags the
    /// markers as control characters (`shouldGenerateGlyphs`), but collapsing
    /// them to zero width is a *layout*-time decision (`shouldUse:
    /// forControlCharacterAt:`). Without also invalidating layout, the cached
    /// line fragments keep the previous marker widths, so the reveal/collapse
    /// never takes visual effect as the caret moves between lines — the markers
    /// appear "stuck" on whichever line first revealed them.
    @discardableResult
    func setRevealedRange(_ range: NSRange, force: Bool) -> Bool {
        guard let storage = textStorage, storage.length > 0 else {
            revealedRange = range
            return false
        }
        let previous = revealedRange
        guard force || !NSEqualRanges(previous, range) else { return false }
        revealedRange = range

        let length = storage.length
        let invalidation = force
            ? NSRange(location: 0, length: length)
            : rangeUnion(previous, range, length: length)
        invalidateGlyphs(forCharacterRange: invalidation, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: invalidation, actualCharacterRange: nil)
        if let container = textContainers.first {
            ensureLayout(for: container)
        }
        return true
    }

    private func rangeUnion(_ a: NSRange, _ b: NSRange, length: Int) -> NSRange {
        let lower = max(0, min(a.location, b.location))
        let upper = min(length, max(NSMaxRange(a), NSMaxRange(b)))
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// A marker character is hidden when it is tagged `.knotqMarker` and falls
    /// outside the revealed range.
    func isHiddenMarker(at charIndex: Int) -> Bool {
        guard let storage = textStorage, charIndex < storage.length else { return false }
        guard !NSLocationInRange(charIndex, revealedRange) else { return false }
        return storage.attribute(.knotqMarker, at: charIndex, effectiveRange: nil) != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let editor = editorTextView
        MainActor.assumeIsolated {
            editor?.drawChrome(forGlyphRange: glyphsToShow, at: origin)
        }
    }
}

extension EditorLayoutManager: NSLayoutManagerDelegate {
    /// Flag hidden marker glyphs as control characters so the zero-advancement
    /// action below collapses them without removing the characters from storage.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: UIFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        var changed = false
        for i in 0..<glyphRange.length {
            properties[i] = props[i]
            if isHiddenMarker(at: charIndexes[i]) {
                properties[i] = .controlCharacter
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(
            glyphs,
            properties: &properties,
            characterIndexes: charIndexes,
            font: aFont,
            forGlyphRange: glyphRange
        )
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHiddenMarker(at: charIndex) ? .zeroAdvancement : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        0
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        let editor = editorTextView
        return MainActor.assumeIsolated {
            editor?.annotationSpacingAfterGlyph(at: glyphIndex) ?? 0
        }
    }
}
