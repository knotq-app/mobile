import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
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
    // Bumped on every keystroke/structural edit (see `markDirty`). The editor view
    // observes it to debounce a live flush of the edits into the core (so a phone
    // edit pushes within ~1 s like desktop, instead of only on blur).
    @Published var editTick = 0
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
    /// by line identity (item id + offset within the line) — absolute offsets go
    /// stale as soon as the change touched anything above the caret — falling back
    /// to the clamped absolute offset when the caret's line is gone.
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
        if let itemID = context.itemID,
           let location = view.caretLocation(forItemID: itemID, offsetInLine: context.offsetInLine) {
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
    func adoptItemIDs(from items: [MobileItem], theme: KnotQTheme) {
        view?.adoptItemIDs(from: items, theme: theme)
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
    let transparentOverlayNavigation: Bool
    let editorScrollEnabled: Bool
    let editorInsets: UIEdgeInsets
    let showsInlineTitle: Bool

    @StateObject private var controller = EditorController()
    @State private var schemeSignature = ""
    @State private var dateTarget: EditorDateTarget?
    @State private var pendingArchive: ArchiveTarget?
    @State private var loadedSchemeID: String?
    @State private var showingImagePicker = false
    @State private var imagePickerItem: PhotosPickerItem?
    // Debounced live-commit while typing (push-on-type, like desktop).
    @State private var liveFlushWork: DispatchWorkItem?
    // Set when we flush our own edits, so the resulting snapshot echo doesn't
    // reload the editor and reset the caret mid-type.
    @State private var selfFlushEcho = false

    private var accent: Color {
        schemeColor(scheme.colorIndex, dark: theme.isDark)
    }

    private var timeFormat: String {
        model.snapshot?.settings.timeFormat ?? "twelve_hour"
    }

    private var editorTextInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: editorInsets.top + (showsInlineTitle ? DesktopEditorMetrics.titleBlockHeight : 0) + overlayNavigationInset,
            left: editorInsets.left,
            bottom: editorInsets.bottom,
            right: editorInsets.right
        )
    }

    private var showsOverlayNavigation: Bool {
        showsEditorNavigation && transparentOverlayNavigation
    }

    private var overlayNavigationInset: CGFloat {
        showsOverlayNavigation ? 54 : 0
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
        transparentOverlayNavigation: Bool = false,
        editorScrollEnabled: Bool = true,
        editorInsets: UIEdgeInsets = UIEdgeInsets(top: 6, left: DesktopEditorMetrics.textLeftPad, bottom: 120, right: 24),
        showsInlineTitle: Bool = true,
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
        self.transparentOverlayNavigation = transparentOverlayNavigation
        self.editorScrollEnabled = editorScrollEnabled
        self.editorInsets = editorInsets
        self.showsInlineTitle = showsInlineTitle
        self.autoFocusOnAppear = autoFocusOnAppear
        self.autoFocusTitleOnAppear = autoFocusTitleOnAppear
        self.onAutoFocusTitleConsumed = onAutoFocusTitleConsumed
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if usesEmbeddedNavigationBar {
                    editorNavigationBar(showsDivider: true)
                }

                ZStack(alignment: .topLeading) {
                    SchemeTextView(
                        controller: controller,
                        items: scheme.items,
                        timeFormat: timeFormat,
                        theme: theme,
                        accent: accent,
                        isScrollEnabled: editorScrollEnabled,
                        textInsets: editorTextInsets,
                        schemeTitle: scheme.displayName,
                        showsTitle: showsInlineTitle,
                        titleEditable: !scheme.isDailyQueue,
                        titleValidator: titleValidator,
                        onRenameTitle: { title in
                            model.renameScheme(id: scheme.id, name: title)
                        },
                        onDate: openDateForLine,
                        onImageUpload: {
                            controller.prepareImageUploadTarget()
                            showingImagePicker = true
                        },
                        onInsertTable: insertTableFromToolbar,
                        onTableCellCommit: commitTableCell,
                        onTableInsertRow: { hit, row in
                            guard !hit.isHeader else { return }
                            model.insertTableRow(schemeID: scheme.id, itemID: hit.itemID, row: Int32(row))
                        },
                        onTableDeleteRow: { hit in
                            guard !hit.isHeader else { return }
                            model.deleteTableRow(schemeID: scheme.id, itemID: hit.itemID, row: Int32(hit.row))
                        },
                        onTableInsertColumn: { hit, column in
                            model.insertTableColumn(schemeID: scheme.id, itemID: hit.itemID, column: Int32(column))
                        },
                        onTableDeleteColumn: { hit in
                            model.deleteTableColumn(schemeID: scheme.id, itemID: hit.itemID, column: Int32(hit.column))
                        },
                        readOnly: scheme.isReadOnly
                    )

                }
                .clipped()
            }

            if showsOverlayNavigation {
                editorNavigationBar(showsDivider: false)
            }
        }
        .background(theme.bgApp.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hideSystemNavigationBar)
        .toolbar(hideSystemNavigationBar ? .hidden : .automatic, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background {
            if usesNativeNavigation && !transparentOverlayNavigation && !usesEmbeddedNavigationBar {
                SchemeEditorTransparentNavigationBar()
            }
        }
        .toolbar {
            if usesNativeNavigation && showsEditorNavigation && !transparentOverlayNavigation && !usesEmbeddedNavigationBar {
                ToolbarItem(placement: .topBarTrailing) {
                    editorTrailingControls
                        .padding(.leading, 12)
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
            schemeSignature = newValue
            if selfFlushEcho {
                // Our own live flush echoing back through the snapshot — the editor
                // already shows this content, so don't reload (would reset the caret).
                selfFlushEcho = false
                return
            }
            if controller.isDirty {
                // A genuine remote change arrived while the user is mid-edit (the
                // core no longer reports the echo of our own push as a change).
                // Keystrokes still inside the live-flush window exist only in the
                // text view, so rebuilding from the remote list would drop them.
                // Merge per line — the user's unflushed lines win locally, remote
                // wins everywhere else — then flush the merge so the core and
                // every other device converge on it.
                liveFlushWork?.cancel()
                liveFlushWork = nil
                let localEdits = controller.commit()
                let merged = mergeRemoteSchemeItems(
                    remote: scheme.items,
                    baseline: controller.baselineItems,
                    local: localEdits
                )
                controller.reloadPreservingCaret(items: merged, theme: theme, timeFormat: timeFormat)
                if merged != scheme.items {
                    // The core still holds the plain remote state: keep the
                    // baseline there so a second remote change during the flush
                    // window still sees these lines as locally modified.
                    controller.baselineItems = scheme.items
                    controller.isDirty = true
                    scheduleLiveFlush()
                }
            } else {
                loadDocument(force: false)
            }
        }
        // Push-on-type: each keystroke re-arms a short debounce that flushes the
        // editor into the core (which then syncs over the socket), so phone edits
        // propagate live like desktop instead of only on blur.
        .onChange(of: controller.editTick) { _, _ in scheduleLiveFlush() }
        // On iPad the editor pane is reused across schemes (no fresh `onAppear`),
        // so creating a new scheme while one is already open needs this to select
        // its title — matching the iPhone flow where each scheme pushes a new view.
        .onChange(of: autoFocusTitleOnAppear) { _, shouldFocus in
            guard shouldFocus else { return }
            DispatchQueue.main.async {
                controller.focusTitle()
                onAutoFocusTitleConsumed()
            }
        }
        .onChange(of: timeFormat) { _, _ in loadDocument(force: true) }
        .onChange(of: imagePickerItem) { _, item in
            handlePickedImage(item)
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $imagePickerItem,
            matching: .images
        )
        .onDisappear {
            controller.blur()
            commitDocument()
        }
        .sheet(item: $dateTarget) { target in
            if let item = model.scheme(id: scheme.id)?.items.first(where: { $0.id == target.itemID }) {
                // iPad presents as a centered form sheet; iPhone keeps the
                // half-height bottom sheet.
                if isPadLayout {
                    ItemDateSheet(schemeID: scheme.id, item: item)
                } else {
                    ItemDateSheet(schemeID: scheme.id, item: item)
                        .presentationDetents([.fraction(0.50)])
                }
            }
        }
        .archiveConfirmation(target: $pendingArchive) { _ in
            archiveCurrentScheme()
        }
    }

    private func editorNavigationBar(showsDivider: Bool) -> some View {
        HStack(spacing: 8) {
            if let onBack {
                if isPadLayout {
                    SchemeEditorGlassSurface(theme: theme, minWidth: 38) {
                        Button(action: {
                            commitDocument()
                            onBack()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(SchemeTopLipIconButton(theme: theme))
                        .accessibilityLabel("Back")
                    }
                } else {
                    SchemeEditorGlassSurface(theme: theme, minWidth: 38) {
                        Button(action: {
                            commitDocument()
                            onBack()
                        }) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(SchemeTopLipIconButton(theme: theme))
                        .accessibilityLabel("Back")
                    }
                }
            }

            Spacer()

            editorTrailingControls
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(height: 1)
            }
        }
    }

    private var usesEmbeddedNavigationBar: Bool {
        showsEditorNavigation
            && !transparentOverlayNavigation
            && !showsOverlayNavigation
            && (!usesNativeNavigation || isPadLayout)
    }

    private var isPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var isIpadNativeNavigation: Bool {
        isPadLayout && usesNativeNavigation
    }

    private var hideSystemNavigationBar: Bool {
        transparentOverlayNavigation || (isIpadNativeNavigation && showsEditorNavigation)
    }

    private var editorTrailingControls: some View {
        Group {
            if isPadLayout {
                SchemeEditorGlassSurface(
                    theme: theme,
                    minWidth: 74,
                    horizontalPadding: 2
                ) {
                    trailingControlItems
                }
            } else {
                SchemeEditorGlassSurface(
                    theme: theme,
                    minWidth: 74,
                    horizontalPadding: 2
                ) {
                    trailingControlItems
                }
            }
        }
    }

    private var trailingControlItems: some View {
        HStack(spacing: isPadLayout ? 0 : 1) {
            SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)
            if !scheme.isDailyQueue {
                SchemeToolbarDivider(theme: theme)
                SchemeArchiveButton(theme: theme) {
                    pendingArchive = .scheme(scheme)
                }
            }
        }
    }

    private func loadDocument(force: Bool) {
        if !force && controller.isDirty { return }
        // A cell edit goes straight to the model and is shown optimistically by
        // the in-place editor, so the full reload only hitches. Skip it while a
        // cell is being edited, unless a structural change needs to retarget.
        if !force && controller.isEditingTableCell && !controller.hasPendingCellFocus { return }
        let shouldPlaceCursorAtEnd = loadedSchemeID != scheme.id
        controller.load(items: scheme.items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: shouldPlaceCursorAtEnd)
        schemeSignature = signature(for: scheme)
        loadedSchemeID = scheme.id
    }

    private func commitDocument() {
        liveFlushWork?.cancel()
        liveFlushWork = nil
        guard !scheme.isReadOnly else {
            controller.isDirty = false
            return
        }
        controller.flushCellEdit()
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

    /// Re-arm the debounce that flushes editor edits into the core while the user
    /// is still typing, so a phone edit propagates within ~1 s (push-on-type) like
    /// desktop, instead of waiting for blur. A burst of keystrokes coalesces into
    /// one flush (the timer only fires once typing pauses).
    private func scheduleLiveFlush() {
        liveFlushWork?.cancel()
        let work = DispatchWorkItem { flushLive() }
        liveFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Flush the editor's pending edits into the core WITHOUT reloading the text
    /// view, so the caret is untouched. `isDirty` stays true so the resulting
    /// snapshot echo is recognised (`selfFlushEcho`) and doesn't reload either.
    /// The model mutation goes through `mutate`, which schedules the debounced sync
    /// push, so the edit rides the socket to other devices.
    private func flushLive() {
        liveFlushWork = nil
        guard !scheme.isReadOnly, controller.isDirty else { return }
        controller.flushCellEdit()
        let edits = controller.commit()
        selfFlushEcho = true
        model.replaceSchemeItems(schemeID: scheme.id, items: edits)
        if let refreshed = model.scheme(id: scheme.id) {
            // Adopt the ids the core minted for lines this flush created — still
            // without a reload — so the next flush updates those items in place
            // instead of re-creating them under fresh ids, and a mid-edit remote
            // merge can match every line by id.
            controller.adoptItemIDs(from: refreshed.items, theme: theme)
            controller.baselineItems = refreshed.items
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

    private func handlePickedImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run { imagePickerItem = nil }
                    return
                }
                let media = try Self.storeImageData(data, contentTypes: item.supportedContentTypes)
                await MainActor.run {
                    controller.attachImageMedia(media, theme: theme)
                    imagePickerItem = nil
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = error.localizedDescription
                    imagePickerItem = nil
                }
            }
        }
    }

    private static func storeImageData(_ rawData: Data, contentTypes: [UTType]) throws -> MobileItemMedia {
        guard let image = UIImage(data: rawData) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let detected = supportedImageFormat(for: contentTypes)
        let payload: Data
        let format: String
        let fileExtension: String
        if let detected {
            payload = rawData
            format = detected.format
            fileExtension = detected.fileExtension
        } else if let jpeg = image.jpegData(compressionQuality: 0.92) {
            payload = jpeg
            format = "jpeg"
            fileExtension = "jpg"
        } else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = try imageAssetsDirectory()
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try payload.write(to: url, options: [.atomic])

        let width = image.cgImage.map { Int32($0.width) } ?? Int32((image.size.width * image.scale).rounded())
        let height = image.cgImage.map { Int32($0.height) } ?? Int32((image.size.height * image.scale).rounded())
        return MobileItemMedia(
            kind: "image",
            path: url.path,
            format: format,
            width: width,
            height: height
        )
    }

    private static func supportedImageFormat(for contentTypes: [UTType]) -> (format: String, fileExtension: String)? {
        if contentTypes.contains(where: { $0.conforms(to: .png) }) {
            return ("png", "png")
        }
        if contentTypes.contains(where: { $0.conforms(to: .jpeg) }) {
            return ("jpeg", "jpg")
        }
        if contentTypes.contains(where: { $0.conforms(to: .gif) }) {
            return ("gif", "gif")
        }
        if contentTypes.contains(where: { $0.conforms(to: .tiff) }) {
            return ("tiff", "tiff")
        }
        if contentTypes.contains(where: { $0.preferredFilenameExtension?.lowercased() == "webp" }) {
            return ("webp", "webp")
        }
        return nil
    }

    private static func imageAssetsDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("KnotQMobile", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func openDateForLine() {
        guard !scheme.isReadOnly else { return }
        // Push pending edits to the model so the date sheet edits a persisted
        // item, but DON'T reload the editor here. A full `commitDocument()`
        // re-applies the attributed string, which in the Daily feed (where each
        // day is a self-sizing, non-scrolling editor) reflows the section and
        // shoves the whole stack — the "button glitches, disappears, reappears
        // lower" symptom. The text view already shows the right content, so a
        // reload buys nothing on this path.
        syncEditsToModel()
        guard let itemID = controller.currentLineItemID(),
              let currentScheme = model.scheme(id: scheme.id),
              currentScheme.items.contains(where: { $0.id == itemID }) else { return }
        dateTarget = EditorDateTarget(itemID: itemID)
    }

    /// Flushes the editor's pending edits into the model without reloading the
    /// text view. Used before opening an item-scoped sheet (date/recurrence) so
    /// the sheet targets a persisted item while avoiding the self-sizing reflow
    /// that `commitDocument()`'s reload triggers in the Daily feed.
    private func syncEditsToModel() {
        guard !scheme.isReadOnly else {
            controller.isDirty = false
            return
        }
        controller.flushCellEdit()
        guard controller.isDirty else { return }
        let edits = controller.commit()
        model.replaceSchemeItems(schemeID: scheme.id, items: edits)
        controller.isDirty = false
        // Adopt the refreshed signature so the model mutation above doesn't
        // bounce back through `.onChange(of: signature(for:))` as a redundant
        // reload (which would reintroduce the reflow we're avoiding).
        if let refreshed = model.scheme(id: scheme.id) {
            controller.adoptItemIDs(from: refreshed.items, theme: theme)
            controller.baselineItems = refreshed.items
            schemeSignature = signature(for: refreshed)
        }
    }

    private func insertTableFromToolbar() {
        guard !scheme.isReadOnly else { return }
        let afterItemID = controller.currentLineItemID()
        // Mint the id up front so the table can render locally *now* (no
        // snapshot round-trip) and the eager `insertTable` command persists it
        // under the same id — making its cells immediately editable. The block
        // also rides the normal document commit, which matches by this id.
        let itemID = UUID().uuidString
        controller.insertTableBlock(itemID: itemID, theme: theme)
        model.insertTable(schemeID: scheme.id, afterItemID: afterItemID, itemID: itemID)
    }

    /// Persists an in-place cell edit. Body cell text may contain newlines; the
    /// core splits those into the cell's line items.
    private func commitTableCell(_ hit: EditorTableCellHit, text: String) {
        guard !scheme.isReadOnly else { return }
        if hit.isHeader {
            model.setTableColumnName(
                schemeID: scheme.id,
                itemID: hit.itemID,
                column: Int32(hit.column),
                name: text
            )
            return
        }
        model.setTableCellText(
            schemeID: scheme.id,
            itemID: hit.itemID,
            row: Int32(hit.row),
            column: Int32(hit.column),
            text: text
        )
    }

    private func signature(for scheme: MobileScheme) -> String {
        scheme.items
            .map {
                let media = $0.media
                    .map { "\($0.kind):\($0.path ?? ""):\($0.format):\($0.width ?? -1)x\($0.height ?? -1)" }
                    .joined(separator: ",")
                let tables = $0.tables
                    .map { table in
                        let columns = table.columns.map(\.name).joined(separator: ",")
                        let rows = table.rows
                            .map { row in row.cells.map(\.text).joined(separator: "\u{1f}") }
                            .joined(separator: "\u{1e}")
                        return "\(columns):\(rows)"
                    }
                    .joined(separator: "\u{1d}")
                let content = $0.content
                    .map { inline -> String in
                        switch inline {
                        case let .text(text):
                            return "text:\(text)"
                        case let .image(media):
                            return "image:\(media.path ?? ""):\(media.format)"
                        case let .table(table):
                            return "table:\(table.columns.map(\.name).joined(separator: ",")):\(table.rows.map { $0.cells.map(\.text).joined(separator: "\u{1f}") }.joined(separator: "\u{1e}"))"
                        }
                    }
                    .joined(separator: "\u{1c}")
                return "\($0.id)|\($0.text)|\($0.marker)|\($0.indent)|\($0.done)|\($0.start ?? "")|\($0.end ?? "")|\(media)|\(tables)|\(content)"
            }
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


private struct SchemeEditorTransparentNavigationBar: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: HostController, context: Context) {
        uiViewController.coordinator = context.coordinator
        context.coordinator.configure(from: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: HostController, coordinator: Coordinator) {
        coordinator.restoreIfNeeded()
    }

    final class HostController: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.configure(from: self)
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.configure(from: self)
            }
        }
    }

    final class Coordinator {
        private weak var navigationBar: UINavigationBar?
        private var standardAppearance: UINavigationBarAppearance?
        private var scrollEdgeAppearance: UINavigationBarAppearance?
        private var compactAppearance: UINavigationBarAppearance?
        private var compactScrollEdgeAppearance: UINavigationBarAppearance?
        private var isTranslucent: Bool?

        @MainActor
        func configure(from controller: UIViewController) {
            guard let navBar = controller.navigationController?.navigationBar else { return }
            if navigationBar !== navBar {
                restoreIfNeeded()
                navigationBar = navBar
                standardAppearance = navBar.standardAppearance
                scrollEdgeAppearance = navBar.scrollEdgeAppearance
                compactAppearance = navBar.compactAppearance
                compactScrollEdgeAppearance = navBar.compactScrollEdgeAppearance
                isTranslucent = navBar.isTranslucent
            }

            let transparent = UINavigationBarAppearance()
            transparent.configureWithTransparentBackground()
            transparent.backgroundColor = .clear
            transparent.backgroundEffect = nil
            transparent.shadowColor = .clear

            navBar.isTranslucent = true
            navBar.standardAppearance = transparent
            navBar.scrollEdgeAppearance = transparent
            navBar.compactAppearance = transparent
            navBar.compactScrollEdgeAppearance = transparent
        }

        @MainActor
        func restoreIfNeeded() {
            guard let navBar = navigationBar else { return }
            if let standardAppearance {
                navBar.standardAppearance = standardAppearance
            }
            navBar.scrollEdgeAppearance = scrollEdgeAppearance
            if let compactAppearance {
                navBar.compactAppearance = compactAppearance
            }
            navBar.compactScrollEdgeAppearance = compactScrollEdgeAppearance
            if let isTranslucent {
                navBar.isTranslucent = isTranslucent
            }
            navigationBar = nil
        }
    }
}

