import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct EditorDateTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
}

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
    // A custom back button commits before changing navigation state, and the
    // resulting disappearance commits again. Keep the epoch of the document
    // submission currently in flight so those two lifecycle hooks cannot enqueue
    // the same whole-document replacement twice. This deliberately is an epoch,
    // rather than a boolean: typing again while a prior write is in flight must
    // still submit the newer document when the pane disappears.
    @State private var commitSubmissionEpoch: UInt64?
    // The scheme signature our own live flush produced, captured from the
    // refreshed snapshot. When `.onChange(of: signature(for:))` fires with
    // exactly this content it is our own edit echoing back — skip the reload
    // that would reset the caret. A genuine remote change carries a different
    // signature, so (unlike a boolean flag) this can never swallow one.
    @State private var selfFlushSignature: String?
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
                        // Read live off the tracker rather than via
                        // `awaitingWriteBeforeInitialLoad`: that is set in
                        // `onAppear`, which runs *after* the text view has been made
                        // and seeded. Later passes can't undo the seeding either
                        // way — `updateUIView` never reloads items.
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
                        // Typing into the blank editor we show while waiting for
                        // the first load would be committed as the WHOLE
                        // document — the load that was going to fill it in has
                        // not happened yet, so the flush sees one line where the
                        // day's real content should be. Hold edits off for the
                        // length of that wait instead.
                        readOnly: scheme.isReadOnly || awaitingWriteBeforeInitialLoad
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
        .onChange(of: signature(for: scheme)) { _, newValue in
            guard newValue != schemeSignature else { return }
            // Still waiting on our own first load — the signature bookkeeping below
            // (and especially the mid-edit merge) assumes a loaded document.
            guard !awaitingWriteBeforeInitialLoad else { return }
            schemeSignature = newValue
            if newValue == selfFlushSignature {
                // Our own live flush echoing back through the snapshot — the editor
                // already shows this content, so don't reload (would reset the caret).
                selfFlushSignature = nil
                return
            }
            selfFlushSignature = nil
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
        schemeSignature = signature(for: scheme)
        loadedSchemeID = scheme.id
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
                schemeSignature = signature(for: refreshed)
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
    /// snapshot echo is recognised (`selfFlushEcho`) and doesn't reload either.
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
            selfFlushSignature = signature(for: refreshed)
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
        // Scheduling is a line operation. An empty document has no current line
        // to target, so create the first blank task and schedule it immediately.
        // This applies to both ordinary schemes and daily queues, which share
        // this editor chrome.
        if model.scheme(id: scheme.id)?.items.isEmpty == true {
            model.addItem(schemeID: scheme.id, text: "") {
                guard let itemID = model.scheme(id: scheme.id)?.items.last?.id else { return }
                dateTarget = EditorDateTarget(itemID: itemID)
            }
            return
        }
        // Push pending edits to the model so the date sheet edits a persisted
        // item, but DON'T reload the editor here. A full `commitDocument()`
        // re-applies the attributed string, which in the Daily feed (where each
        // day is a self-sizing, non-scrolling editor) reflows the section and
        // shoves the whole stack — the "button glitches, disappears, reappears
        // lower" symptom. The text view already shows the right content, so a
        // reload buys nothing on this path.
        // Resolve the target only once that flush has landed. Reading
        // `model.scheme(id:)` straight after the call sees the PRE-write snapshot,
        // so on a line the user just typed (never flushed, hence not in the core's
        // list yet) the `contains` check failed and the date sheet silently
        // refused to open. The completion also runs after `adoptItemIDs`, so
        // `currentLineItemID()` is the core's id rather than a local placeholder.
        syncEditsToModel {
            guard let itemID = controller.currentLineItemID(),
                  let currentScheme = model.scheme(id: scheme.id),
                  currentScheme.items.contains(where: { $0.id == itemID }) else { return }
            dateTarget = EditorDateTarget(itemID: itemID)
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
            // Adopt the refreshed signature so the model mutation above doesn't
            // bounce back through `.onChange(of: signature(for:))` as a redundant
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
            schemeSignature = signature(for: refreshed)
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


/// Makes the hosting `UINavigationController`'s bar fully transparent *and*
/// translucent, which is what lets a pane's content extend up underneath it
/// instead of starting below it. Shared by the scheme editor and the daily feed
/// so the two read as the same screen — a daily that keeps the default opaque
/// bar shows a dead strip across the top and clips its first line against it,
/// where the editor's text flows right up past the back button.
///
/// Restores the bar's original appearance on teardown, so screens that *want*
/// a normal bar (settings, archive) are unaffected.
struct TransparentNavigationBar: UIViewControllerRepresentable {
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
        .accessibilityLabel(L10n.t("sidebar.context.archive"))
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
        .accessibilityLabel(L10n.t("mobile.scheme.color_label"))
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
                .accessibilityLabel(L10n.t("mobile.scheme.color_label"))
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
