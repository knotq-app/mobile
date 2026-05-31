import SwiftUI

struct HomeDashboardPane: View {
    let snapshot: MobileSnapshot?
    let selectedDate: Date
    let theme: KnotQTheme
    let onOpenDaily: () -> Void
    let onOpenScheme: (String) -> Void
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let schemePreviewMaxHeight = max(180, proxy.size.height * 0.34)
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HomeSchemesSection(
                            root: snapshot?.root,
                            dailyEntry: dailyEntry,
                            selectedDate: selectedDate,
                            maxHeight: schemePreviewMaxHeight,
                            theme: theme,
                            onOpenDaily: onOpenDaily,
                            onOpenScheme: onOpenScheme,
                            onNewScheme: onNewScheme,
                            onNewFolder: onNewFolder,
                            onGoogleCalendar: onGoogleCalendar
                        )

                        HomeUpcomingSection(
                            occurrences: upcomingOccurrences,
                            theme: theme,
                            timeFormat: timeFormat,
                            onToggleOccurrence: onToggleOccurrence,
                            onOpenOccurrence: onOpenOccurrence
                        )
                    }
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollDismissesKeyboard(.never)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.bgApp)

                HomeQuickWriteButtons(theme: theme, onNewScheme: onNewScheme, onOpenDaily: onOpenDaily)
                    .padding(.trailing, 22)
                    // Pane now extends under the home indicator; lift the buttons
                    // back up so they clear the floating dock and bottom edge.
                    .padding(.bottom, 120)
            }
            .background(theme.bgApp)
        }
        // Fill the bottom safe-area lip so content scrolls to the screen edge.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var selectedDateKey: String {
        AppModel.dateOnly(selectedDate)
    }

    private var todayKey: String {
        AppModel.dateOnly(Date())
    }

    private var dailyEntry: MobileDailyEntry? {
        snapshot?.daily.first { $0.date == selectedDateKey }
            ?? snapshot?.daily.first { $0.date == todayKey }
    }

    /// Overdue items first (so they aren't missed), then upcoming ones.
    private var upcomingOccurrences: [MobileOccurrence] {
        let overdue = snapshot?.calendar.overdue ?? []
        let upcoming = snapshot?.calendar.upcoming ?? []
        return Array((overdue + upcoming).prefix(14))
    }

    private var timeFormat: String {
        snapshot?.settings.timeFormat ?? "twelve_hour"
    }
}

