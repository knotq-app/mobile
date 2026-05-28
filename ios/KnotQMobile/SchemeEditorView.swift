import SwiftUI
import UIKit

// MARK: - Attribute keys

private extension NSAttributedString.Key {
    static let knotqLine = NSAttributedString.Key("knotqLine")
}

// MARK: - Metrics

private enum DesktopEditorMetrics {
    static let textLeftPad: CGFloat = 35
    static let markerSlot: CGFloat = 21
    static let indentWidth: CGFloat = 15
    static let checkboxSize: CGFloat = 14
    static let textFontSize: CGFloat = 16
    static let textLineHeight: CGFloat = 22
    static let headingFontSize: CGFloat = 24
    static let headingLineHeight: CGFloat = 30
    static let annotationFontSize: CGFloat = 11
    static let annotationHeight: CGFloat = 14
    static let annotationBarGap: CGFloat = 8
    static let annotationTextGap: CGFloat = 7
    static let indentGuideXShift: CGFloat = 2
    static let imageTopGap: CGFloat = 8
    static let imageStackGap: CGFloat = 7
    static let imageMaxHeight: CGFloat = 300
    static let imageFallbackWidth: CGFloat = 320
    static let imageFallbackHeight: CGFloat = 180
    static let titleFontSize: CGFloat = 26
    static let titleLineHeight: CGFloat = 34
    static let titleBlockHeight: CGFloat = 44
}

// MARK: - Per-paragraph metadata

@objc final class LineMeta: NSObject {
    let marker: Marker
    let indent: Int
    let done: Bool
    let itemID: String?
    let annotation: String?
    let media: [MobileItemMedia]

    init(marker: Marker = .blank, indent: Int = 0, done: Bool = false, itemID: String? = nil, annotation: String? = nil, media: [MobileItemMedia] = []) {
        self.marker = marker
        self.indent = indent
        self.done = done
        self.itemID = itemID
        self.annotation = annotation
        self.media = media
        super.init()
    }

    convenience init(item: MobileItem, timeFormat: String) {
        self.init(
            marker: Marker(rawValue: item.marker) ?? .blank,
            indent: Int(item.indent),
            done: item.done,
            itemID: item.id.isEmpty ? nil : item.id,
            annotation: LineMeta.annotationText(start: item.start, end: item.end, timeFormat: timeFormat),
            media: item.media
        )
    }

    func with(marker: Marker? = nil, indent: Int? = nil, done: Bool? = nil, itemID: String?? = nil, annotation: String?? = nil, media: [MobileItemMedia]? = nil) -> LineMeta {
        LineMeta(
            marker: marker ?? self.marker,
            indent: indent ?? self.indent,
            done: done ?? self.done,
            itemID: itemID ?? self.itemID,
            annotation: annotation ?? self.annotation,
            media: media ?? self.media
        )
    }

    override func isEqual(_ other: Any?) -> Bool {
        guard let o = other as? LineMeta else { return false }
        return marker == o.marker && indent == o.indent && done == o.done && itemID == o.itemID && annotation == o.annotation && media == o.media
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(marker.rawValue)
        h.combine(indent)
        h.combine(done)
        h.combine(itemID)
        h.combine(annotation)
        h.combine(media)
        return h.finalize()
    }

    static func annotationText(start: String?, end: String?, timeFormat: String) -> String? {
        let s = MobileDate.formatTime(start, timeFormat: timeFormat)
        let e = MobileDate.formatTime(end, timeFormat: timeFormat)
        switch (s, e) {
        case let (.some(s), .some(e)): return "\(s) → \(e)"
        case let (.some(s), .none): return "At \(s)"
        case let (.none, .some(e)): return "Due \(e)"
        default: return nil
        }
    }
}

// MARK: - Attribute composition

private enum EditorAttributes {
    static func paragraphStyle(meta: LineMeta) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth
        let markerOffset = meta.marker == .blank ? CGFloat(0) : DesktopEditorMetrics.markerSlot
        style.firstLineHeadIndent = indent + markerOffset
        style.headIndent = indent
        style.minimumLineHeight = DesktopEditorMetrics.textLineHeight
        style.paragraphSpacing = 0
        return style
    }

    static func bodyAttributes(meta: LineMeta, theme: KnotQTheme) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize),
            .foregroundColor: UIColor(theme.textPrimary),
            .paragraphStyle: paragraphStyle(meta: meta),
            .knotqLine: meta
        ]
        if meta.done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = UIColor(theme.textMuted)
        }
        return attrs
    }
}

private func buildAttributedString(items: [MobileItem], theme: KnotQTheme, timeFormat: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    if items.isEmpty {
        return result
    }
    for item in items {
        let meta = LineMeta(item: item, timeFormat: timeFormat)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        result.append(NSAttributedString(string: item.text, attributes: attrs))
        result.append(NSAttributedString(string: "\n", attributes: attrs))
    }
    return result
}