private struct SchemeEditorGlassSurface<Content: View>: View {
    let theme: KnotQTheme
    var minWidth: CGFloat?
    var horizontalPadding: CGFloat
    let content: Content

    init(
        theme: KnotQTheme,
        minWidth: CGFloat? = nil,
        horizontalPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.minWidth = minWidth
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .glassEffect(.regular.tint(glassTint).interactive(), in: shape)
                .overlay {
                    shape.strokeBorder(glassBorder, lineWidth: 0.7)
                }
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .background {
                    shape.fill(padSurface)
                }
                .overlay {
                    shape.strokeBorder(padBorder, lineWidth: 0.7)
                }
        } else {
            content
                .padding(.horizontal, horizontalPadding)
                .frame(height: 38)
                .frame(minWidth: minWidth)
                .background {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(fallbackTint)
                }
                .overlay {
                    shape.strokeBorder(glassBorder, lineWidth: 0.8)
                }
                .shadow(
                    color: .black.opacity(theme.isDark ? 0.24 : 0.08),
                    radius: theme.isDark ? 12 : 5,
                    x: 0,
                    y: theme.isDark ? 5 : 2
                )
        }
    }

    private var glassTint: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.20)
    }

    private var fallbackTint: Color {
        theme.isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.24)
    }

    private var padSurface: Color {
        theme.buttonBg
    }

    private var padBorder: Color {
        theme.isDark ? Color.white.opacity(0.16) : theme.borderOverlay.opacity(0.75)
    }

    private var glassBorder: Color {
        theme.isDark ? Color.white.opacity(0.15) : theme.borderOverlay.opacity(0.72)
    }
}

private struct SchemeTopLipIconButton: ButtonStyle {
    let theme: KnotQTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 38, height: 38)
            // No glass/material fill: a bare, transparent control so the chrome
            // never reads as an opaque lip over the editor. Only a faint press
            // state gives tap feedback.
            .background(
                configuration.isPressed ? theme.rowSelected.opacity(0.5) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct SchemeToolbarDivider: View {
    let theme: KnotQTheme

    var body: some View {
        Rectangle()
            .fill(theme.dividerSoft)
            .frame(width: 1, height: 20)
    }
}

private struct SchemeArchiveButton: View {
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "archivebox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 38, height: 38)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    private var isPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
            Button {
                showingPicker = true
            } label: {
                if isPadLayout {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 18, height: 18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(theme.borderOverlay, lineWidth: 1)
                    }
                    .frame(width: 18, height: 18)
                    .frame(width: 38, height: 38)
                    .contentShape(Capsule(style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 18, height: 18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(theme.borderOverlay, lineWidth: 1)
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(Capsule(style: .continuous))
            }
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
