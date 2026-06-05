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
    private var pendingImageLocation: Int?

    func load(items: [MobileItem], theme: KnotQTheme, timeFormat: String, placeCursorAtEnd: Bool = false) {
        view?.loadItems(items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: placeCursorAtEnd)
        isDirty = false
        isEmpty = items.isEmpty || items.allSatisfy {
            $0.text.isEmpty
                && $0.marker == "blank"
                && $0.indent == 0
                && $0.start == nil
                && $0.end == nil
                && $0.media.isEmpty
        }
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

    func prepareImageUploadTarget() {
        pendingImageLocation = view?.selectedRange.location
    }

    func attachImageMedia(_ media: MobileItemMedia, theme: KnotQTheme) {
        view?.attachImageMedia(media, at: pendingImageLocation, theme: theme)
        pendingImageLocation = nil
        isEmpty = false
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
    let transparentOverlayNavigation: Bool
    let editorScrollEnabled: Bool
    let editorInsets: UIEdgeInsets

    @StateObject private var controller = EditorController()
    @State private var schemeSignature = ""
    @State private var dateTarget: EditorDateTarget?
    @State private var pendingArchive: ArchiveTarget?
    @State private var loadedSchemeID: String?
    @State private var showingImagePicker = false
    @State private var imagePickerItem: PhotosPickerItem?

    private var accent: Color {
        schemeColor(scheme.colorIndex, dark: theme.isDark)
    }

    private var timeFormat: String {
        model.snapshot?.settings.timeFormat ?? "twelve_hour"
    }

    private var editorTextInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: editorInsets.top + DesktopEditorMetrics.titleBlockHeight + overlayNavigationInset,
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
        self.autoFocusOnAppear = autoFocusOnAppear
        self.autoFocusTitleOnAppear = autoFocusTitleOnAppear
        self.onAutoFocusTitleConsumed = onAutoFocusTitleConsumed
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if showsEditorNavigation && !usesNativeNavigation && !showsOverlayNavigation {
                    editorNavigationBar(showsDivider: true)
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
                        onImageUpload: {
                            controller.prepareImageUploadTarget()
                            showingImagePicker = true
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
        .navigationBarBackButtonHidden(transparentOverlayNavigation)
        .toolbar(transparentOverlayNavigation ? .hidden : .automatic, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .background {
            if usesNativeNavigation && !transparentOverlayNavigation {
                SchemeEditorTransparentNavigationBar()
            }
        }
        .toolbar {
            if usesNativeNavigation && showsEditorNavigation && !transparentOverlayNavigation {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        SchemeColorPickerButton(scheme: scheme, theme: theme, accent: accent)
                        if !scheme.isDailyQueue {
                            SchemeArchiveButton(theme: theme) {
                                pendingArchive = .scheme(scheme)
                            }
                        }
                    }
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
            loadDocument(force: false)
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
                ItemDateSheet(schemeID: scheme.id, item: item)
                    .presentationDetents([.fraction(0.50)])
            }
        }
        .archiveConfirmation(target: $pendingArchive) { _ in
            archiveCurrentScheme()
        }
    }

    private func editorNavigationBar(showsDivider: Bool) -> some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: {
                    commitDocument()
                    onBack()
                }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(SchemeTopLipIconButton(theme: theme))
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
        commitDocument()
        guard let itemID = controller.currentLineItemID(),
              let currentScheme = model.scheme(id: scheme.id),
              currentScheme.items.contains(where: { $0.id == itemID }) else { return }
        dateTarget = EditorDateTarget(itemID: itemID)
    }

    private func signature(for scheme: MobileScheme) -> String {
        scheme.items
            .map {
                let media = $0.media
                    .map { "\($0.kind):\($0.path ?? ""):\($0.format):\($0.width ?? -1)x\($0.height ?? -1)" }
                    .joined(separator: ",")
                return "\($0.id)|\($0.text)|\($0.marker)|\($0.indent)|\($0.done)|\($0.start ?? "")|\($0.end ?? "")|\(media)"
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
