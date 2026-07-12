import Foundation
import SwiftUI
import UIKit

struct DesktopSchemePane: View {
    let scheme: MobileScheme
    let theme: KnotQTheme
    let onBack: () -> Void
    let onAdd: () -> Void
    var autoFocusTitle: Bool = false
    var onTitleFocusConsumed: () -> Void = {}

    var body: some View {
        IntegratedSchemeEditorPane(
            scheme: scheme,
            theme: theme,
            onBack: onBack,
            onAdd: onAdd,
            autoFocusTitleOnAppear: autoFocusTitle,
            onAutoFocusTitleConsumed: onTitleFocusConsumed
        )
    }
}

struct DailyFeedPane: View {
    let entries: [MobileDailyEntry]
    let selectedDate: Date
    let theme: KnotQTheme
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDate: @MainActor (Date) -> Void
    var onLoadOlder: @MainActor (String) -> Void = { _ in }
    var isLoadingOlder: Bool = false
    var canLoadOlder: Bool = true
    var loadAnchorDate: String?
    var onLoadAnchorRestored: @MainActor () -> Void = {}
    let onBack: () -> Void
    let onAdd: () -> Void
    var usesNativeNavigation: Bool = false
    var autoFocusSelectedDay: Bool = true
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !usesNativeNavigation {
                DailyEditorNavigationBar(theme: theme, onBack: onBack, onAdd: onAdd)
            }

            if visibleEntries.isEmpty {
                EmptyState(title: L10n.t("mobile.daily.not_ready_title"), detail: L10n.t("mobile.daily.not_ready_detail"), theme: theme)
            } else {
                // The feed is hosted in a custom UIKit scroll container rather
                // than a SwiftUI `ScrollView { LazyVStack { ... } }`. Each day is
                // a self-sizing, non-scrolling editor; the LazyVStack recycled
                // the focused day when it scrolled off-screen (tearing down the
                // first responder and jumping layout) and the self-sizing reflow
                // shoved the whole stack. Owning a real `UIScrollView` +
                // `UIStackView` of hosting controllers keeps every mounted day
                // alive and lets us anchor `contentOffset` across content-size
                // and keyboard changes.
                DailyFeedScroll(
                    entries: visibleEntries,
                    selectedDateKey: selectedDateKey,
                    theme: theme,
                    autoFocusSelectedDay: autoFocusSelectedDay,
                    emptyDates: emptyDates,
                    isLoadingOlder: isLoadingOlder,
                    canLoadOlder: canLoadOlder,
                    loadAnchorDate: loadAnchorDate,
                    model: model,
                    onSelect: { dateKey in onDate(AppModel.date(from: dateKey) ?? selectedDate) },
                    onLoadOlder: { oldest in onLoadOlder(oldest) },
                    onLoadAnchorRestored: { onLoadAnchorRestored() }
                )
                // The container manages keyboard insets itself; let SwiftUI not
                // also shrink it for the keyboard (double avoidance jumps it).
                .ignoresSafeArea(.keyboard)
            }
        }
        .background(theme.bgApp.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedDateKey: String {
        AppModel.dateOnly(selectedDate)
    }

    private var sortedEntries: [MobileDailyEntry] {
        entries.sorted { $0.date < $1.date }
    }

    /// Hide empty queues unless they are the selected editable day; otherwise
    /// they reserve editor height without showing meaningful content.
    private var visibleEntries: [MobileDailyEntry] {
        return sortedEntries.filter { entry in
            if entry.date == selectedDateKey { return true }
            return !isEffectivelyEmpty(entry)
        }
    }

    /// Visible entries that have no meaningful content (only the selected day
    /// survives the `visibleEntries` filter while empty). The container passes
    /// this to each day section so it can keep showing the title on the empty
    /// selected day.
    private var emptyDates: Set<String> {
        Set(visibleEntries.filter(isEffectivelyEmpty).map(\.date))
    }

    private func isEffectivelyEmpty(_ entry: MobileDailyEntry) -> Bool {
        !entry.scheme.items.contains(where: itemHasVisibleDailyContent)
    }

    private func itemHasVisibleDailyContent(_ item: MobileItem) -> Bool {
        if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if hasNonEmptyValue(item.start) || hasNonEmptyValue(item.end) || hasNonEmptyValue(item.repeatRule) {
            return true
        }
        return item.notificationOffsetSecs != nil || item.media.contains(where: dailyMediaIsDisplayable)
    }

}

