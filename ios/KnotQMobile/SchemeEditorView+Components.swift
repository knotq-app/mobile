import SwiftUI
import UIKit

private struct EditorDateTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
}

@MainActor
final class EditorController: ObservableObject {
    fileprivate weak var view: EditorTextView?
    @Published var isDirty = false
    @Published var isEmpty = true

    func load(items: [MobileItem], theme: KnotQTheme, timeFormat: String, placeCursorAtEnd: Bool = false) {
        view?.loadItems(items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: placeCursorAtEnd)
        isDirty = false
        isEmpty = items.isEmpty || items.allSatisfy { $0.text.isEmpty && $0.marker == "blank" && $0.indent == 0 && $0.start == nil && $0.end == nil }
    }

    func commit() -> [MobileItemEdit] {
        view?.extractItemEdits() ?? []
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

    /// Activates the text view so the system shows the caret + keyboard.
    func focus() {
        guard let view, !view.isFirstResponder else { return }
        view.becomeFirstResponder()
    }

    func blur() {
        view?.resignFirstResponder()
    }

    func focusTitle() {
        view?.focusTitle()
    }
}

private final class TransparentInputAccessoryView: UIInputView {
    init(frame: CGRect) {
        super.init(frame: frame, inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frame.height > 0 ? frame.height : 44)
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

    private func clearAccessoryChrome() {
        var next: UIView? = self
        for _ in 0..<8 {
            next?.backgroundColor = .clear
            next?.isOpaque = false
            next = next?.superview
        }
    }
}

struct IntegratedSchemeEditorPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scheme: MobileScheme
    let theme: KnotQTheme
    let onBack: (() -> Void)?
    let onAdd: () -> Void
    let usesNativeNavigation: Bool
    let showsEditorNavigation: Bool
    let editorScrollEnabled: Bool
    let editorInsets: UIEdgeInsets

    @StateObject private var controller = EditorController()
    @State private var schemeSignature = ""
    @State private var dateTarget: EditorDateTarget?
    @State private var pendingArchive: ArchiveTarget?
    @State private var loadedSchemeID: String?

    private var accent: Color {
        schemeColor(scheme.colorIndex, dark: theme.isDark)
    }

    private var timeFormat: String {
        model.snapshot?.settings.timeFormat ?? "twelve_hour"
    }