struct HomeUpcomingSection: View {
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 2)

            if occurrences.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 180)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(occurrences.enumerated()), id: \.element.id) { idx, occurrence in
                        OccurrenceCompactRow(
                            occurrence: occurrence,
                            theme: theme,
                            timeFormat: timeFormat,
                            striped: idx % 2 == 1,
                            showDayLabel: true,
                            longPressDuration: 0.18,
                            moreAction: { onOpenOccurrence(occurrence) }
                        ) {
                            onToggleOccurrence(occurrence)
                        }
                    }
                }
                .padding(.bottom, 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct HomeNavigationPane: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: MobileSnapshot?
    let selectedDate: Date
    let theme: KnotQTheme
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onCreateScheme: () -> String?
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void
    let onAddItem: (String) -> Void
    let onPrepareDaily: () -> Void
    let onSelectDailyDate: @MainActor (Date) -> Void
    @Binding var titleFocusSchemeID: String?
    @Binding var navigationDepth: Int
    @State private var path: [HomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeDashboardPane(
                snapshot: snapshot,
                selectedDate: selectedDate,
                theme: theme,
                onOpenDaily: openDailyInStack,
                onOpenScheme: { path.append(.scheme($0)) },
                onToggleOccurrence: onToggleOccurrence,
                onOpenOccurrence: onOpenOccurrence,
                onNewScheme: createSchemeInStack,
                onNewFolder: onNewFolder,
                onGoogleCalendar: onGoogleCalendar
            )
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .scheme(let id):
                    if let scheme = model.scheme(id: id) {
                        IntegratedSchemeEditorPane(
                            scheme: scheme,
                            theme: theme,
                            onBack: nil,
                            onAdd: { onAddItem(scheme.id) },
                            usesNativeNavigation: true,
                            showsEditorNavigation: true,
                            autoFocusOnAppear: titleFocusSchemeID != scheme.id,
                            autoFocusTitleOnAppear: titleFocusSchemeID == scheme.id,
                            onAutoFocusTitleConsumed: { consumeTitleFocus(for: scheme.id) }
                        )
                        .toolbar(.visible, for: .navigationBar)
                    } else {
                        EmptyState(title: "Scheme missing", detail: "It may have been archived or deleted.", theme: theme)
                            .toolbar(.visible, for: .navigationBar)
                    }
                case .daily:
                    DailyFeedPane(
                        entries: model.snapshot?.daily ?? [],
                        selectedDate: model.selectedDate,
                        theme: theme,
                        onPrevious: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                        onNext: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                        onDate: onSelectDailyDate,
                        onBack: {},
                        onAdd: {
                            if let daily = model.snapshot?.daily.first(where: { $0.date == AppModel.dateOnly(model.selectedDate) })?.scheme {
                                onAddItem(daily.id)
                            }
                        },
                        usesNativeNavigation: true
                    )
                    .toolbar(.visible, for: .navigationBar)
                }
            }
        }
        .onChange(of: path) { _, newPath in
            navigationDepth = newPath.count
        }
        .onDisappear {
            navigationDepth = 0
        }
    }

    private func consumeTitleFocus(for id: String) {
        if titleFocusSchemeID == id {
            titleFocusSchemeID = nil
        }
    }

    private func createSchemeInStack() {
        guard let id = onCreateScheme() else { return }
        path.append(.scheme(id))
    }

    private func openDailyInStack() {
        onPrepareDaily()
        path.append(.daily)
    }
}

struct HomeSchemesSection: View {
    let root: MobileNode?
    let dailyEntry: MobileDailyEntry?
    let selectedDate: Date
    let maxHeight: CGFloat
    let theme: KnotQTheme
    let onOpenDaily: () -> Void
    let onOpenScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text("Schemes")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    Button("Google Calendar", systemImage: "calendar.badge.plus") {
                        onGoogleCalendar(nil)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(theme.buttonBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 3)

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let root, !root.children.isEmpty {
                        SchemeNavigatorListView(
                            root: root,
                            selectedSchemeID: nil,
                            theme: theme,
                            compact: false,
                            onOpenScheme: onOpenScheme
                        )
                    } else {
                        Text("No schemes yet")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                    }
                }
                .frame(height: maxHeight)

                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(height: 0.5)
                    .padding(.leading, 4)
                    .padding(.trailing, 4)

                HomeDailySchemeRow(
                    entry: dailyEntry,
                    selectedDate: selectedDate,
                    theme: theme,
                    onOpenDaily: onOpenDaily
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
            .background(theme.rowSelected.opacity(theme.isDark ? 0.52 : 0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.borderOverlay, lineWidth: 0.8)
            }
        }
    }
}

struct HomeDailySchemeRow: View {
    let entry: MobileDailyEntry?
    let selectedDate: Date
    let theme: KnotQTheme
    let onOpenDaily: () -> Void

    var body: some View {
        Button(action: onOpenDaily) {
            HStack(spacing: 8) {
                SchemeTreePrefix(depth: 0, showsDisclosure: false, expanded: false, compact: false, theme: theme)
                SchemeTreeIconSlot(compact: false) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.isDark ? Color(hex: 0xc0d6ff) : Color(hex: 0x4f71a6))
                }
                Text("Daily")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(AppModel.displayDate(entry?.date ?? AppModel.dateOnly(selectedDate)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            }
        .buttonStyle(.plain)
        .accessibilityLabel("Daily")
    }

    private var openCount: Int {
        guard let entry else { return 0 }
        return entry.scheme.items.filter { item in
            !item.done && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }
}