struct DailyEditorNavigationBar: View {
    let theme: KnotQTheme
    let onBack: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(DailyBackButtonStyle(theme: theme))
            .accessibilityLabel(L10n.t("common.back"))

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }
}

/// Applies the blanket tap-to-select gesture only to a non-selected day. The
/// selected day must let taps fall through to the editor — including its
/// transparent side gutters, which a section-level `contentShape(Rectangle())`
/// would otherwise capture, swallowing caret-before/after-a-table taps.
private struct DaySelectTapModifier: ViewModifier {
    let selected: Bool
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        if selected {
            content
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
    }
}

struct DailyDayEditorSection: View {
    let entry: MobileDailyEntry
    let isEmpty: Bool
    let selected: Bool
    let theme: KnotQTheme
    let autoFocusOnAppear: Bool
    let onSelect: () -> Void

    var body: some View {
        IntegratedSchemeEditorPane(
            scheme: displayScheme,
            theme: theme,
            onBack: nil,
            onAdd: {},
            usesNativeNavigation: false,
            showsEditorNavigation: false,
            editorScrollEnabled: false,
            // left/right keep the table's original gutter size (the old 10pt feed
            // padding + 14pt inset = 24), but as `textContainerInset` rather than
            // SwiftUI padding so the editor spans edge-to-edge: the whole gutter,
            // right up to the screen edge, is now inside the tappable text view
            // (the dead outer strip is gone) without narrowing the table.
            editorInsets: UIEdgeInsets(top: 3, left: 24, bottom: 5, right: 24),
            // Always show the day's title on the selected day, even when it's
            // empty — a freshly created daily queue has no content yet, and
            // hiding the title there leaves the section looking like it never got
            // created. Non-selected empty days stay collapsed.
            showsInlineTitle: !isEmpty || selected,
            // Focus the selected (last/today) day on open even when it's empty —
            // a fresh daily queue has no items, and we still want the caret + the
            // keyboard up at the end of that section so the user can type right
            // away. `autoFocusSelectedDay` is the real opt-in (off on iPad/screenshots).
            autoFocusOnAppear: selected && autoFocusOnAppear
        )
        // Fill the row's full width so the editor's own text view (and its
        // tappable side gutters beside a table) reaches the screen edge, instead
        // of sitting narrower than the row with dead section margin around it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Self-size from the editor's TextKit measurement (SchemeTextView
        // .sizeThatFits) for every day that renders content — including the
        // selected empty day, which now shows its title plus a blank editable
        // line. Only collapse non-selected empty days to nothing.
        .frame(height: isEmpty && !selected ? 0 : nil, alignment: .top)
        .clipped()
        .background(selected ? theme.rowSelected.opacity(0.42) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        // Tap-to-select only for *non-selected* days. On the selected day (the one
        // being edited) a section-wide contentShape+onTapGesture would swallow
        // taps in the editor's transparent side gutters before they reach the text
        // view — breaking caret-before/after-a-table taps there.
        .modifier(DaySelectTapModifier(selected: selected, onSelect: onSelect))
    }

    private var displayScheme: MobileScheme {
        MobileScheme(
            id: entry.scheme.id,
            name: entry.scheme.name,
            displayName: entry.scheme.displayName,
            colorIndex: entry.scheme.colorIndex,
            isDailyQueue: entry.scheme.isDailyQueue,
            isReadOnly: entry.scheme.isReadOnly,
            date: entry.scheme.date,
            items: displayItems
        )
    }

    private var displayItems: [MobileItem] {
        entry.scheme.items.map { item in
            var item = item
            item.media = item.media.filter(dailyMediaIsDisplayable)
            return item
        }
    }

}

private func dailyMediaIsDisplayable(_ media: MobileItemMedia) -> Bool {
    guard media.kind == "image",
          let path = media.path?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else {
        return false
    }
    return FileManager.default.fileExists(atPath: path)
}

private func hasNonEmptyValue(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
}

private struct DailyBackButtonStyle: ButtonStyle {
    let theme: KnotQTheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = Circle()
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 38, height: 38)
            .background {
                if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
                    Color.clear
                } else {
                    shape.fill(theme.buttonBg)
                }
            }
            .overlay {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    shape.strokeBorder(theme.isDark ? Color.white.opacity(0.16) : theme.borderOverlay.opacity(0.75), lineWidth: 0.7)
                }
            }
            .glassEffectIfAvailable(theme: theme, in: shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable<S: Shape>(theme: KnotQTheme, in shape: S) -> some View {
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
            self
                .glassEffect(.regular.tint(theme.isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.20)).interactive(), in: shape)
                .overlay {
                    shape.stroke(theme.isDark ? Color.white.opacity(0.15) : theme.borderOverlay.opacity(0.72), lineWidth: 0.7)
                }
        } else {
            self
        }
    }
}