private func extractEdits(from storage: NSAttributedString) -> [MobileItemEdit] {
    let ns = storage.string as NSString
    var edits: [MobileItemEdit] = []
    var paraStart = 0
    while true {
        let rest = NSRange(location: paraStart, length: ns.length - paraStart)
        let nlRange = ns.range(of: "\n", options: [], range: rest)
        let lineEnd = nlRange.location == NSNotFound ? ns.length : nlRange.location
        let lineRange = NSRange(location: paraStart, length: lineEnd - paraStart)
        let meta = metaForLine(storage: storage, lineRange: lineRange)
        let body = lineRange.length > 0 ? editorVisibleString(ns.substring(with: lineRange)) : ""
        edits.append(MobileItemEdit(
            id: meta.itemID,
            text: body,
            marker: meta.marker.rawValue,
            indent: Int32(meta.indent),
            done: meta.done
        ))
        if nlRange.location == NSNotFound { break }
        paraStart = nlRange.location + 1
        if paraStart >= ns.length { break }
    }
    if ns.length == 0 {
        return []
    }
    return edits
}

private func metaForLine(storage: NSAttributedString, lineRange: NSRange) -> LineMeta {
    if lineRange.location < storage.length, let m = storage.attribute(.knotqLine, at: lineRange.location, effectiveRange: nil) as? LineMeta {
        return m
    }
    if lineRange.location > 0, let m = storage.attribute(.knotqLine, at: lineRange.location - 1, effectiveRange: nil) as? LineMeta {
        return m
    }
    return LineMeta()
}

private func isMarkdownHeading(_ line: String) -> Bool {
    let trimmed = editorVisibleString(line).trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "#" else { return false }
    let hashes = trimmed.prefix { $0 == "#" }.count
    guard hashes > 0 else { return false }
    if trimmed.count == hashes { return true }
    let index = trimmed.index(trimmed.startIndex, offsetBy: hashes)
    return trimmed[index].isWhitespace
}

private func editorVisibleString(_ raw: String) -> String {
    raw
}

private struct EditorParagraphRange {
    let lineRange: NSRange
    let fullRange: NSRange
}

private func paragraphRanges(in ns: NSString, intersecting target: NSRange? = nil) -> [EditorParagraphRange] {
    guard ns.length > 0 else { return [] }
    var ranges: [EditorParagraphRange] = []
    var start = 0

    while start < ns.length {
        var end = start
        while end < ns.length && ns.character(at: end) != 10 {
            end += 1
        }

        let hasNewline = end < ns.length
        let lineRange = NSRange(location: start, length: end - start)
        let fullRange = NSRange(location: start, length: end - start + (hasNewline ? 1 : 0))
        if target.map({ rangesOverlapOrTouch(fullRange, $0) }) ?? true {
            ranges.append(EditorParagraphRange(lineRange: lineRange, fullRange: fullRange))
        }

        guard hasNewline else { break }
        start = end + 1
    }

    return ranges
}

private func lineRange(from paragraphRange: NSRange, in ns: NSString) -> NSRange {
    var length = paragraphRange.length
    if length > 0 && ns.character(at: NSMaxRange(paragraphRange) - 1) == 10 {
        length -= 1
    }
    return NSRange(location: paragraphRange.location, length: length)
}

private func rangesOverlapOrTouch(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location <= NSMaxRange(b) && b.location <= NSMaxRange(a)
}

private extension NSAttributedString {
    func metaAt(_ location: Int) -> LineMeta? {
        guard location < length, location >= 0 else { return nil }
        return attribute(.knotqLine, at: location, effectiveRange: nil) as? LineMeta
    }
}

// MARK: - Outer SwiftUI views

struct SchemeEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    let schemeID: String

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        if let scheme = model.scheme(id: schemeID) {
            IntegratedSchemeEditorPane(scheme: scheme, theme: theme, onBack: nil, onAdd: {}, usesNativeNavigation: true)
        } else {
            EmptyState(title: "Scheme missing", detail: "It may have been deleted.", theme: theme)
        }
    }
}

private struct EditorDateTarget: Identifiable {
    let itemID: String
    var id: String { itemID }
}

@MainActor
final class EditorController: ObservableObject {
    fileprivate weak var view: EditorTextView?
    @Published var isDirty = false
    @Published var isEmpty = true

    func load(items: [MobileItem], theme: KnotQTheme, timeFormat: String) {
        view?.loadItems(items, theme: theme, timeFormat: timeFormat)
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
}

struct IntegratedSchemeEditorPane: View {
    @EnvironmentObject private var model: AppModel
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

