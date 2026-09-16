import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct EditorDateTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
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
    let onEmptyStateChange: (Bool) -> Void

    @StateObject private var controller = EditorController()
    @State private var dateTarget: EditorDateTarget?
    @State private var pendingArchive: ArchiveTarget?
    @State private var loadedSchemeID: String?
    @State private var showingImagePicker = false
    @State private var imagePickerItem: PhotosPickerItem?
    // Debounced live-commit while typing (push-on-type, like desktop).
    @State private var liveFlushWork: DispatchWorkItem?
    // A custom back button commits before changing navigation state, and the
    // resulting disappearance commits again. Keep the epoch of the document
    // submission currently in flight so those two lifecycle hooks cannot enqueue
    // the same whole-document replacement twice. This deliberately is an epoch,
    // rather than a boolean: typing again while a prior write is in flight must
    // still submit the newer document when the pane disappears.
    @State private var commitSubmissionEpoch: UInt64?
    // The item snapshot our own live flush produced. When the refreshed model
    // arrives with exactly these items it is our own echo — skip the reload
    // that would reset the caret. Keeping the value model-native avoids building
    // a full delimiter-heavy string on every SwiftUI body evaluation, and exact
    // Equatable comparison cannot suffer from delimiter collisions.
    @State private var selfFlushItems: [MobileItem]?
    // Set when `onAppear` found a core write for this scheme still in flight, so
    // the initial load was postponed until the post-write snapshot exists.
    @State private var awaitingWriteBeforeInitialLoad = false
    /// When the wait above began, for `CoreTiming.deferredEditorLoad`.
    @State private var deferredLoadStartedAt: CFAbsoluteTime?

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
        onAutoFocusTitleConsumed: @escaping () -> Void = {},
        onEmptyStateChange: @escaping (Bool) -> Void = { _ in }
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
        self.onEmptyStateChange = onEmptyStateChange
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if usesEmbeddedNavigationBar {
                    editorNavigationBar(showsDivider: true)
                }

                ZStack(alignment: .topLeading) {
                    editorTextView

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
                TransparentNavigationBar()
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
            // A commit from the pane instance we are replacing (`onDisappear` →
            // `commitDocument`) or its last live flush may still be on the bridge
            // queue. `scheme` then holds the pre-write text, and loading it would
            // both show the user stale content and install it as the baseline the
            // eventual merge resolves against — which is how the in-flight edit got
            // dropped. Wait for the write instead; the day/scheme renders empty for
            // the length of one core write, then loads the real text.
            if model.hasWriteInFlight(schemeID: scheme.id) {
                awaitingWriteBeforeInitialLoad = true
                deferredLoadStartedAt = CFAbsoluteTimeGetCurrent()
                // The write can land between the body evaluation that armed the
                // observer below and this point, leaving no change for it to
                // see. That used to mean a brief flicker; now that waiting also
                // makes the editor read-only it would mean a permanently blank,
                // uneditable day, so re-check once this runloop turn is over.
                DispatchQueue.main.async {
                    guard awaitingWriteBeforeInitialLoad,
                          !model.hasWriteInFlight(schemeID: scheme.id) else { return }
                    finishDeferredInitialLoad()
                }
            } else {
                loadDocument(force: true)
            }
            if autoFocusTitleOnAppear {
                EditorAutoFocus.schedule(in: controller, target: .title) {
                    controller.focusTitle()
                    onAutoFocusTitleConsumed()
                }
            } else if autoFocusOnAppear {
                EditorAutoFocus.schedule(in: controller) {
                    controller.focus()
                }
            }
        }
        .onChange(of: model.hasWriteInFlight(schemeID: scheme.id)) { _, inFlight in
            guard !inFlight, awaitingWriteBeforeInitialLoad else { return }
            finishDeferredInitialLoad()
        }
        .onChange(of: scheme.items) { _, newItems in
            // Still waiting on our own first load — the snapshot bookkeeping below
            // (and especially the mid-edit merge) assumes a loaded document.
            guard !awaitingWriteBeforeInitialLoad else { return }
            if isSelfFlushEcho(newItems) {
                // Our own live flush echoing back through the snapshot — the editor
                // already shows this content, so don't reload (would reset the caret).
                selfFlushItems = nil
                return
            }
            selfFlushItems = nil
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
                    remote: newItems,
                    baseline: controller.baselineItems,
                    local: localEdits
                )
                controller.reloadPreservingCaret(items: merged, theme: theme, timeFormat: timeFormat)
                if merged != newItems {
                    // The core still holds the plain remote state: keep the
                    // baseline there so a second remote change during the flush
                    // window still sees these lines as locally modified.
                    controller.baselineItems = newItems
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
        .onReceive(controller.editPulse) { _ in scheduleLiveFlush() }
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
            EditorKeyboardHandoff.cancel()
            commitDocument()
        }
        .sheet(item: $dateTarget) { target in
            editorDateSheet(for: target)
        }
        .archiveConfirmation(target: $pendingArchive) { _ in
            archiveCurrentScheme()
        }
    }

    private var editorTextView: some View {
        SchemeTextView(
            controller: controller,
            // Read live off the tracker rather than via
            // `awaitingWriteBeforeInitialLoad`: that is set in `onAppear`, which
            // runs after the text view has been made and seeded.
            items: model.schemeWrites.initialEditorItems(for: scheme),
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
            onEmptyStateChange: onEmptyStateChange,
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
            // Typing into the blank editor we show while waiting for the first
            // load would be committed as the whole document, so hold edits off
            // for the length of that wait instead.
            readOnly: scheme.isReadOnly || awaitingWriteBeforeInitialLoad
        )
    }

    @ViewBuilder
    private func editorDateSheet(for target: EditorDateTarget) -> some View {
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
                        .accessibilityLabel(L10n.t("common.back"))
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
                        .accessibilityLabel(L10n.t("common.back"))
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

    /// The initial load this pane postponed while a core write was in flight.
    private func finishDeferredInitialLoad() {
        // This gap is exactly what the user sees as "every other day appeared
        // instantly, this one took a moment": the day whose write is still in
        // flight renders empty until it lands. It is one core write long, so if
        // it is ever more than a frame or two, the cost is in the write.
        if let since = deferredLoadStartedAt {
            CoreTiming.deferredEditorLoad(seconds: CFAbsoluteTimeGetCurrent() - since)
            deferredLoadStartedAt = nil
        }
        awaitingWriteBeforeInitialLoad = false
        // Force: this pane has never loaded, so there is nothing of the user's to
        // protect.
        loadDocument(force: true)
        // `onAppear`'s auto-focus ran while the editor was still read-only, where
        // it can't take first responder (and wouldn't have built the formatting
        // toolbar). Now that it's editable and loaded, give it the caret — still
        // not before the push has landed, since a slow write can put us here
        // while the screen is mid-transition.
        if autoFocusTitleOnAppear {
            EditorAutoFocus.schedule(in: controller, target: .title) { controller.focusTitle() }
        } else if autoFocusOnAppear {
            EditorAutoFocus.schedule(in: controller) { controller.focus() }
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
        selfFlushItems = nil
        loadedSchemeID = scheme.id
    }

    private func isSelfFlushEcho(_ items: [MobileItem]) -> Bool {
        guard loadedSchemeID == scheme.id else { return false }
        return selfFlushItems == items
    }

    private func commitDocument(completion: (@MainActor () -> Void)? = nil) {
        liveFlushWork?.cancel()
        liveFlushWork = nil
        // Never write back an editor that has not loaded yet: its text view is
        // empty because we are still waiting for a core write, not because the
        // document is. (The `readOnly` gate should keep it clean, but this is
        // the path that would destroy the day, so it checks for itself.)
        guard !awaitingWriteBeforeInitialLoad else {
            completion?()
            return
        }
        guard !scheme.isReadOnly else {
            controller.isDirty = false
            completion?()
            return
        }
        controller.flushCellEdit()
        guard controller.isDirty else {
            completion?()
            return
        }
        let edits = controller.commit()
        let committedEpoch = controller.editEpoch
        let committedSchemeID = scheme.id
        // The pane can disappear synchronously after a custom back/archive
        // button calls us. Its `onDisappear` is not a second user edit, so it
        // must not place an identical replace behind the first one on the serial
        // core queue. Besides wasted save work, that duplicate used to widen the
        // stale-snapshot window that this editor is designed to avoid.
        guard commitSubmissionEpoch != committedEpoch else {
            completion?()
            return
        }
        commitSubmissionEpoch = committedEpoch
        // The refreshed snapshot only exists once the async core write lands;
        // reloading from a synchronous read would re-install the pre-commit list.
        model.replaceSchemeItems(schemeID: scheme.id, items: edits) {
            if commitSubmissionEpoch == committedEpoch {
                commitSubmissionEpoch = nil
            }
            // The reload below replaces the whole text view, so it may only run if
            // the editor is still showing exactly what we committed. If the user
            // typed while the write was in flight, or the pane was reused for
            // another scheme (iPad keeps one editor across schemes), reloading
            // would overwrite newer text with this older snapshot — the "my typing
            // vanished, then came back a moment later" report. Skipping is safe:
            // the edit that bumped the epoch also re-armed the live flush, so the
            // newer text reaches the core on its own.
            guard controller.editEpoch == committedEpoch,
                  loadedSchemeID == committedSchemeID else { return }
            if let refreshed = model.scheme(id: committedSchemeID) {
                controller.load(items: refreshed.items, theme: theme, timeFormat: timeFormat)
                selfFlushItems = refreshed.items
            } else {
                controller.isDirty = false
            }
            completion?()
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
    /// snapshot echo is recognised and doesn't reload either.
    /// The model mutation goes through `mutate`, which schedules the debounced sync
    /// push, so the edit rides the socket to other devices.
    private func flushLive() {
        liveFlushWork = nil
        // See `commitDocument`: an unloaded editor's contents are not the
        // document, so flushing them would replace it.
        guard !awaitingWriteBeforeInitialLoad else { return }
        guard !scheme.isReadOnly, controller.isDirty else { return }
        controller.flushCellEdit()
        let edits = controller.commit()
        // The core write runs async on the bridge queue; the snapshot carrying
        // the ids it minted only exists in `completion`. Reading the model
        // synchronously after the call would see the PRE-flush list — id
        // adoption would silently no-op (line-count mismatch) and every flush
        // would re-create the still-unadopted line under a fresh id.
        model.replaceSchemeItems(schemeID: scheme.id, items: edits) {
            guard let refreshed = model.scheme(id: scheme.id) else { return }
            // Adopt the ids the core minted for lines this flush created — still
            // without a reload — so the next flush updates those items in place
            // instead of re-creating them under fresh ids, and a mid-edit remote
            // merge can match every line by id.
            controller.adoptItemIDs(from: refreshed.items)
            controller.baselineItems = refreshed.items
            selfFlushItems = refreshed.items
        }
    }

    private func archiveCurrentScheme() {
        guard !scheme.isDailyQueue else { return }
        // Archiving is a distinct mutation on the same FIFO bridge queue. Queue
        // it only after the editor replacement has completed, rather than merely
        // after it was submitted. This also makes the navigation disappearance a
        // no-op for the document: the first commit has already cleared its dirty
        // state before the archive changes the visible scheme list.
        commitDocument {
            model.archiveScheme(id: scheme.id)
            if usesNativeNavigation {
                dismiss()
            } else {
                onBack?()
            }
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
        //
        // The flush has to come FIRST, before any "is this document empty?"
        // test. `model.scheme(id:)` returns the PRE-write snapshot, so a scheme
        // whose only line is one the user just typed still reads as empty —
        // and the empty-document branch below would then append a SECOND, blank
        // item and schedule that one, landing the schedule on the line *after*
        // the one the user was on (type "J", tap schedule, the date attaches to
        // the next line). Flushing first makes the typed line a real item, so
        // the ordinary path targets it.
        syncEditsToModel {
            // Resolve the target only once the flush has landed. The completion
            // runs after `adoptItemIDs`, so `currentLineItemID()` is the core's
            // id rather than a local placeholder.
            if let itemID = controller.currentLineItemID(),
               let currentScheme = model.scheme(id: scheme.id),
               currentScheme.items.contains(where: { $0.id == itemID }) {
                dateTarget = EditorDateTarget(itemID: itemID)
                return
            }
            // Scheduling is a line operation and there is genuinely no line to
            // target — an untouched empty document. Create the first blank task
            // and schedule it. This applies to both ordinary schemes and daily
            // queues, which share this editor chrome.
            guard model.scheme(id: scheme.id)?.items.isEmpty == true else { return }
            model.addItem(schemeID: scheme.id, text: "") {
                guard let itemID = model.scheme(id: scheme.id)?.items.last?.id else { return }
                dateTarget = EditorDateTarget(itemID: itemID)
            }
        }
    }

    /// Flushes the editor's pending edits into the model without reloading the
    /// text view. Used before opening an item-scoped sheet (date/recurrence) so
    /// the sheet targets a persisted item while avoiding the self-sizing reflow
    /// that `commitDocument()`'s reload triggers in the Daily feed.
    /// `completion` runs once the model reflects the flush — immediately when
    /// there was nothing to flush, otherwise from the core write's completion.
    /// Callers that need to look the edited item up in the model must use it.
    private func syncEditsToModel(completion: (@MainActor () -> Void)? = nil) {
        guard !scheme.isReadOnly else {
            controller.isDirty = false
            completion?()
            return
        }
        controller.flushCellEdit()
        guard controller.isDirty else {
            completion?()
            return
        }
        let edits = controller.commit()
        let syncedEpoch = controller.editEpoch
        let syncedSchemeID = scheme.id
        model.replaceSchemeItems(schemeID: scheme.id, items: edits) {
            // Adopt the refreshed items so the model mutation above doesn't
            // bounce back through `.onChange(of: scheme.items)` as a redundant
            // reload (which would reintroduce the reflow we're avoiding). Runs in
            // the completion because the snapshot only reflects the replace once
            // the async core write lands.
            guard loadedSchemeID == syncedSchemeID,
                  let refreshed = model.scheme(id: syncedSchemeID) else {
                // The pane moved on to another scheme mid-flight; a caller waiting
                // to act on "the line I was editing" must not fire against it.
                return
            }
            controller.adoptItemIDs(from: refreshed.items)
            controller.baselineItems = refreshed.items
            selfFlushItems = refreshed.items
            // Only NOW is it safe to drop the dirty flag. Clearing it up front
            // (as this used to) opened a window between enqueuing the write and
            // it landing in which any snapshot republish took the
            // `loadDocument(force: false)` branch and rebuilt the text view from
            // the still-PRE-write snapshot — the user's typing vanishing, then
            // reappearing once the write finally landed. It also let the pending
            // live flush bail on `guard controller.isDirty`, stranding keystrokes
            // made in that window. Keystrokes during the flight bump the epoch;
            // leave the flag set for them so their own flush still runs.
            if controller.editEpoch == syncedEpoch {
                controller.isDirty = false
            }
            completion?()
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

    private func titleValidator(_ name: String) -> String? {
        guard !scheme.isDailyQueue else {
            return WorkspaceNameValidation.schemeError(name)
        }
        let root = model.snapshot?.root
        let folderID = WorkspaceNameValidation.parentFolderID(containingSchemeID: scheme.id, root: root)
        return WorkspaceNameValidation.schemeError(name, root: root, folderID: folderID, excludingID: scheme.id)
    }
}