struct DesktopItemRow: View {
    @EnvironmentObject private var model: AppModel
    let schemeID: String
    let item: MobileItem
    let index: Int
    let count: Int
    let theme: KnotQTheme

    @State private var draft: String
    @State private var showingDate = false
    @State private var pendingItemDelete = false

    init(schemeID: String, item: MobileItem, index: Int, count: Int, theme: KnotQTheme) {
        self.schemeID = schemeID
        self.item = item
        self.index = index
        self.count = count
        self.theme = theme
        _draft = State(initialValue: item.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if item.marker == "checkbox" {
                    model.toggleItem(schemeID: schemeID, itemID: item.id)
                } else {
                    model.setItemMarker(schemeID: schemeID, itemID: item.id, marker: .checkbox)
                }
            } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : markerIcon(item.marker))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.done ? theme.accent : theme.textDim)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(item.indent) * 18)

            VStack(alignment: .leading, spacing: 6) {
                TextField(L10n.t("sidebar.context.item"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(item.done ? theme.textMuted : theme.textPrimary)
                    .strikethrough(item.done)
                    .onSubmit { commitText() }
                    .onDisappear { commitText() }
                    .onChange(of: item.text) { _, value in
                        if draft != value { draft = value }
                    }

                HStack(spacing: 7) {
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textMuted)

                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textDim)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(index % 2 == 1 ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contextMenu {
            Button(L10n.t("mobile.daily.move_up"), systemImage: "arrow.up") {
                model.reorderItem(schemeID: schemeID, from: index, to: max(index - 1, 0))
            }
            .disabled(index == 0)
            Button(L10n.t("mobile.daily.move_down"), systemImage: "arrow.down") {
                model.reorderItem(schemeID: schemeID, from: index, to: min(index + 1, count - 1))
            }
            .disabled(index >= count - 1)
            Button(L10n.t("common.delete"), systemImage: "trash", role: .destructive) {
                pendingItemDelete = true
            }
        }
        .sheet(isPresented: $showingDate) {
            ItemDateSheet(schemeID: schemeID, item: item)
                .presentationDetents([.fraction(0.50)])
        }
        .confirmationDialog(
            L10n.t("mobile.daily.delete_item_confirm_title"),
            isPresented: $pendingItemDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.t("common.delete"), role: .destructive) {
                model.deleteItem(schemeID: schemeID, itemID: item.id)
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("mobile.daily.delete_item_confirm_message"))
        }
    }

    private func commitText() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != item.text {
            model.updateItemText(schemeID: schemeID, itemID: item.id, text: trimmed)
        }
    }

    private func markerIcon(_ marker: String) -> String {
        switch marker {
        case "checkbox": "square"
        case "bullet": "smallcircle.filled.circle"
        case "numbered": "list.number"
        default: "text.alignleft"
        }
    }
}