    private var editorTextInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: editorInsets.top + DesktopEditorMetrics.titleBlockHeight,
            left: editorInsets.left,
            bottom: editorInsets.bottom,
            right: editorInsets.right
        )
    }

    let autoFocusOnAppear: Bool
    let autoFocusTitleOnAppear: Bool
    let onAutoFocusTitleConsumed: () -> Void

    init(
        scheme: MobileScheme,
        theme: KnotQTheme,
        onBack: (() -> Void)?,
        onAdd: @escaping () -> Void,
        usesNativeNavigation: Bool = false,
        showsEditorNavigation: Bool = true,
        editorScrollEnabled: Bool = true,
        editorInsets: UIEdgeInsets = UIEdgeInsets(top: 6, left: DesktopEditorMetrics.textLeftPad, bottom: 120, right: 24),
        autoFocusOnAppear: Bool = false,
        autoFocusTitleOnAppear: Bool = false,
        onAutoFocusTitleConsumed: @escaping () -> Void = {}
    ) {
        self.scheme = scheme
        self.theme = theme
        self.onBack = onBack
        self.onAdd = onAdd
        self.usesNativeNavigation = usesNativeNavigation
        self.showsEditorNavigation = showsEditorNavigation
        self.editorScrollEnabled = editorScrollEnabled
        self.editorInsets = editorInsets
        self.autoFocusOnAppear = autoFocusOnAppear
        self.autoFocusTitleOnAppear = autoFocusTitleOnAppear
        self.onAutoFocusTitleConsumed = onAutoFocusTitleConsumed
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsEditorNavigation && !usesNativeNavigation {
                editorNavigationBar
            }

            ZStack(alignment: .topLeading) {
                SchemeTextView(
                    controller: controller,
                    theme: theme,
                    accent: accent,
                    isScrollEnabled: editorScrollEnabled,
                    textInsets: editorTextInsets,
                    schemeTitle: scheme.displayName,
                    titleEditable: !scheme.isDailyQueue,
                    titleValidator: titleValidator,
                    onRenameTitle: { title in
                        model.renameScheme(id: scheme.id, name: title)
                    },
                    onDate: openDateForLine,
                    readOnly: scheme.isReadOnly
                )

            }
            .clipped()
        }
        .background(theme.bgApp.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesNativeNavigation && showsEditorNavigation {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)
                    if !scheme.isDailyQueue {
                        Button {
                            pendingArchive = .scheme(scheme)
                        } label: {
                            Image(systemName: "archivebox")
                        }
                    }
                }
            }
        }
        .onAppear {
            loadDocument(force: true)
            if autoFocusTitleOnAppear {
                DispatchQueue.main.async {
                    controller.focusTitle()
                    onAutoFocusTitleConsumed()
                }
            } else if autoFocusOnAppear {
                // Focus on the next runloop tick (once the text view is in the
                // window) rather than after a fixed delay, so the caret + scroll
                // land immediately instead of a beat later.
                DispatchQueue.main.async {
                    controller.focus()
                }
            }
        }
        .onChange(of: signature(for: scheme)) { _, newValue in
            guard newValue != schemeSignature else { return }
            loadDocument(force: false)
        }
        .onChange(of: timeFormat) { _, _ in loadDocument(force: true) }
        .onDisappear {
            controller.blur()
            commitDocument()
        }
        .sheet(item: $dateTarget) { target in
            if let item = model.scheme(id: scheme.id)?.items.first(where: { $0.id == target.itemID }) {
                ItemDateSheet(schemeID: scheme.id, item: item)
                    .presentationDetents([.fraction(0.50)])
            }
        }
        .archiveConfirmation(target: $pendingArchive) { _ in
            archiveCurrentScheme()
        }
    }

    private var editorNavigationBar: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: {
                    commitDocument()
                    onBack()
                }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }

            Spacer()

            SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)

            if !scheme.isDailyQueue {
                Button {
                    pendingArchive = .scheme(scheme)
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }

    private func loadDocument(force: Bool) {
        if !force && controller.isDirty { return }
        let shouldPlaceCursorAtEnd = loadedSchemeID != scheme.id
        controller.load(items: scheme.items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: shouldPlaceCursorAtEnd)
        schemeSignature = signature(for: scheme)
        loadedSchemeID = scheme.id
    }

    private func commitDocument() {
        guard !scheme.isReadOnly else {
            controller.isDirty = false
            return
        }
        guard controller.isDirty else { return }
        let edits = controller.commit()
        model.replaceSchemeItems(schemeID: scheme.id, items: edits)
        if let refreshed = model.scheme(id: scheme.id) {
            controller.load(items: refreshed.items, theme: theme, timeFormat: timeFormat)
            schemeSignature = signature(for: refreshed)
        } else {
            controller.isDirty = false
        }
    }

    private func archiveCurrentScheme() {
        guard !scheme.isDailyQueue else { return }
        commitDocument()
        model.archiveScheme(id: scheme.id)
        if usesNativeNavigation {
            dismiss()
        } else {
            onBack?()
        }
    }

    private func openDateForLine() {
        guard !scheme.isReadOnly else { return }
        commitDocument()
        guard let itemID = controller.currentLineItemID(),
              let currentScheme = model.scheme(id: scheme.id),
              currentScheme.items.contains(where: { $0.id == itemID }) else { return }
        dateTarget = EditorDateTarget(itemID: itemID)
    }

    private func signature(for scheme: MobileScheme) -> String {
        scheme.items
            .map { "\($0.id)|\($0.text)|\($0.marker)|\($0.indent)|\($0.done)|\($0.start ?? "")|\($0.end ?? "")" }
            .joined(separator: "\n")
    }

    private func titleValidator(_ name: String) -> String? {
        guard !scheme.isDailyQueue else {
            return WorkspaceNameValidation.schemeError(name)
        }
        let root = model.snapshot?.root
        let folderID = WorkspaceNameValidation.parentFolderID(containingSchemeID: scheme.id, root: root)
        return WorkspaceNameValidation.schemeError(name, root: root, folderID: folderID, excludingID: scheme.id)
    }
}