    init(
        scheme: MobileScheme,
        theme: KnotQTheme,
        onBack: (() -> Void)?,
        onAdd: @escaping () -> Void,
        usesNativeNavigation: Bool = false,
        showsEditorNavigation: Bool = true,
        editorScrollEnabled: Bool = true,
        editorInsets: UIEdgeInsets = UIEdgeInsets(top: 6, left: DesktopEditorMetrics.textLeftPad, bottom: 180, right: 24)
    ) {
        self.scheme = scheme
        self.theme = theme
        self.onBack = onBack
        self.onAdd = onAdd
        self.usesNativeNavigation = usesNativeNavigation
        self.showsEditorNavigation = showsEditorNavigation
        self.editorScrollEnabled = editorScrollEnabled
        self.editorInsets = editorInsets
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
                    titleValidator: titleValidator,
                    onRenameTitle: { title in
                        model.renameScheme(id: scheme.id, name: title)
                    },
                    onDate: openDateForLine
                )

                if controller.isEmpty {
                    Text("Start typing")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textMuted)
                        .padding(.top, editorTextInsets.top + 4)
                        .padding(.leading, editorTextInsets.left + 2)
                        .allowsHitTesting(false)
                }

            }
            .clipped()
        }
        .background(theme.bgApp)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesNativeNavigation && showsEditorNavigation {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.appendTaskLine(theme: theme)
                    } label: {
                        Image(systemName: "plus")
                    }

                    Menu {
                        ColorMenu(nodeID: scheme.id, colorIndex: scheme.colorIndex, theme: theme)
                        Button("Save", systemImage: "checkmark") { commitDocument() }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteScheme(id: scheme.id) }
                            .disabled(scheme.isDailyQueue)
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent)
                            .frame(width: 18, height: 18)
                    }
                }
            }
        }
        .onAppear { loadDocument(force: true) }
        .onChange(of: signature(for: scheme)) { _, newValue in
            guard newValue != schemeSignature else { return }
            loadDocument(force: false)
        }
        .onChange(of: timeFormat) { _, _ in loadDocument(force: true) }
        .onDisappear { commitDocument() }
        .sheet(item: $dateTarget) { target in
            if let item = model.scheme(id: scheme.id)?.items.first(where: { $0.id == target.itemID }) {
                ItemDateSheet(schemeID: scheme.id, item: item)
                    .presentationDetents([.medium])
            }
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

            Button {
                controller.appendTaskLine(theme: theme)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(TitleIconButton(theme: theme))

            Menu {
                ColorMenu(nodeID: scheme.id, colorIndex: scheme.colorIndex, theme: theme)
                Button("Commit Edits", systemImage: "checkmark") { commitDocument() }
                Button("Delete", role: .destructive) { model.deleteScheme(id: scheme.id) }
                    .disabled(scheme.isDailyQueue)
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(TitleIconButton(theme: theme))
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }

    private func loadDocument(force: Bool) {
        if !force && controller.isDirty { return }
        controller.load(items: scheme.items, theme: theme, timeFormat: timeFormat)
        schemeSignature = signature(for: scheme)
    }

    private func commitDocument() {
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

    private func openDateForLine() {
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

struct ItemRow: View {
    @EnvironmentObject private var model: AppModel
    let schemeID: String
    let item: MobileItem
    @State private var draft: String
    @State private var showingDate = false

    init(schemeID: String, item: MobileItem) {
        self.schemeID = schemeID
        self.item = item
        _draft = State(initialValue: item.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if item.marker == "checkbox" {
                    model.toggleItem(schemeID: schemeID, itemID: item.id)
                } else {
                    model.setItemMarker(schemeID: schemeID, itemID: item.id, marker: .checkbox)
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : markerIcon(item.marker))
                    .foregroundStyle(item.done ? .green : .secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(item.indent) * 18)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Item", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .strikethrough(item.done)
                    .onSubmit { commitText() }
                    .onDisappear { commitText() }
                    .onChange(of: item.text) { _, value in
                        if draft != value { draft = value }
                    }

                HStack(spacing: 10) {
                    Menu {
                        ForEach(Marker.allCases) { marker in
                            Button {
                                model.setItemMarker(schemeID: schemeID, itemID: item.id, marker: marker)
                            } label: {
                                Label(marker.label, systemImage: marker.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "text.badge.checkmark")
                    }

                    Button {
                        model.setItemIndent(schemeID: schemeID, itemID: item.id, indent: item.indent > 0 ? item.indent - 1 : 0)
                    } label: {
                        Image(systemName: "decrease.indent")
                    }
                    .disabled(item.indent == 0)

                    Button {
                        model.setItemIndent(schemeID: schemeID, itemID: item.id, indent: min(item.indent + 1, 8))
                    } label: {
                        Image(systemName: "increase.indent")
                    }

                    Button {
                        showingDate = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }

                    Text(item.kind.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .sheet(isPresented: $showingDate) {
            ItemDateSheet(schemeID: schemeID, item: item)
        }
    }

    private func commitText() {
        if draft != item.text {
            model.updateItemText(schemeID: schemeID, itemID: item.id, text: draft)
        }
    }

    private func markerIcon(_ marker: String) -> String {
        switch marker {
        case "checkbox": "circle"
        case "bullet": "smallcircle.filled.circle"
        case "numbered": "list.number"
        default: "text.alignleft"
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
    let titleValidator: (String) -> String?
    let onRenameTitle: (String) -> Void
    let onDate: () -> Void

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
        view.isScrollEnabled = isScrollEnabled
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.autocapitalizationType = .sentences
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.inputAccessoryView = coordinator.makeToolbar(for: view)
        view.configureTitle(title: schemeTitle, theme: theme, validator: titleValidator, onCommit: onRenameTitle)
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
        uiView.theme = theme
        uiView.accentColor = UIColor(accent)
        uiView.backgroundColor = UIColor(theme.bgApp)
        uiView.textContainerInset = textInsets
        uiView.isScrollEnabled = isScrollEnabled
        uiView.configureTitle(title: schemeTitle, theme: theme, validator: titleValidator, onCommit: onRenameTitle)
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

    private var suppressDelegateDepth = 0
    private var autoBulletizePending = false

    func suppress(_ block: () -> Void) {
        suppressDelegateDepth += 1
        defer { suppressDelegateDepth -= 1 }
        block()
    }

    func markDirty() {
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
        if let view = textView as? EditorTextView {
            view.enforceTerminalNewlineAfterUserEdit()
        }
        markDirty()
        refreshEmpty()
    }

    @objc func handleEditorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view else { return }
        _ = view.toggleCheckboxAt(point: recognizer.location(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        return view.checkboxLineRange(at: touch.location(in: view)) != nil
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let view = textView as? EditorTextView else { return true }
        if text == "\n" && range.length == 0 {
            return !handleEnter(in: view, at: range.location)
        }
        return true
    }

    private func handleEnter(in view: EditorTextView, at cursor: Int) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        if cursor == ns.length, ns.length > 0, ns.character(at: ns.length - 1) == 10 {
            let baseMeta = storage.metaAt(ns.length - 1) ?? LineMeta()
            let newMeta = continuationMeta(baseMeta)
            let attrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
            suppress {
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: cursor, length: 0), with: NSAttributedString(string: "\n", attributes: attrs))
                storage.endEditing()
            }
            view.selectedRange = NSRange(location: cursor, length: 0)
            view.typingAttributes = attrs
            markDirty()
            refreshEmpty()
            return true
        }
        let probe = min(cursor, max(0, ns.length - 1))
        let paraRange = ns.length > 0 ? ns.paragraphRange(for: NSRange(location: probe, length: 0)) : NSRange(location: 0, length: 0)
        let currentLineRange = lineRange(from: paraRange, in: ns)
        let body = currentLineRange.length > 0 ? ns.substring(with: currentLineRange) : ""
        let meta = metaForLine(storage: storage, lineRange: currentLineRange)

        // Empty marker line → exit list (clear marker, no newline insertion).
        if editorVisibleString(body).isEmpty && meta.marker != .blank {
            let cleared = LineMeta(marker: .blank, indent: meta.indent, done: false, itemID: meta.itemID, annotation: meta.annotation, media: meta.media)
            let attrs = EditorAttributes.bodyAttributes(meta: cleared, theme: theme)
            suppress {
                storage.beginEditing()
                if paraRange.length > 0 {
                    for (key, value) in attrs {
                        storage.addAttribute(key, value: value, range: paraRange)
                    }
                }
                storage.endEditing()
            }
            view.typingAttributes = attrs
            markDirty()
            return true
        }

        // Continue marker / inherit indent on new paragraph.
        let newMeta = continuationMeta(meta)
        let oldAttrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        let newAttrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: cursor, length: 0), with: NSAttributedString(string: "\n", attributes: oldAttrs))
            // Make sure the old paragraph keeps its meta + style.
            let oldLen = cursor - currentLineRange.location + 1
            if oldLen > 0 {
                for (key, value) in oldAttrs {
                    storage.addAttribute(key, value: value, range: NSRange(location: paraRange.location, length: oldLen))
                }
            }
            let nsAfter = storage.string as NSString
            if cursor + 1 < nsAfter.length {
                let newParaRange = nsAfter.paragraphRange(for: NSRange(location: cursor + 1, length: 0))
                if newParaRange.length > 0 {
                    for (key, value) in newAttrs {
                        storage.addAttribute(key, value: value, range: newParaRange)
                    }
                }
            }
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: cursor + 1, length: 0)
        view.typingAttributes = newAttrs
        markDirty()
        refreshEmpty()
        return true
    }

    private func continuationMeta(_ meta: LineMeta) -> LineMeta {
        switch meta.marker {
        case .blank, .bullet, .numbered:
            return LineMeta(marker: meta.marker, indent: meta.indent, done: false, itemID: nil, annotation: nil)
        case .checkbox:
            return LineMeta(marker: .checkbox, indent: meta.indent, done: false, itemID: nil, annotation: nil)
        }
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard suppressDelegateDepth == 0 else { return }
        if actions.contains(.editedCharacters) {
            ensureMetaConsistency(in: storage, around: editedRange)
            applyStylingForEditedParagraphs(in: storage, around: editedRange)
            if !autoBulletizePending {
                autoBulletizePending = true
                let editLocation = editedRange.location
                DispatchQueue.main.async { [weak self] in
                    self?.autoBulletizePending = false
                    self?.maybeAutoBulletize(at: editLocation)
                }
            }
        }
    }

    private func ensureMetaConsistency(in storage: NSTextStorage, around editedRange: NSRange) {
        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: editedRange)
        suppress {
            storage.beginEditing()
            for paragraph in paragraphRanges(in: ns, intersecting: paraRange) {
                let meta = self.inheritedMeta(in: storage, ns: ns, lineRange: paragraph.lineRange)
                let fullRange = paragraph.fullRange
                guard fullRange.length > 0 else { continue }
                storage.addAttribute(.knotqLine, value: meta, range: fullRange)
            }
            storage.endEditing()
        }
    }

    private func inheritedMeta(in storage: NSTextStorage, ns: NSString, lineRange: NSRange) -> LineMeta {
        if lineRange.location < storage.length, let m = storage.attribute(.knotqLine, at: lineRange.location, effectiveRange: nil) as? LineMeta {
            if lineRange.location > 0,
               ns.character(at: lineRange.location - 1) == 10,
               let previous = storage.attribute(.knotqLine, at: lineRange.location - 1, effectiveRange: nil) as? LineMeta,
               m.itemID == previous.itemID,
               m.annotation == previous.annotation {
                return LineMeta(marker: previous.marker, indent: previous.indent, done: false, itemID: nil, annotation: nil)
            }
            return m
        }
        if lineRange.location > 0, let m = storage.attribute(.knotqLine, at: lineRange.location - 1, effectiveRange: nil) as? LineMeta {
            // Inherit marker/indent only; a brand-new paragraph is a fresh item.
            return LineMeta(marker: m.marker, indent: m.indent, done: false, itemID: nil, annotation: nil)
        }
        return LineMeta()
    }

    private func fullParagraphRange(lineRange: NSRange, in ns: NSString) -> NSRange {
        let end = lineRange.location + lineRange.length
        let includesTrailingNewline = end < ns.length && ns.character(at: end) == 10
        return NSRange(location: lineRange.location, length: lineRange.length + (includesTrailingNewline ? 1 : 0))
    }

    private func applyStylingForEditedParagraphs(in storage: NSTextStorage, around editedRange: NSRange) {
        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: editedRange)
        suppress {
            storage.beginEditing()
            for paragraph in paragraphRanges(in: ns, intersecting: paraRange) {
                let lineRange = paragraph.lineRange
                let meta = metaForLine(storage: storage, lineRange: lineRange)
                let fullRange = paragraph.fullRange
                guard fullRange.length > 0 else { continue }
                let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: self.theme)
                storage.removeAttribute(.font, range: fullRange)
                storage.removeAttribute(.foregroundColor, range: fullRange)
                storage.removeAttribute(.paragraphStyle, range: fullRange)
                storage.removeAttribute(.strikethroughStyle, range: fullRange)
                storage.removeAttribute(.strikethroughColor, range: fullRange)
                for (key, value) in attrs {
                    storage.addAttribute(key, value: value, range: fullRange)
                }
                let body = lineRange.length > 0 ? ns.substring(with: lineRange) : ""
                if isMarkdownHeading(body) {
                    storage.addAttribute(.font, value: UIFont.systemFont(ofSize: DesktopEditorMetrics.headingFontSize, weight: .bold), range: lineRange)
                } else {
                    self.applyEmphasis(body: body, lineLocation: lineRange.location, storage: storage)
                }
            }
            storage.endEditing()
        }
    }

    private func applyEmphasis(body: String, lineLocation: Int, storage: NSTextStorage) {
        let ns = body as NSString
        var i = 0
        while i < ns.length {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch != "*" && ch != "_" { i += 1; continue }
            let searchRange = NSRange(location: i + 1, length: ns.length - i - 1)
            let close = ns.range(of: ch, options: [], range: searchRange)
            if close.location == NSNotFound { i += 1; continue }
            if close.location > i + 1 {
                let range = NSRange(location: lineLocation + i + 1, length: close.location - i - 1)
                let font: UIFont = ch == "*" ? .systemFont(ofSize: DesktopEditorMetrics.textFontSize, weight: .bold) : .italicSystemFont(ofSize: DesktopEditorMetrics.textFontSize)
                storage.addAttribute(.font, value: font, range: range)
            }
            i = close.location + 1
        }
    }

    private func maybeAutoBulletize(at editLocation: Int) {
        guard let view else { return }
        let storage = view.textStorage
        let ns = storage.string as NSString
        guard editLocation <= ns.length else { return }
        let paraRange = ns.paragraphRange(for: NSRange(location: min(editLocation, max(0, ns.length - 1)), length: 0))
        var bodyEnd = paraRange.location + paraRange.length
        if bodyEnd > paraRange.location, bodyEnd <= ns.length, ns.character(at: bodyEnd - 1) == 10 { bodyEnd -= 1 }
        let bodyLen = bodyEnd - paraRange.location
        guard bodyLen > 0 else { return }
        let body = ns.substring(with: NSRange(location: paraRange.location, length: bodyLen))
        let visibleBody = editorVisibleString(body)
        guard let meta = storage.attribute(.knotqLine, at: paraRange.location, effectiveRange: nil) as? LineMeta, meta.marker == .blank else { return }

        var newMarker: Marker?
        var stripLen = 0
        if visibleBody == "- " || visibleBody == "* " {
            newMarker = .bullet
            stripLen = (body as NSString).length
        } else if visibleBody.range(of: #"^\d+\.\s$"#, options: .regularExpression) != nil {
            newMarker = .numbered
            stripLen = (body as NSString).length
        }
        guard let newMarker else { return }

        let newMeta = meta.with(marker: newMarker, done: false)
        let attrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: paraRange.location, length: stripLen), with: "")
            let nsAfter = storage.string as NSString
            let updatedParaRange = nsAfter.paragraphRange(for: NSRange(location: paraRange.location, length: 0))
            if updatedParaRange.length > 0 {
                for (key, value) in attrs {
                    storage.addAttribute(key, value: value, range: updatedParaRange)
                }
            }
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: paraRange.location, length: 0)
        view.typingAttributes = attrs
        markDirty()
    }

    // MARK: Toolbar

    func makeToolbar(for textView: UITextView) -> UIView {
        let width = UIScreen.main.bounds.width
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: width, height: 38), inputViewStyle: .keyboard)
        container.autoresizingMask = [.flexibleWidth]
        container.allowsSelfSizing = true

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        container.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(stack)

        [
            toolbarButton("text.alignleft") { [weak self] in self?.view?.setCurrentMarker(.blank, theme: self?.theme ?? .dark) },
            toolbarButton("checkmark.square") { [weak self] in self?.view?.setCurrentMarker(.checkbox, theme: self?.theme ?? .dark) },
            toolbarButton("list.bullet") { [weak self] in self?.view?.setCurrentMarker(.bullet, theme: self?.theme ?? .dark) },
            toolbarButton("list.number") { [weak self] in self?.view?.setCurrentMarker(.numbered, theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("decrease.indent", prominent: true) { [weak self] in self?.view?.shiftCurrentIndent(-1, theme: self?.theme ?? .dark) },
            toolbarButton("increase.indent", prominent: true) { [weak self] in self?.view?.shiftCurrentIndent(1, theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("calendar.badge.clock") { [weak self] in self?.onDateRequested?() },
            toolbarButton("plus") { [weak self] in self?.view?.appendTaskLine(theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("keyboard.chevron.compact.down") { [weak textView] in textView?.resignFirstResponder() }
        ].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        return container
    }

    private func toolbarButton(_ systemName: String, prominent: Bool = false, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold), forImageIn: .normal)
        button.tintColor = UIColor(prominent ? theme.textPrimary : theme.textDim)
        button.backgroundColor = prominent ? UIColor(theme.buttonBg) : .clear
        button.layer.cornerRadius = 5
        button.widthAnchor.constraint(equalToConstant: prominent ? 31 : 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: 27).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(theme.dividerSoft)
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
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

    func configure(title: String, theme: KnotQTheme, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        self.validator = validator
        self.onCommit = onCommit
        textField.textColor = UIColor(theme.textPrimary)
        normalTintColor = UIColor(theme.accent)
        errorTintColor = UIColor(theme.danger)
        errorLabel.textColor = errorTintColor
        if !textField.isFirstResponder {
            committedTitle = title
            textField.text = title
        }
        updateError()
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

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineTitleView()
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let maxHeight = DesktopEditorMetrics.textLineHeight
        if rect.height > maxHeight {
            rect.size.height = maxHeight
        }
        return rect
    }

    func configureTitle(title: String, theme: KnotQTheme, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        inlineTitleView.configure(title: title, theme: theme, validator: validator, onCommit: onCommit)
        setNeedsLayout()
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

    func loadItems(_ items: [MobileItem], theme: KnotQTheme, timeFormat: String) {
        let savedSelection = selectedRange
        self.theme = theme
        coordinator?.suppress {
            let attributed = buildAttributedString(items: items, theme: theme, timeFormat: timeFormat)
            textStorage.setAttributedString(attributed)
        }
        let length = textStorage.length
        selectedRange = NSRange(location: min(savedSelection.location, length), length: 0)
        if length > 0 {
            let probe = min(savedSelection.location, length - 1)
            let meta = textStorage.metaAt(probe) ?? LineMeta()
            typingAttributes = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        } else {
            typingAttributes = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        }
        layoutManager.ensureLayout(for: textContainer)
        setNeedsDisplay()
        coordinator?.markClean()
    }

    func extractItemEdits() -> [MobileItemEdit] {
        ensureTerminalNewline()
        return extractEdits(from: textStorage)
    }

    func isEffectivelyEmpty() -> Bool {
        let ns = textStorage.string as NSString
        guard ns.length > 0 else { return true }
        return paragraphRanges(in: ns).allSatisfy { paragraph in
            let body = paragraph.lineRange.length > 0 ? editorVisibleString(ns.substring(with: paragraph.lineRange)) : ""
            let meta = metaForLine(storage: textStorage, lineRange: paragraph.lineRange)
            return body.isEmpty && meta.marker == .blank && meta.indent == 0 && meta.annotation == nil
        }
    }

    func appendTaskLine(theme: KnotQTheme) {
        let storage = textStorage
        let location = storage.length
        let meta = LineMeta(marker: .checkbox)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        var lineStart = location
        coordinator?.suppress {
            storage.beginEditing()
            self.ensureTerminalNewline()
            lineStart = storage.length
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: NSAttributedString(string: "\n", attributes: attrs))
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
        let ns = textStorage.string as NSString
        let loc = min(selectedRange.location, max(0, ns.length - 1))
        guard ns.length > 0, loc < ns.length else { return nil }
        return textStorage.metaAt(loc)?.itemID
    }

    func setCurrentMarker(_ marker: Marker, theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let loc = min(selectedRange.location, ns.length)
        let paraRange = editableParagraphRange(in: ns, at: loc)
        let oldMeta = metaForLine(storage: textStorage, lineRange: lineRange(from: paraRange, in: ns))
        let newDone = (marker == .checkbox && oldMeta.marker == .checkbox) ? !oldMeta.done : false
        let newMeta = LineMeta(marker: marker, indent: oldMeta.indent, done: newDone, itemID: oldMeta.itemID, annotation: oldMeta.annotation, media: oldMeta.media)
        applyMetaToCurrentParagraph(newMeta, paragraphRange: paraRange, theme: theme)
    }

    func shiftCurrentIndent(_ delta: Int, theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let loc = min(selectedRange.location, ns.length)
        let paraRange = editableParagraphRange(in: ns, at: loc)
        let oldMeta = metaForLine(storage: textStorage, lineRange: lineRange(from: paraRange, in: ns))
        let newMeta = oldMeta.with(indent: max(0, min(8, oldMeta.indent + delta)))
        applyMetaToCurrentParagraph(newMeta, paragraphRange: paraRange, theme: theme)
    }

    private func applyMetaToCurrentParagraph(_ meta: LineMeta, paragraphRange: NSRange, theme: KnotQTheme) {
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        coordinator?.suppress {
            textStorage.beginEditing()
            if paragraphRange.length > 0 {
                self.clearBaseAttributes(in: paragraphRange)
                for (key, value) in attrs {
                    textStorage.addAttribute(key, value: value, range: paragraphRange)
                }
            }
            textStorage.endEditing()
        }
        typingAttributes = attrs
        coordinator?.markDirty()
        setNeedsDisplay()
    }

    private func clearBaseAttributes(in range: NSRange) {
        textStorage.removeAttribute(.font, range: range)
        textStorage.removeAttribute(.foregroundColor, range: range)
        textStorage.removeAttribute(.paragraphStyle, range: range)
        textStorage.removeAttribute(.strikethroughStyle, range: range)
        textStorage.removeAttribute(.strikethroughColor, range: range)
    }

    func enforceTerminalNewlineAfterUserEdit() {
        let savedSelection = selectedRange
        var appended = false
        coordinator?.suppress {
            textStorage.beginEditing()
            appended = self.ensureTerminalNewline()
            textStorage.endEditing()
        }
        if appended {
            selectedRange = NSRange(
                location: min(savedSelection.location, textStorage.length),
                length: min(savedSelection.length, max(0, textStorage.length - savedSelection.location))
            )
        }
    }

    @discardableResult
    private func ensureTerminalNewline() -> Bool {
        let ns = textStorage.string as NSString
        guard ns.length > 0, ns.character(at: ns.length - 1) != 10 else { return false }
        let paragraph = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
        let meta = metaForLine(storage: textStorage, lineRange: lineRange(from: paragraph, in: ns))
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        textStorage.replaceCharacters(in: NSRange(location: textStorage.length, length: 0), with: NSAttributedString(string: "\n", attributes: attrs))
        return true
    }

    private func editableParagraphRange(in ns: NSString, at location: Int) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let probe = min(max(0, location), ns.length - 1)
        return ns.paragraphRange(for: NSRange(location: probe, length: 0))
    }

    @discardableResult
    fileprivate func toggleCheckboxAt(point: CGPoint) -> Bool {
        let ns = textStorage.string as NSString
        guard let lineRange = checkboxLineRange(at: point) else { return false }
        let paraRange = ns.paragraphRange(for: lineRange)
        let oldMeta = textStorage.metaAt(paraRange.location) ?? LineMeta()
        let newMeta = oldMeta.with(done: !oldMeta.done)
        applyMetaToCurrentParagraph(newMeta, paragraphRange: paraRange, theme: theme)
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
        var numberedOrdinal = 1
        let paragraphs = paragraphRanges(in: ns)
        for index in paragraphs.indices {
            let paragraph = paragraphs[index]
            guard let geometry = paragraphGeometry(for: paragraph, origin: origin) else { continue }
            let glyphRange = geometry.glyphRange
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { continue }
            let firstFragment = geometry.fragments[0]
            let visualBounds = geometry.bounds
            let meta = metaForLine(storage: storage, lineRange: paragraph.lineRange)
            let previousMeta = index > 0 ? metaForLine(storage: storage, lineRange: paragraphs[index - 1].lineRange) : nil
            let nextMeta = index + 1 < paragraphs.count ? metaForLine(storage: storage, lineRange: paragraphs[index + 1].lineRange) : nil
            let previousAnnotated = index > 0 && metaForLine(storage: storage, lineRange: paragraphs[index - 1].lineRange).annotation != nil
            let nextAnnotated = index + 1 < paragraphs.count && metaForLine(storage: storage, lineRange: paragraphs[index + 1].lineRange).annotation != nil
            let mediaExtraHeight = mediaStackHeight(meta.media, maxWidth: editorImageMaxWidth(textLeft: firstFragment.minX))
            let rowExtraHeight = (meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight) + mediaExtraHeight
            if meta.marker == .numbered {
                self.drawIndentGuides(meta: meta, previousMeta: previousMeta, nextMeta: nextMeta, firstFragment: firstFragment, visualBounds: visualBounds, rowExtraHeight: rowExtraHeight, context: context)
                self.drawMarker(meta: meta, ordinal: numberedOrdinal, fragment: firstFragment, context: context)
                numberedOrdinal += 1
            } else {
                numberedOrdinal = 1
                self.drawIndentGuides(meta: meta, previousMeta: previousMeta, nextMeta: nextMeta, firstFragment: firstFragment, visualBounds: visualBounds, rowExtraHeight: rowExtraHeight, context: context)
                self.drawMarker(meta: meta, ordinal: 1, fragment: firstFragment, context: context)
            }
            if let annotation = meta.annotation {
                self.drawAnnotationBar(meta: meta, firstFragment: firstFragment, visualBounds: visualBounds, rowExtraHeight: rowExtraHeight, connectsToPrevious: previousAnnotated, connectsToNext: nextAnnotated, context: context)
                self.drawAnnotation(annotation, meta: meta, visualBounds: visualBounds, context: context)
            }
            if !meta.media.isEmpty {
                self.drawMediaStack(meta.media, meta: meta, firstFragment: firstFragment, visualBounds: visualBounds, context: context)
            }
        }
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
        switch meta.marker {
        case .blank:
            return
        case .bullet:
            context.setFillColor(accentColor.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
        case .numbered:
            let label = "\(ordinal)." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: accentColor
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        case .checkbox:
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            (meta.done ? accentColor : UIColor(theme.buttonBg)).setFill()
            path.fill()
            accentColor.setStroke()
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

struct ItemDateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let schemeID: String
    let item: MobileItem
    @State private var kind: String
    @State private var date: Date

    init(schemeID: String, item: MobileItem) {
        self.schemeID = schemeID
        self.item = item
        let initialKind = item.start != nil ? "start" : (item.end != nil ? "end" : "start")
        _kind = State(initialValue: initialKind)
        _date = State(initialValue: MobileDate.parseDateTime(initialKind == "start" ? item.start : item.end) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Field", selection: $kind) {
                        Text("Start / At").tag("start")
                        Text("End / Due").tag("end")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, value in
                        date = MobileDate.parseDateTime(value == "start" ? item.start : item.end) ?? date
                    }
                }

                Section {
                    DatePicker(selectedLabel, selection: $date)
                } footer: {
                    Text(summaryText)
                }

                Section {
                    Button("Clear \(selectedLabel)") {
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: kind, date: nil)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                    .disabled(kind == "start" ? item.start == nil : item.end == nil)

                    Button("Clear Both Dates") {
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "start", date: nil)
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "end", date: nil)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                    .disabled(item.start == nil && item.end == nil)
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: kind, date: date)
                        dismiss()
                    }
                }
            }
        }
    }

    private var selectedLabel: String {
        kind == "start" ? "Start" : "End"
    }

    private var summaryText: String {
        let start = MobileDate.formatTime(item.start) ?? "No start"
        let end = MobileDate.formatTime(item.end) ?? "No end"
        return "\(start) · \(end)"
    }
}