/// iPad search detail: a native `.searchable` field in the nav bar over a plain
/// results List, instead of the iPhone's bottom-floating search bar.
struct IPadSearchDetail: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @Binding var query: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        List {
            if model.searchHits.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.t("mobile.search.empty_hint") : L10n.t("mobile.search.no_results"))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(model.searchHits.enumerated()), id: \.element.id) { idx, hit in
                    Button {
                        if let schemeID = hit.schemeId {
                            onOpenScheme(schemeID)
                        }
                    } label: {
                        HomeSearchHitRow(hit: hit, theme: theme, striped: false)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(idx % 2 == 1 ? theme.rowAlt : Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .autocorrectionDisabled()
        .navigationTitle(L10n.t("mobile.search.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DesktopSearchPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    var keyboardVisible: Bool = false
    let onOpenScheme: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @GestureState private var searchBarDragOffset: CGFloat = 0

    var body: some View {
        let keyboardRaised = keyboardVisible || searchFocused
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(model.searchHits.enumerated()), id: \.element.id) { idx, hit in
                    Button {
                        if let schemeID = hit.schemeId {
                            onOpenScheme(schemeID)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Rectangle()
                                .fill(searchHitColor(hit, dark: theme.isDark))
                                .frame(width: 1.5)
                                .padding(.vertical, 7)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.schemeName.isEmpty ? hit.targetKind.capitalized : hit.schemeName)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(searchHitColor(hit, dark: theme.isDark))
                                    Spacer()
                                    Text(hit.detail)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(theme.textSoft)
                                }
                                Text(hit.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 7)
                            .padding(.trailing, 8)
                        }
                        .background(idx % 2 == 1 ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bgApp)
        // Apple-style: the search field lives at the bottom, riding above the
        // keyboard. It clears the floating dock when the keyboard is down.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textMuted)
                    TextField(L10n.t("search.placeholder"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { model.search(query) }
                        .onChange(of: query) { _, value in model.search(value) }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            model.search("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 44)
            }
            .padding(.horizontal, 12)
            .background(theme.bgModal, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(theme.borderOverlay, lineWidth: 1) }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            // Driven by the real keyboard state (same signal as the dock) so the
            // bar and dock shift together: snug above the keyboard when open,
            // clearing the floating dock when closed.
            .padding(.bottom, keyboardRaised ? 8 : 84)
            .offset(y: max(0, searchBarDragOffset))
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .updating($searchBarDragOffset) { value, state, _ in
                        if value.translation.height > 0 &&
                           abs(value.translation.width) < value.translation.height * 1.25 {
                            state = min(112, value.translation.height)
                        } else {
                            state = 0
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 28 &&
                           value.translation.height > abs(value.translation.width) * 1.25 {
                            searchFocused = false
                        }
                    },
                including: .subviews
            )
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.85), value: searchBarDragOffset)
            // Solid fill (no gradient fade) so the search bar has a crisp top
            // edge and content is cleanly hidden behind it instead of hazing.
            .background(theme.bgApp)
        }
        .onAppear {
            model.search(query)
            // Prefill the cursor: focus the field as soon as the pane appears.
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

// MARK: - Daily feed UIKit scroll container

/// UIKit-backed scroll container for the Daily feed (see the comment in
/// `DailyFeedPane.body` for why the SwiftUI `ScrollView`/`LazyVStack` version was
/// replaced). It hosts one `UIHostingController<DailyDayEditorSection>` per
/// visible day inside a `UIScrollView` + `UIStackView`, so:
///   * no day is recycled while it (and its first responder) scrolls off-screen,
///   * Auto Layout self-sizing of each day is stable (no reflow jumps),
///   * `contentOffset` is owned here, so the focused day stays anchored across
///     content-size changes (loading older history) and keyboard show/hide.
struct DailyFeedScroll: UIViewControllerRepresentable {
    let entries: [MobileDailyEntry]          // already filtered to visible + sorted ascending
    let selectedDateKey: String
    let theme: KnotQTheme
    let autoFocusSelectedDay: Bool
    let emptyDates: Set<String>
    let isLoadingOlder: Bool
    let canLoadOlder: Bool
    let loadAnchorDate: String?
    let model: AppModel
    let onSelect: (String) -> Void
    let onLoadOlder: (String) -> Void
    let onLoadAnchorRestored: () -> Void

    func makeUIViewController(context: Context) -> DailyFeedScrollController {
        let controller = DailyFeedScrollController()
        push(into: controller)
        controller.apply(initial: true)
        return controller
    }

    func updateUIViewController(_ controller: DailyFeedScrollController, context: Context) {
        push(into: controller)
        controller.apply(initial: false)
    }

    private func push(into controller: DailyFeedScrollController) {
        controller.model = model
        controller.theme = theme
        controller.entries = entries
        controller.selectedDateKey = selectedDateKey
        controller.autoFocusSelectedDay = autoFocusSelectedDay
        controller.emptyDates = emptyDates
        controller.isLoadingOlder = isLoadingOlder
        controller.canLoadOlder = canLoadOlder
        controller.loadAnchorDate = loadAnchorDate
        controller.onSelect = onSelect
        controller.onLoadOlder = onLoadOlder
        controller.onLoadAnchorRestored = onLoadAnchorRestored
    }
}

final class DailyFeedScrollController: UIViewController, UIScrollViewDelegate {
    private enum ScrollEdge { case top, bottom }
    private static let baseTopInset: CGFloat = 2
    // Clears the floating add button at the bottom (matched the old SwiftUI
    // `.padding(.bottom, 76)`).
    private static let baseBottomInset: CGFloat = 76
    private static let maxContentWidth: CGFloat = 760
    private static let loadOlderTopThreshold: CGFloat = 80

    // Inputs (set by the representable before each `apply`).
    var model: AppModel!
    var theme: KnotQTheme = .dark
    var entries: [MobileDailyEntry] = []
    var selectedDateKey: String = ""
    var autoFocusSelectedDay: Bool = false
    var emptyDates: Set<String> = []
    var isLoadingOlder: Bool = false
    var canLoadOlder: Bool = true
    var loadAnchorDate: String?
    var onSelect: (String) -> Void = { _ in }
    var onLoadOlder: (String) -> Void = { _ in }
    var onLoadAnchorRestored: () -> Void = {}

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let loadingRow = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // One hosting controller per day, keyed by `entry.date`.
    private var hosts: [String: UIHostingController<AnyView>] = [:]
    private var order: [String] = []
    // What `rootView(for:)` was last built from, per day — every `AppModel`
    // mutation republishes `snapshot` (so e.g. the user's own live-flush of the
    // line they're typing re-invokes `apply` here), but most of those carry no
    // real change for this feed. Skipping the rootView reassignment (and the
    // anchor-based scroll resnap below) when nothing changed avoids an Auto
    // Layout pass + contentOffset correction firing on every keystroke's flush.
    private var lastAppliedEntry: [String: MobileDailyEntry] = [:]
    private var lastAppliedFlags: [String: (isEmpty: Bool, selected: Bool, isDark: Bool, autoFocus: Bool)] = [:]

    private var didSetup = false
    private var needsInitialPin = false
    private var didInitialBottomPin = false
    private var pendingLoadOlder = false
    private var lastSelectedDateKey = ""
    private var keyboardInset: CGFloat = 0
    private var pendingCaretScrollWorkItem: DispatchWorkItem?

    // MARK: Lifecycle

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        setupIfNeeded()
    }

    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .none
        // We own every inset, so don't let the system fold the safe area in.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: Self.baseTopInset, left: 0, bottom: Self.baseBottomInset, right: 0)
        view.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 0
        scrollView.addSubview(stack)

        loadingRow.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        loadingRow.addSubview(spinner)
        stack.addArrangedSubview(loadingRow)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        // Width = min(viewport, maxContentWidth), left-aligned (matches the old
        // `.frame(maxWidth: 760, alignment: .leading)`). Pinning both edges of
        // the stack to the content guide makes content width == stack width, so
        // the feed never scrolls horizontally.
        let preferWide = stack.widthAnchor.constraint(equalTo: frame.widthAnchor)
        preferWide.priority = .defaultHigh
        let capWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentWidth)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preferWide,
            capWidth,

            loadingRow.heightAnchor.constraint(equalToConstant: 34),
            spinner.centerXAnchor.constraint(equalTo: loadingRow.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingRow.centerYAnchor),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if needsInitialPin, scrollView.bounds.height > 0, scrollView.contentSize.height > 0 {
            needsInitialPin = false
            pinToBottom()
            // Re-pin after the next layout pass; self-sizing editors settle their
            // height a tick late, which would otherwise leave us short of bottom.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pinToBottom()
                self.didInitialBottomPin = true
            }
        }
    }

    // MARK: Apply

    func apply(initial: Bool) {
        loadViewIfNeeded()

        // Capture the on-screen position of an anchor day BEFORE mutating the
        // content, so loading older history (which prepends rows) doesn't shift
        // what the user is looking at.
        var anchor: (date: String, screenY: CGFloat)?
        if !initial, scrollView.bounds.height > 0 {
            let anchorDate = (loadAnchorDate.flatMap { hosts[$0] != nil ? $0 : nil }) ?? topmostVisibleDate()
            if let date = anchorDate, let v = hosts[date]?.view {
                anchor = (date, v.frame.minY - scrollView.contentOffset.y)
            }
        }

        let (contentChanged, structuralChanged) = reconcile()
        spinner.isHidden = !isLoadingOlder
        if isLoadingOlder { spinner.startAnimating() } else { spinner.stopAnimating() }
        loadingRow.isHidden = !isLoadingOlder
        // A finished/cleared load re-arms the top trigger.
        if !isLoadingOlder { pendingLoadOlder = false }

        if contentChanged {
            view.layoutIfNeeded()
        }
        // Resnap only for structural changes (a day added/removed/reordered) or
        // an explicit `loadAnchorDate` — see the `reconcile` doc comment.
        if structuralChanged || loadAnchorDate != nil,
           let anchor, let v = hosts[anchor.date]?.view {
            scrollView.contentOffset.y = clampOffsetY(v.frame.minY - anchor.screenY)
        }

        // The anchor signal is single-shot; clear it once we've consumed it.
        // Async so we don't mutate model state mid SwiftUI update.
        if loadAnchorDate != nil {
            DispatchQueue.main.async { [weak self] in self?.onLoadAnchorRestored() }
        }

        if initial {
            needsInitialPin = !entries.isEmpty
            lastSelectedDateKey = selectedDateKey
        } else if selectedDateKey != lastSelectedDateKey {
            lastSelectedDateKey = selectedDateKey
            if didInitialBottomPin {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollTo(date: self?.selectedDateKey ?? "", edge: .bottom)
                }
            }
        }
    }

    /// Reconciles the hosting controllers to `entries`: updates existing days in
    /// place (preserving their editor state / first responder), creates hosts for
    /// new days, removes vanished ones, and orders them after the loading row.
    /// Returns `(contentChanged, structuralChanged)` — callers use these to skip
    /// unnecessary work in `apply`:
    ///  - `contentChanged`: some day's rootView was actually reassigned (skip the
    ///    Auto Layout pass otherwise — most `apply` calls are no-ops, since
    ///    `entries` is rebuilt from `AppModel.snapshot`, which republishes on
    ///    every mutate anywhere in the app, including our own live-flush).
    ///  - `structuralChanged`: a day was added, removed, or reordered. Only this
    ///    (or an explicit `loadAnchorDate`, the "loaded older history" signal)
    ///    justifies the anchor resnap below — content growing/shrinking *within*
    ///    an already-visible day (e.g. the line the user is actively typing,
    ///    including on a slow enough cadence that every keystroke's flush is a
    ///    real, distinct change) doesn't move anything above it, so there is
    ///    nothing to correct for. Resnapping anyway was visible as an instant
    ///    jump-then-settle on every such flush.
    private func reconcile() -> (contentChanged: Bool, structuralChanged: Bool) {
        var contentChanged = false
        var structuralChanged = false
        let newDates = entries.map(\.date)
        let newSet = Set(newDates)

        for (date, host) in hosts where !newSet.contains(date) {
            host.willMove(toParent: nil)
            stack.removeArrangedSubview(host.view)
            host.view.removeFromSuperview()
            host.removeFromParent()
            hosts[date] = nil
            lastAppliedEntry[date] = nil
            lastAppliedFlags[date] = nil
            contentChanged = true
            structuralChanged = true
        }

        for (index, entry) in entries.enumerated() {
            let flags = (
                isEmpty: emptyDates.contains(entry.date),
                selected: entry.date == selectedDateKey,
                isDark: theme.isDark,
                autoFocus: autoFocusSelectedDay
            )
            let host: UIHostingController<AnyView>
            if let existing = hosts[entry.date] {
                host = existing
                let unchanged = lastAppliedEntry[entry.date] == entry
                    && (lastAppliedFlags[entry.date].map { $0 == flags } ?? false)
                if !unchanged {
                    host.rootView = rootView(for: entry)
                    lastAppliedEntry[entry.date] = entry
                    lastAppliedFlags[entry.date] = flags
                    contentChanged = true
                }
            } else {
                host = UIHostingController(rootView: rootView(for: entry))
                host.view.backgroundColor = .clear
                host.sizingOptions = .intrinsicContentSize
                addChild(host)
                hosts[entry.date] = host
                host.didMove(toParent: self)
                lastAppliedEntry[entry.date] = entry
                lastAppliedFlags[entry.date] = flags
                contentChanged = true
                structuralChanged = true
            }
            // +1 to sit after the loading row at index 0.
            let target = index + 1
            if stack.arrangedSubviews.firstIndex(of: host.view) != target {
                stack.insertArrangedSubview(host.view, at: min(target, stack.arrangedSubviews.count))
                contentChanged = true
                structuralChanged = true
            }
        }
        order = newDates
        return (contentChanged, structuralChanged)
    }

    private func rootView(for entry: MobileDailyEntry) -> AnyView {
        let date = entry.date
        return AnyView(
            DailyDayEditorSection(
                entry: entry,
                isEmpty: emptyDates.contains(date),
                selected: date == selectedDateKey,
                theme: theme,
                autoFocusOnAppear: autoFocusSelectedDay,
                onSelect: { [weak self] in self?.onSelect(date) }
            )
            .environmentObject(model)
        )
    }

    // MARK: Scrolling helpers

    private func clampOffsetY(_ y: CGFloat) -> CGFloat {
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        return min(max(y, minY), maxY)
    }

    private func pinToBottom() {
        view.layoutIfNeeded()
        scrollView.contentOffset.y = clampOffsetY(.greatestFiniteMagnitude)
    }

    private func scrollTo(date: String, edge: ScrollEdge) {
        guard let v = hosts[date]?.view else { return }
        view.layoutIfNeeded()
        let target: CGFloat
        switch edge {
        case .top:
            target = v.frame.minY - scrollView.adjustedContentInset.top
        case .bottom:
            target = v.frame.maxY - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        }
        scrollView.contentOffset.y = clampOffsetY(target)
    }

    private func topmostVisibleDate() -> String? {
        let topY = scrollView.contentOffset.y
        for date in order {
            if let v = hosts[date]?.view, v.frame.maxY > topY + 0.5 { return date }
        }
        return order.last
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard didInitialBottomPin,
              scrollView.isDragging || scrollView.isDecelerating,
              canLoadOlder, !isLoadingOlder, !pendingLoadOlder,
              let oldest = order.first else { return }
        let topThreshold = -scrollView.adjustedContentInset.top + Self.loadOlderTopThreshold
        guard scrollView.contentOffset.y <= topThreshold else { return }
        pendingLoadOlder = true
        onLoadOlder(oldest)
    }

    // MARK: Keyboard

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let kbInView = view.convert(value.cgRectValue, from: nil)
        let newInset = max(0, scrollView.frame.maxY - kbInView.minY)
        // The predictive-text/accessory bar refires this notification on nearly
        // every keystroke even when the keyboard's actual height hasn't changed.
        // Reacting unconditionally restarted an animated caret-follow scroll
        // mid-flight on every letter — a stack of competing animations that
        // shows up as the feed instantly jumping and settling back a beat
        // later. Only react when the height genuinely moved.
        guard abs(newInset - keyboardInset) > 0.5 else { return }
        keyboardInset = newInset
        updateBottomInset()
        pendingCaretScrollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.scrollFocusedCaretToVisible() }
        pendingCaretScrollWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardInset = 0
        updateBottomInset()
    }

    private func updateBottomInset() {
        var inset = scrollView.contentInset
        inset.bottom = Self.baseBottomInset + keyboardInset
        scrollView.contentInset = inset
        scrollView.verticalScrollIndicatorInsets.bottom = keyboardInset
    }

    private func scrollFocusedCaretToVisible() {
        guard let textView = firstResponderTextView(in: view),
              let selection = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: selection.end)
        guard caret.origin.y.isFinite, caret.size.height.isFinite else { return }
        let rect = textView.convert(caret, to: scrollView).insetBy(dx: 0, dy: -24)
        scrollView.scrollRectToVisible(rect, animated: true)
    }

    private func firstResponderTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isFirstResponder { return textView }
        for subview in view.subviews {
            if let found = firstResponderTextView(in: subview) { return found }
        }
        return nil
    }
}