private struct SchemeColorPickerButton: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    let accent: Color
    @State private var showingPicker = false

    private let colorOrder: [Int32] = [0, 1, 5, 2, 3, 4]

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(accent)
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(theme.borderOverlay, lineWidth: 1)
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
        .popover(isPresented: $showingPicker, arrowEdge: .top) {
            HStack(spacing: 8) {
                ForEach(colorOrder, id: \.self) { index in
                    Button {
                        model.setSchemeColor(id: scheme.id, colorIndex: index)
                        showingPicker = false
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(schemeColor(index, dark: theme.isDark))
                            .frame(width: 34, height: 34)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(index == scheme.colorIndex ? theme.textPrimary : theme.borderOverlay, lineWidth: index == scheme.colorIndex ? 2 : 0.8)
                            }
                            .overlay {
                                if index == scheme.colorIndex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.isDark ? Color.black.opacity(0.82) : Color.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color")
                }
            }
            .padding(12)
            .background(theme.bgModal)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Theme helpers

private extension KnotQTheme {
    var editorChromeColor: UIColor {
        UIColor(hex: isDark ? 0xb8c9e8 : 0x536a8f)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - SchemeTextView

private struct SchemeTextView: UIViewRepresentable {
    let controller: EditorController
    let theme: KnotQTheme
    let accent: Color
    let isScrollEnabled: Bool
    let textInsets: UIEdgeInsets
    let schemeTitle: String
    let titleEditable: Bool
    let titleValidator: (String) -> String?
    let onRenameTitle: (String) -> Void
    let onDate: () -> Void
    let readOnly: Bool

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator()
    }

    func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.controller = controller
        coordinator.theme = theme
        coordinator.accentColor = UIColor(accent)
        coordinator.onDateRequested = onDate
        coordinator.readOnly = readOnly
        view.coordinator = coordinator
        view.theme = theme
        view.accentColor = UIColor(accent)
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.backgroundColor = UIColor(theme.bgApp)
        view.textColor = UIColor(theme.textPrimary)
        view.font = .systemFont(ofSize: DesktopEditorMetrics.textFontSize)
        view.textContainerInset = textInsets
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.textContainer.widthTracksTextView = true
        view.isScrollEnabled = isScrollEnabled
        // When embedded with scrolling disabled (e.g. the Daily feed), let the
        // parent SwiftUI layout dictate width instead of UITextView insisting
        // on its intrinsic (effectively unbounded) width.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.keyboardDismissMode = .none
        view.alwaysBounceVertical = true
        view.autocapitalizationType = .sentences
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.isEditable = !readOnly
        view.isSelectable = true
        view.inputAccessoryView = readOnly ? nil : coordinator.makeToolbar(for: view)
        view.configureTitle(title: schemeTitle, theme: theme, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        let checkboxTap = UITapGestureRecognizer(target: coordinator, action: #selector(EditorCoordinator.handleEditorTap(_:)))
        checkboxTap.delegate = coordinator
        checkboxTap.cancelsTouchesInView = false
        view.addGestureRecognizer(checkboxTap)
        controller.view = view
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        return view
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.theme = theme
        coordinator.accentColor = UIColor(accent)
        coordinator.onDateRequested = onDate
        coordinator.readOnly = readOnly
        uiView.theme = theme
        uiView.accentColor = UIColor(accent)
        uiView.backgroundColor = UIColor(theme.bgApp)
        uiView.textContainerInset = textInsets
        uiView.isScrollEnabled = isScrollEnabled
        uiView.keyboardDismissMode = .none
        uiView.isEditable = !readOnly
        uiView.isSelectable = true
        uiView.inputAccessoryView = readOnly ? nil : uiView.inputAccessoryView ?? coordinator.makeToolbar(for: uiView)
        uiView.configureTitle(title: schemeTitle, theme: theme, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        uiView.setNeedsDisplay()
    }
}

// MARK: - Editor coordinator

@MainActor
private final class EditorCoordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate, UIGestureRecognizerDelegate {
    weak var view: EditorTextView?
    weak var controller: EditorController?
    var theme: KnotQTheme = .dark
    var accentColor: UIColor = .systemBlue
    var onDateRequested: (() -> Void)?
    var readOnly = false

    private var suppressDelegateDepth = 0
    private var autoBulletizePending = false
    fileprivate var autoBulletUndo: (lineLocation: Int, originalBody: String)?

    // Toolbar marker buttons keyed by Marker, so we can tint the active one.
    private var markerButtons: [Marker: UIButton] = [:]

    func suppress(_ block: () -> Void) {
        suppressDelegateDepth += 1
        defer { suppressDelegateDepth -= 1 }
        block()
    }

    func markDirty() {
        guard !readOnly else { return }
        controller?.isDirty = true
    }

    private func refreshEmpty() {
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
    }

    /// Highlights the toolbar marker button matching the caret's line.
    fileprivate func refreshToolbarActiveMarker(in textView: UITextView) {
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
        _ = view.toggleCheckboxAt(point: recognizer.location(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !readOnly else { return false }
        guard let view else { return false }
        return view.checkboxLineRange(at: touch.location(in: view)) != nil
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !readOnly else { return false }
        guard let view = textView as? EditorTextView else { return true }
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
        }
        // Any non-backspace edit clears the pending auto-bullet undo.
        if !(text.isEmpty && range.length == 1) {
            autoBulletUndo = nil
        }
        return true
    }

    /// Desktop parity: backspace at col 0 of a line with a non-blank marker
    /// clears the marker first instead of joining lines. The user has to
    /// backspace a second time to actually merge with the previous line.
    private func handleClearMarkerBackspace(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        // backspace at column 0 of paragraph P targets the prior "\n"; the
        // caret sits at P.location, deletionRange = (P.location - 1, 1).
        let caret = deletionRange.location + 1
        guard caret <= ns.length else { return false }
        let para = editableParagraphRange(in: ns, at: caret)
        guard caret == para.location, para.location > 0 else { return false }
        let meta = lineMeta(at: para.location, in: storage)
        guard meta.marker != .blank else { return false }
        let cleared = LineMeta(
            marker: .blank,
            indent: meta.indent,
            done: false,
            itemID: meta.itemID,
            annotation: nil,
            media: meta.media
        )
        suppress {
            storage.beginEditing()
            setLineMeta(cleared, onParagraph: para, in: storage, theme: theme)
            storage.endEditing()
        }
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: cleared, theme: theme)
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        return true
    }

    // MARK: - Edit handlers (called from shouldChangeTextIn)

    /// Backspace immediately after auto-bulletize → undo the conversion.
    /// Auto-bulletize left the caret at col 0 of the converted line; that
    /// backspace would otherwise delete the prior newline.
    private func handleAutoBulletUndo(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        guard let undo = autoBulletUndo else { return false }
        guard deletionRange.location == undo.lineLocation - 1,
              deletionRange.length == 1 else {
            autoBulletUndo = nil
            return false
        }
        let storage = view.textStorage
        let paraRange = editableParagraphRange(in: storage.string as NSString, at: undo.lineLocation)
        let body = bodyText(paragraphRange: paraRange, in: storage)
        let bodyRange = NSRange(location: paraRange.location, length: (body as NSString).length)
        let restoredMeta = LineMeta()
        let attrs = EditorAttributes.bodyAttributes(meta: restoredMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: bodyRange, with: NSAttributedString(string: undo.originalBody, attributes: attrs))
            let restored = editableParagraphRange(in: storage.string as NSString, at: paraRange.location)
            setLineMeta(restoredMeta, onParagraph: restored, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(
            location: paraRange.location + (undo.originalBody as NSString).length,
            length: 0
        )
        view.typingAttributes = attrs
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        return true
    }

    /// Enter: either escape an empty marker line (clear marker, no insertion),
    /// or split the current paragraph and continue the marker on the new line.
    /// With invariant I3 the caret is always within a real paragraph, so the
    /// "cursor past end of storage" edge case no longer needs special handling.
    private func handleEnter(in view: EditorTextView, at cursor: Int) -> Bool {
        let storage = view.textStorage
        let paraRange = editableParagraphRange(in: storage.string as NSString, at: cursor)
        let body = bodyText(paragraphRange: paraRange, in: storage)
        let currentMeta = lineMeta(at: paraRange.location, in: storage)

        // Empty marker line → escape: clear marker without inserting a newline.
        if body.isEmpty && currentMeta.marker != .blank {
            let cleared = LineMeta(
                marker: .blank,
                indent: currentMeta.indent,
                done: false,
                itemID: currentMeta.itemID,
                annotation: nil,
                media: currentMeta.media
            )
            suppress {
                storage.beginEditing()
                setLineMeta(cleared, onParagraph: paraRange, in: storage, theme: theme)
                storage.endEditing()
            }
            view.typingAttributes = EditorAttributes.bodyAttributes(meta: cleared, theme: theme)
            markDirty()
            return true
        }

        // Split the paragraph at the caret: old half keeps currentMeta, new half
        // gets continuation meta (fresh identity, same marker/indent/done-reset).
        let newMeta = continuationMeta(currentMeta)
        let oldAttrs = EditorAttributes.bodyAttributes(meta: currentMeta, theme: theme)
        let newAttrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: cursor, length: 0),
                with: NSAttributedString(string: "\n", attributes: oldAttrs)
            )
            // Re-establish meta uniformly on both halves.
            let ns = storage.string as NSString
            let oldHalf = editableParagraphRange(in: ns, at: cursor)
            let newHalf = editableParagraphRange(in: ns, at: cursor + 1)
            setLineMeta(currentMeta, onParagraph: oldHalf, in: storage, theme: theme)
            setLineMeta(newMeta, onParagraph: newHalf, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: cursor + 1, length: 0)
        view.typingAttributes = newAttrs
        markDirty()
        refreshEmpty()
        return true
    }

    private func continuationMeta(_ meta: LineMeta) -> LineMeta {
        LineMeta(marker: meta.marker, indent: meta.indent, done: false, itemID: nil, annotation: nil)
    }

    // MARK: NSTextStorageDelegate

    /// After any user edit we (a) re-establish invariants I1 + I2 and (b) try
    /// auto-bulletize. Programmatic edits (set marker, toggle indent, etc.)
    /// suppress this callback because they already maintain the invariants.
    func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard suppressDelegateDepth == 0 else { return }
        guard actions.contains(.editedCharacters) else { return }

        suppress {
            storage.beginEditing()
            ensureWellFormed(storage, theme: theme)
            normalizeAffectedParagraphs(in: storage, around: editedRange)
            storage.endEditing()
        }

        if !autoBulletizePending {
            autoBulletizePending = true
            let editLocation = editedRange.location
            DispatchQueue.main.async { [weak self] in
                self?.autoBulletizePending = false
                self?.maybeAutoBulletize(at: editLocation)
            }
        }
    }

    /// Re-applies meta + styling uniformly on every paragraph that overlaps the
    /// edit. Detects "cloned" paragraphs (where UITextView's attribute extension
    /// leaked an itemID/annotation from the previous paragraph) by reference
    /// equality of the .knotqLine value and resets identity on those.
    private func normalizeAffectedParagraphs(in storage: NSTextStorage, around editedRange: NSRange) {
        let ns = storage.string as NSString
        let editParaRange = ns.paragraphRange(for: editedRange)
        for paragraph in paragraphRanges(in: ns, intersecting: editParaRange) {
            let fullRange = paragraph.fullRange
            guard fullRange.length > 0 else { continue }
            var meta = paragraphMeta(of: fullRange, in: storage)
            if fullRange.location > 0 {
                let prev = storage.attribute(.knotqLine, at: fullRange.location - 1, effectiveRange: nil) as? LineMeta
                if let prev, prev === meta {
                    // Cloned via attribute inheritance — fresh paragraph, reset identity.
                    meta = LineMeta(
                        marker: prev.marker,
                        indent: prev.indent,
                        done: false,
                        itemID: nil,
                        annotation: nil,
                        media: []
                    )
                }
            }
            setLineMeta(meta, onParagraph: fullRange, in: storage, theme: theme)
        }
    }

    /// Detects "- ", "* ", or "N. " typed on a blank line and converts the
    /// marker. Runs asynchronously after the typing settles so the caret is in
    /// a consistent position.
    private func maybeAutoBulletize(at editLocation: Int) {
        guard let view else { return }
        let storage = view.textStorage
        let paraRange = editableParagraphRange(in: storage.string as NSString, at: editLocation)
        let body = bodyText(paragraphRange: paraRange, in: storage)
        guard !body.isEmpty else { return }
        let currentMeta = lineMeta(at: paraRange.location, in: storage)
        guard currentMeta.marker == .blank else { return }

        let newMarker: Marker
        if body == "- " || body == "* " {
            newMarker = .bullet
        } else if body.range(of: #"^\d+\.\s$"#, options: .regularExpression) != nil {
            newMarker = .numbered
        } else {
            return
        }

        autoBulletUndo = (lineLocation: paraRange.location, originalBody: body)
        let newMeta = currentMeta.with(marker: newMarker, done: false)
        let bodyRange = NSRange(location: paraRange.location, length: (body as NSString).length)
        let attrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: bodyRange, with: NSAttributedString(string: "", attributes: attrs))
            let updated = editableParagraphRange(in: storage.string as NSString, at: paraRange.location)
            setLineMeta(newMeta, onParagraph: updated, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: paraRange.location, length: 0)
        view.typingAttributes = attrs
        markDirty()
    }

    // MARK: Toolbar

    func makeToolbar(for textView: UITextView) -> UIView {
        markerButtons.removeAll()
        let width = UIScreen.main.bounds.width
        let container = TransparentInputAccessoryView(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        container.autoresizingMask = [.flexibleWidth]
        container.backgroundColor = .clear
        container.isOpaque = false
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolbarPan(_:)))
        dismissPan.cancelsTouchesInView = false
        container.addGestureRecognizer(dismissPan)

        // Liquid glass background (iOS 26+). Falls back to an ultra-thin
        // material so older OSes still render something readable above the
        // keyboard. The glass replaces per-button chip backgrounds; the bar
        // itself is the only floating surface.
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

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        backdrop.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(stack)

        // Desktop format-palette order, with dismiss-keyboard as the leftmost
        // glyph and section dividers between functional groups.
        let blank = markerButton(.blank, systemName: "text.alignleft")
        let checkbox = markerButton(.checkbox, systemName: "checkmark.square")
        let bullet = markerButton(.bullet, systemName: "list.bullet")
        let numbered = markerButton(.numbered, systemName: "list.number")
        [
            toolbarButton("keyboard.chevron.compact.down") { [weak textView] in textView?.resignFirstResponder() },
            separator(),
            blank, checkbox, bullet, numbered,
            separator(),
            toolbarButton("decrease.indent") { [weak self] in self?.view?.shiftCurrentIndent(-1, theme: self?.theme ?? .dark) },
            toolbarButton("increase.indent") { [weak self] in self?.view?.shiftCurrentIndent(1, theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("calendar.badge.clock") { [weak self] in self?.onDateRequested?() },
            separator(),
            toolbarButton("bold") { [weak self] in self?.view?.toggleWrappedMarkdown("*", theme: self?.theme ?? .dark) },
            toolbarButton("italic") { [weak self] in self?.view?.toggleWrappedMarkdown("_", theme: self?.theme ?? .dark) },
            toolbarButton("textformat.size") { [weak self] in self?.view?.toggleHeading(theme: self?.theme ?? .dark) },
        ].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        return container
    }

    @objc private func handleToolbarPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        guard recognizer.state == .ended || recognizer.state == .changed else { return }
        if translation.y > 22, translation.y > abs(translation.x) * 1.25 {
            view?.resignFirstResponder()
        }
    }

    private func markerButton(_ marker: Marker, systemName: String) -> UIButton {
        let button = toolbarButton(systemName) { [weak self] in
            guard let self else { return }
            self.view?.setCurrentMarker(marker, theme: self.theme)
        }
        markerButtons[marker] = button
        return button
    }

    private func toolbarButton(_ systemName: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold),
            forImageIn: .normal
        )
        button.tintColor = UIColor(theme.textDim)
        button.backgroundColor = .clear
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(theme.dividerSoft)
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }
}

