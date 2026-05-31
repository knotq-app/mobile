import SwiftUI
import UIKit

private struct EditorDateTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
}

@MainActor
final class EditorController: ObservableObject {
    weak var view: EditorTextView?
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
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)
                        if !scheme.isDailyQueue {
                            SchemeArchiveButton(theme: theme) {
                                pendingArchive = .scheme(scheme)
                            }
                        }
                    }
                    .padding(.leading, 6)
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

            HStack(spacing: 4) {
                SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)
                if !scheme.isDailyQueue {
                    SchemeArchiveButton(theme: theme) {
                        pendingArchive = .scheme(scheme)
                    }
                }
            }
            .padding(.leading, 6)
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

private struct SchemeArchiveButton: View {
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "archivebox")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Archive")
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
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 18, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(theme.borderOverlay, lineWidth: 1)
                }
                .frame(width: 24, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
        .popover(isPresented: $showingPicker, arrowEdge: .top) {
            SchemeColorPickerPopover(
                scheme: scheme,
                theme: theme,
                colorOrder: colorOrder
            ) { index in
                model.setSchemeColor(id: scheme.id, colorIndex: index)
                showingPicker = false
            }
            .presentationCompactAdaptation(.popover)
            .presentationBackground(theme.bgApp)
            .presentationCornerRadius(12)
        }
    }
}

private struct SchemeColorPickerPopover: View {
    let scheme: MobileScheme
    let theme: KnotQTheme
    let colorOrder: [Int32]
    let onSelect: (Int32) -> Void

    private let columns = Array(repeating: GridItem(.fixed(42), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(colorOrder, id: \.self) { index in
                let selected = index == scheme.colorIndex
                Button {
                    onSelect(index)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? theme.rowSelected : Color.clear)
                            .frame(width: 42, height: 42)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(schemeColor(index, dark: theme.isDark))
                            .frame(width: 28, height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selected ? theme.textPrimary : theme.borderOverlay, lineWidth: selected ? 2 : 0.8)
                            }
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.isDark ? Color.black.opacity(0.82) : Color.white)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color")
            }
        }
        .padding(8)
        .background(theme.bgApp)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.dividerSoft, lineWidth: 1)
        }
    }
}
