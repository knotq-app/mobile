import SwiftUI
import UIKit

struct SchemeTextView: UIViewRepresentable {
    let controller: EditorController
    let items: [MobileItem]
    let timeFormat: String
    let theme: KnotQTheme
    let accent: Color
    let isScrollEnabled: Bool
    let textInsets: UIEdgeInsets
    let schemeTitle: String
    let showsTitle: Bool
    let titleEditable: Bool
    let titleValidator: (String) -> String?
    let onRenameTitle: (String) -> Void
    let onDate: () -> Void
    let onImageUpload: () -> Void
    let onInsertTable: () -> Void
    /// Persists an in-place cell edit (cell hit + new first-line text).
    let onTableCellCommit: (EditorTableCellHit, String) -> Void
    /// Row/column structure ops from the cell editor's accessory bar.
    let onTableInsertRow: (EditorTableCellHit, Int) -> Void
    let onTableDeleteRow: (EditorTableCellHit) -> Void
    let onTableInsertColumn: (EditorTableCellHit, Int) -> Void
    let onTableDeleteColumn: (EditorTableCellHit) -> Void
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
        coordinator.onImageUploadRequested = onImageUpload
        coordinator.onInsertTableRequested = onInsertTable
        coordinator.readOnly = readOnly
        view.onTableCellCommit = onTableCellCommit
        view.onTableInsertRow = onTableInsertRow
        view.onTableDeleteRow = onTableDeleteRow
        view.onTableInsertColumn = onTableInsertColumn
        view.onTableDeleteColumn = onTableDeleteColumn
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
        view.configureTitle(title: schemeTitle, theme: theme, visible: showsTitle, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        let checkboxTap = UITapGestureRecognizer(target: coordinator, action: #selector(EditorCoordinator.handleEditorTap(_:)))
        checkboxTap.delegate = coordinator
        checkboxTap.cancelsTouchesInView = false
        coordinator.checkboxTapRecognizer = checkboxTap
        view.addGestureRecognizer(checkboxTap)
        controller.view = view
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        // Populate storage before SwiftUI's first sizeThatFits pass so a
        // self-sizing (Daily feed) editor measures real content from frame one;
        // the pane's onAppear load runs only after layout.
        view.loadItems(items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: false)
        return view
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        let accentColor = UIColor(accent)
        let themeChanged = uiView.theme.isDark != theme.isDark
        let accentChanged = uiView.accentColor != accentColor
        let insetsChanged = uiView.textContainerInset != textInsets
        coordinator.theme = theme
        coordinator.accentColor = accentColor
        coordinator.onDateRequested = onDate
        coordinator.onImageUploadRequested = onImageUpload
        coordinator.onInsertTableRequested = onInsertTable
        coordinator.readOnly = readOnly
        uiView.onTableCellCommit = onTableCellCommit
        uiView.onTableInsertRow = onTableInsertRow
        uiView.onTableDeleteRow = onTableDeleteRow
        uiView.onTableInsertColumn = onTableInsertColumn
        uiView.onTableDeleteColumn = onTableDeleteColumn
        // Every UIKit write below is equality-guarded: updateUIView re-runs on
        // each ancestor re-render (every model snapshot, every live flush), and
        // UITextView setters like textContainerInset invalidate text layout even
        // when the value is unchanged — visible as a small scroll jump / late
        // caret while typing near the bottom of the document.
        if themeChanged {
            uiView.theme = theme
            uiView.backgroundColor = UIColor(theme.bgApp)
        }
        if accentChanged {
            uiView.accentColor = accentColor
        }
        if insetsChanged {
            uiView.textContainerInset = textInsets
        }
        if uiView.isScrollEnabled != isScrollEnabled {
            uiView.isScrollEnabled = isScrollEnabled
        }
        if uiView.keyboardDismissMode != .none {
            uiView.keyboardDismissMode = .none
        }
        if uiView.isEditable == readOnly {
            uiView.isEditable = !readOnly
        }
        if !uiView.isSelectable {
            uiView.isSelectable = true
        }
        if themeChanged {
            uiView.restyleForTheme(theme)
        }
        if readOnly, uiView.inputAccessoryView != nil {
            uiView.inputAccessoryView = nil
        }
        uiView.configureTitle(title: schemeTitle, theme: theme, visible: showsTitle, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        if themeChanged || accentChanged || insetsChanged {
            uiView.refreshEmbeddedLayoutIfNeeded(deferred: true)
            uiView.setNeedsDisplay()
        }
    }

    /// Self-sizing for embedded (non-scrolling) editors: report the exact
    /// TextKit-measured height for the proposed width so the Daily feed lays
    /// days out without estimated heights. Scrolling editors keep the default
    /// fill-proposed-space behavior.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorTextView, context: Context) -> CGSize? {
        guard !isScrollEnabled else { return nil }
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.measuredHeight(forWidth: width))
    }
}