// MARK: - EditorTextView

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

    func configure(title: String, theme: KnotQTheme, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        self.validator = validator
        self.onCommit = onCommit
        textField.textColor = UIColor(theme.textPrimary)
        normalTintColor = UIColor(theme.accent)
        errorTintColor = UIColor(theme.danger)
        errorLabel.textColor = errorTintColor
        textField.isUserInteractionEnabled = editable
        if !textField.isFirstResponder {
            committedTitle = title
            textField.text = title
        }
        if !editable, textField.isFirstResponder {
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

private final class EditorTextView: UITextView {
    var theme: KnotQTheme = .dark { didSet { setNeedsDisplay() } }
    var accentColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
    weak var coordinator: EditorCoordinator?

    private let inlineTitleView = EditorInlineTitleView()
    private let editorLayoutManager: EditorLayoutManager
    private var imageCache: [String: UIImage] = [:]

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

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineTitleView()
        // With scrolling disabled (Daily feed), recompute intrinsic height after
        // the parent grants a width — otherwise wrapping is calculated against
        // an unbounded container and the text never breaks.
        if !isScrollEnabled, bounds.width != lastIntrinsicWidth {
            lastIntrinsicWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
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
        let maxHeight = DesktopEditorMetrics.textLineHeight
        if rect.height > maxHeight {
            rect.origin.y += (rect.height - maxHeight) / 2
            rect.size.height = maxHeight
        }
        rect.size.width = max(2, min(rect.width, 2))
        return rect
    }

    func configureTitle(title: String, theme: KnotQTheme, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        inlineTitleView.configure(title: title, theme: theme, editable: editable, validator: validator, onCommit: onCommit)
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
        if placeCursorAtEnd {
            scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
            // On first open the text view often has no real bounds yet, so the
            // initial scroll lands nowhere. Re-scroll to the end once layout has
            // settled so we reliably open at the very bottom of the document.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollRangeToVisible(NSRange(location: max(0, self.textStorage.length - 1), length: 0))
            }
        }
        setNeedsDisplay()
        coordinator?.markClean()
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
        return body.isEmpty && m.marker == .blank && m.indent == 0 && m.annotation == nil
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
            media: old.media
        )
        applyMeta(new, paragraphRange: para, theme: theme)
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
    fileprivate func toggleCheckboxAt(point: CGPoint) -> Bool {
        let ns = textStorage.string as NSString
        guard let lineRange = checkboxLineRange(at: point) else { return false }
        let para = ns.paragraphRange(for: lineRange)
        let old = lineMeta(at: para.location, in: textStorage)
        applyMeta(old.with(done: !old.done), paragraphRange: para, theme: theme)
        return true
    }

    fileprivate func checkboxLineRange(at point: CGPoint) -> NSRange? {
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
            let mediaExtraHeight = mediaStackHeight(meta.media, maxWidth: editorImageMaxWidth(textLeft: firstFragment.minX))
            let rowExtraHeight = (meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight) + mediaExtraHeight
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
            if !meta.media.isEmpty {
                drawMediaStack(meta.media, meta: meta, firstFragment: firstFragment, visualBounds: visualBounds, context: context)
            }
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

    private func drawMediaStack(_ media: [MobileItemMedia], meta: LineMeta, firstFragment: CGRect, visualBounds: CGRect, context: CGContext) {
        guard !media.isEmpty else { return }
        let maxWidth = editorImageMaxWidth(textLeft: firstFragment.minX)
        let annotationHeight = meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight
        var y = visualBounds.maxY + annotationHeight + DesktopEditorMetrics.imageTopGap
        var drewImage = false
        for item in media where item.kind == "image" {
            let size = mediaDisplaySize(item, maxWidth: maxWidth)
            guard size.width > 0, size.height > 0 else { continue }
            if drewImage {
                y += DesktopEditorMetrics.imageStackGap
            }
            let rect = CGRect(x: firstFragment.minX, y: y, width: size.width, height: size.height)
            drawImageMedia(item, in: rect, context: context)
            y += size.height
            drewImage = true
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

    private func mediaStackHeight(_ media: [MobileItemMedia], maxWidth: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        var count = 0
        for item in media where item.kind == "image" {
            let size = mediaDisplaySize(item, maxWidth: maxWidth)
            guard size.height > 0 else { continue }
            height += count == 0 ? DesktopEditorMetrics.imageTopGap : DesktopEditorMetrics.imageStackGap
            height += size.height
            count += 1
        }
        return height
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

    private func editorImageMaxWidth(textLeft: CGFloat) -> CGFloat {
        max(120, bounds.width - textLeft - textContainerInset.right - 8)
    }

    private func editorImageMaxWidth(meta: LineMeta) -> CGFloat {
        let textLeft = textContainerInset.left
            + CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth
            + (meta.marker == .blank ? 0 : DesktopEditorMetrics.markerSlot)
        return editorImageMaxWidth(textLeft: textLeft)
    }

    private func annotationGuideX(marker: CGRect) -> CGFloat {
        marker.minX - (DesktopEditorMetrics.annotationBarGap + DesktopEditorMetrics.indentGuideXShift)
    }

    private func markerRect(for meta: LineMeta, fragment: CGRect) -> CGRect {
        CGRect(
            x: textContainerInset.left + CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth,
            y: fragment.minY + (fragment.height - DesktopEditorMetrics.checkboxSize) / 2,
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
        spacing += mediaStackHeight(meta.media, maxWidth: editorImageMaxWidth(meta: meta))
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
        controller?.isDirty = false
    }
}

// MARK: - NSLayoutManager subclass

private final class EditorLayoutManager: NSLayoutManager {
    weak var editorTextView: EditorTextView?

    override init() {
        super.init()
        delegate = self
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

// MARK: - Sheets

struct AddItemSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let schemeID: String
    @State private var text = ""
    @State private var marker: Marker = .checkbox

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item", text: $text, axis: .vertical)
                Picker("Marker", selection: $marker) {
                    ForEach(Marker.allCases) { marker in
                        Label(marker.label, systemImage: marker.icon).tag(marker)
                    }
                }
            }
            .navigationTitle("New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addItem(schemeID: schemeID, text: text, marker: marker)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// The line "Schedule" sheet. Mirrors the calendar's EventEditorSheet — a kind
/// segmented control, conditional start/end pickers with footer guidance, and a
/// repeat picker — but operates on an existing scheme line (it unschedules
/// rather than deleting). A header shows the owning scheme's colour + name.
struct ItemDateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    let schemeID: String
    let item: MobileItem

    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatChoice: RepeatChoice

    init(schemeID: String, item: MobileItem) {
        self.schemeID = schemeID
        self.item = item
        let startDate = MobileDate.parseDateTime(item.start)
        let endDate = MobileDate.parseDateTime(item.end)
        _hasStart = State(initialValue: startDate != nil)
        _hasEnd = State(initialValue: endDate != nil)
        _start = State(initialValue: startDate ?? endDate ?? Date())
        _end = State(initialValue: endDate ?? startDate?.addingTimeInterval(3600) ?? Date().addingTimeInterval(3600))
        _repeatChoice = State(initialValue: RepeatChoice.from(rrule: item.repeatRule))
    }

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    private var scheme: MobileScheme? { model.scheme(id: schemeID) }

    var body: some View {
        NavigationStack {
            Form {
                if let scheme {
                    Section {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(schemeColor(scheme.colorIndex, dark: theme.isDark))
                                .frame(width: 14, height: 14)
                            Text(scheme.displayName)
                                .font(.system(size: 15, weight: .semibold))
                            Spacer(minLength: 8)
                            if !item.text.isEmpty {
                                Text(item.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section {
                    Picker("Kind", selection: kindBinding) {
                        Text("Event").tag(CalendarKind.event)
                        Text("Reminder").tag(CalendarKind.reminder)
                        Text("Assignment").tag(CalendarKind.assignment)
                    }
                    .pickerStyle(.segmented)

                    if hasStart {
                        DatePicker(hasEnd ? "Start" : "At", selection: $start)
                            .onChange(of: start) { _, value in
                                if hasEnd, end < value { end = value.addingTimeInterval(3600) }
                            }
                    }
                    if hasEnd {
                        DatePicker(hasStart ? "End" : "Due", selection: $end, in: (hasStart ? start : Date.distantPast)...)
                    }
                }

                Section {
                    Picker("Repeat", selection: $repeatChoice) {
                        ForEach(RepeatChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "start", date: nil)
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "end", date: nil)
                        model.setItemRecurrence(schemeID: schemeID, itemID: item.id, rrule: nil)
                        dismiss()
                    } label: {
                        Label("Clear Schedule", systemImage: "calendar.badge.minus")
                    }
                    .disabled(item.start == nil && item.end == nil)
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasStart && !hasEnd)
                }
            }
        }
    }

    private var kindBinding: Binding<CalendarKind> {
        Binding(
            get: {
                switch (hasStart, hasEnd) {
                case (true, true): .event
                case (true, false): .reminder
                case (false, true): .assignment
                default: .event
                }
            },
            set: { kind in
                switch kind {
                case .event:
                    if !hasStart { start = hasEnd ? end.addingTimeInterval(-3600) : Date() }
                    if !hasEnd { end = start.addingTimeInterval(3600) }
                    hasStart = true
                    hasEnd = true
                    if end < start { end = start.addingTimeInterval(3600) }
                case .reminder:
                    if !hasStart { start = hasEnd ? end : Date() }
                    hasStart = true
                    hasEnd = false
                case .assignment:
                    if !hasEnd { end = hasStart ? start : Date() }
                    hasStart = false
                    hasEnd = true
                case .task:
                    break
                }
            }
        )
    }

    private func save() {
        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "start", date: hasStart ? start : nil)
        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "end", date: hasEnd ? end : nil)
        model.setItemRecurrence(schemeID: schemeID, itemID: item.id, rrule: repeatChoice.rrule)
        dismiss()
    }
}
