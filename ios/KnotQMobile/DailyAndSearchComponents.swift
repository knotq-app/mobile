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
    private static let bottomAnchorID = "daily-feed-bottom-anchor"
    private static let scrollCoordinateSpace = "daily-feed-scroll-space"

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
    @State private var didInitialBottomPin = false
    @State private var olderLoadsEnabled = false
    @State private var userScrolledTowardOlderEntries = false
    @State private var topSentinelNearViewport = false
    @State private var restoringLoadAnchorDate: String?

    var body: some View {
        VStack(spacing: 0) {
            if !usesNativeNavigation {
                DailyEditorNavigationBar(theme: theme, onBack: onBack, onAdd: onAdd)
            }

            Group {
                if visibleEntries.isEmpty {
                    EmptyState(title: "Daily not ready", detail: "Could not create the daily queue.", theme: theme)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 1)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: DailyFeedTopOffsetPreferenceKey.self,
                                                value: geometry.frame(in: .named(Self.scrollCoordinateSpace)).minY
                                            )
                                        }
                                    }
                                DailyHistoryLoadingRow(isLoading: isLoadingOlder, theme: theme)
                                ForEach(visibleEntries) { entry in
                                    DailyDayEditorSection(
                                        entry: entry,
                                        isEmpty: isEffectivelyEmpty(entry),
                                        selected: entry.date == selectedDateKey,
                                        theme: theme,
                                        autoFocusOnAppear: autoFocusSelectedDay,
                                        onSelect: { onDate(AppModel.date(from: entry.date) ?? selectedDate) }
                                    )
                                    .id(entry.date)
                                    .onAppear {
                                        handleOlderEntryAppear(entry.date)
                                    }
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchorID)
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                            .padding(.bottom, 76)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .coordinateSpace(name: Self.scrollCoordinateSpace)
                        .scrollDismissesKeyboard(.never)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    if value.translation.height > 12 {
                                        userScrolledTowardOlderEntries = true
                                        loadOlderIfReady()
                                    }
                                },
                            including: .subviews
                        )
                            .onPreferenceChange(DailyFeedTopOffsetPreferenceKey.self) { value in
                                topSentinelNearViewport = value >= -20 && value <= 80
                                loadOlderIfReady()
                            }
                            .onAppear {
                                pinInitialBottomIfNeeded(proxy)
                            }
                            .onChange(of: loadAnchorDate) { _, _ in
                                restoreLoadAnchorIfNeeded(proxy)
                            }
                            .onChange(of: visibleEntryDateSignature) { _, _ in
                                restoreLoadAnchorIfNeeded(proxy)
                            }
                            .onChange(of: selectedDateKey) { _, value in
                                scrollWithoutAnimation(proxy, to: value)
                            }
                        }
                    }
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

    private var oldestVisibleDate: String? {
        visibleEntries.first?.date
    }

    private var visibleEntryDateSignature: String {
        visibleEntries.map(\.date).joined(separator: "|")
    }

    /// Hide empty queues unless they are the selected editable day; otherwise
    /// they reserve editor height without showing meaningful content.
    private var visibleEntries: [MobileDailyEntry] {
        return sortedEntries.filter { entry in
            if entry.date == selectedDateKey { return true }
            return !isEffectivelyEmpty(entry)
        }
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

    private func handleOlderEntryAppear(_ date: String) {
        guard olderLoadsEnabled,
              userScrolledTowardOlderEntries,
              topSentinelNearViewport,
              date == oldestVisibleDate
        else {
            return
        }
        loadOlderIfReady()
    }

    private func loadOlderIfReady() {
        guard olderLoadsEnabled,
              userScrolledTowardOlderEntries,
              topSentinelNearViewport,
              let oldestVisibleDate
        else {
            return
        }
        guard canLoadOlder, !isLoadingOlder else {
            userScrolledTowardOlderEntries = false
            return
        }
        userScrolledTowardOlderEntries = false
        onLoadOlder(oldestVisibleDate)
    }

    private func pinInitialBottomIfNeeded(_ proxy: ScrollViewProxy) {
        guard !didInitialBottomPin else { return }
        didInitialBottomPin = true
        olderLoadsEnabled = false
        userScrolledTowardOlderEntries = false
        topSentinelNearViewport = false
        pinToBottom(proxy)
        DispatchQueue.main.async {
            pinToBottom(proxy)
            DispatchQueue.main.async {
                pinToBottom(proxy)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pinToBottom(proxy)
            olderLoadsEnabled = true
        }
    }

    private func pinToBottom(_ proxy: ScrollViewProxy) {
        scrollWithoutAnimation(proxy, to: Self.bottomAnchorID)
    }

    private func restoreLoadAnchorIfNeeded(_ proxy: ScrollViewProxy) {
        guard let anchor = loadAnchorDate else { return }
        guard visibleEntries.contains(where: { $0.date == anchor }) else {
            onLoadAnchorRestored()
            return
        }
        guard restoringLoadAnchorDate != anchor else { return }
        restoringLoadAnchorDate = anchor
        DispatchQueue.main.async {
            scrollWithoutAnimation(proxy, to: anchor, anchor: .top)
            DispatchQueue.main.async {
                scrollWithoutAnimation(proxy, to: anchor, anchor: .top)
                restoringLoadAnchorDate = nil
                onLoadAnchorRestored()
            }
        }
    }

    private func scrollWithoutAnimation<ID: Hashable>(
        _ proxy: ScrollViewProxy,
        to id: ID,
        anchor: UnitPoint = .bottom
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

private struct DailyFeedTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct DailyHistoryLoadingRow: View {
    let isLoading: Bool
    let theme: KnotQTheme

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.textMuted)
                    .accessibilityLabel("Loading older daily entries")
            }
            Spacer()
        }
        .frame(height: isLoading ? 34 : 0)
        .opacity(isLoading ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!isLoading)
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
            .accessibilityLabel("Back")

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
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
            editorInsets: UIEdgeInsets(top: 3, left: 14, bottom: 5, right: 14),
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
        // Self-size from the editor's TextKit measurement (SchemeTextView
        // .sizeThatFits) for every day that renders content — including the
        // selected empty day, which now shows its title plus a blank editable
        // line. Only collapse non-selected empty days to nothing.
        .frame(height: isEmpty && !selected ? 0 : nil, alignment: .top)
        .clipped()
        .background(selected ? theme.rowSelected.opacity(0.42) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            if !selected {
                onSelect()
            }
        }
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
                TextField("Item", text: $draft, axis: .vertical)
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
            Button("Move Up", systemImage: "arrow.up") {
                model.reorderItem(schemeID: schemeID, from: index, to: max(index - 1, 0))
            }
            .disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") {
                model.reorderItem(schemeID: schemeID, from: index, to: min(index + 1, count - 1))
            }
            .disabled(index >= count - 1)
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingItemDelete = true
            }
        }
        .sheet(isPresented: $showingDate) {
            ItemDateSheet(schemeID: schemeID, item: item)
                .presentationDetents([.fraction(0.50)])
        }
        .confirmationDialog(
            "Delete item?",
            isPresented: $pendingItemDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.deleteItem(schemeID: schemeID, itemID: item.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
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
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search across all schemes." : "No results.")
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
        .navigationTitle("Search")
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
                    TextField("Search KnotQ", text: $query)
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
