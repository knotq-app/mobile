import SwiftUI

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
    let onBack: () -> Void
    let onAdd: () -> Void
    var usesNativeNavigation: Bool = false

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
                            VStack(spacing: 0) {
                                ForEach(visibleEntries) { entry in
                                    DailyDayEditorSection(
                                        entry: entry,
                                        selected: entry.date == selectedDateKey,
                                        theme: theme,
                                        onSelect: { onDate(AppModel.date(from: entry.date) ?? selectedDate) }
                                    )
                                    .id(entry.date)
                                }
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .padding(.bottom, 76)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollDismissesKeyboard(.never)
                            .onAppear {
                                // Land on the selected day immediately, then re-pin once
                                // the editor rows have measured their height so the day
                                // settles in place instead of drifting a beat later.
                                proxy.scrollTo(selectedDateKey, anchor: .bottom)
                                DispatchQueue.main.async {
                                    proxy.scrollTo(selectedDateKey, anchor: .bottom)
                                }
                            }
                            .onChange(of: selectedDateKey) { _, value in
                                proxy.scrollTo(value, anchor: .bottom)
                            }
                        }
                    }
            }
        }
        .background(theme.bgApp.ignoresSafeArea())
        .navigationTitle(usesNativeNavigation ? "Daily" : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedDateKey: String {
        AppModel.dateOnly(selectedDate)
    }

    private var sortedEntries: [MobileDailyEntry] {
        entries.sorted { $0.date < $1.date }
    }

    private var selectedEntry: MobileDailyEntry? {
        entries.first { $0.date == selectedDateKey }
    }

    /// Hide empty queues that are neither today nor yesterday — they would
    /// otherwise just show "Start typing" and waste vertical space.
    private var visibleEntries: [MobileDailyEntry] {
        let today = AppModel.dateOnly(Date())
        let yesterday = AppModel.dateOnly(
            Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        )
        return sortedEntries.filter { entry in
            if entry.date == today || entry.date == yesterday { return true }
            if entry.date == selectedDateKey { return true }
            return !isEffectivelyEmpty(entry)
        }
    }

    private func isEffectivelyEmpty(_ entry: MobileDailyEntry) -> Bool {
        entry.scheme.items.allSatisfy { item in
            item.text.isEmpty
                && item.marker == "blank"
                && item.indent == 0
                && item.start == nil
                && item.end == nil
        }
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
            .buttonStyle(TitleIconButton(theme: theme))

            Text("Daily")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

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
    let selected: Bool
    let theme: KnotQTheme
    let onSelect: () -> Void

    var body: some View {
        IntegratedSchemeEditorPane(
            scheme: entry.scheme,
            theme: theme,
            onBack: nil,
            onAdd: {},
            usesNativeNavigation: false,
            showsEditorNavigation: false,
            editorScrollEnabled: false,
            editorInsets: UIEdgeInsets(top: 3, left: 14, bottom: 5, right: 14),
            autoFocusOnAppear: selected
        )
        .frame(minHeight: editorHeight)
        .background(selected ? theme.rowSelected.opacity(0.42) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            if !selected {
                onSelect()
            }
        }
    }

    private var editorHeight: CGFloat {
        let visualLineCount = entry.scheme.items.reduce(0) { total, item in
            total + max(1, Int(ceil(Double(max(item.text.count, 1)) / 34.0)))
        }
        let annotationCount = entry.scheme.items.filter { $0.start != nil || $0.end != nil }.count
        return max(104, CGFloat(max(1, visualLineCount)) * 24 + CGFloat(annotationCount) * 14 + 52)
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
    let onOpenScheme: (String) -> Void
    @State private var query = ""

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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search KnotQ")
        .autocorrectionDisabled()
        .onChange(of: query) { _, value in model.search(value) }
        .onAppear { model.search(query) }
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

