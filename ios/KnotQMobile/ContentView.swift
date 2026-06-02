import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MobilePane: String, CaseIterable, Identifiable {
    case home
    case calendar
    case scheme
    case daily
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .calendar: "Calendar"
        case .scheme: "Scheme"
        case .daily: "Daily"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "square.stack.3d.up"
        case .calendar: "calendar"
        case .scheme: "list.bullet.rectangle"
        case .daily: "checklist"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

private enum AddItemTarget: Identifiable {
    case scheme(String)
    case todayDaily

    var id: String {
        switch self {
        case .scheme(let id): "scheme-\(id)"
        case .todayDaily: "today-daily"
        }
    }
}

private struct PendingOccurrenceMove: Identifiable {
    let id = UUID()
    let occurrence: MobileOccurrence
    let start: Date?
    let end: Date?
}

enum HomeRoute: Hashable {
    case scheme(String)
    case daily
}

/// Selection in the iPad NavigationSplitView sidebar: the fixed destinations plus
/// a specific scheme (driven by the embedded scheme tree).
enum SidebarItem: Hashable {
    case home
    case calendar
    case daily
    case settings
    case scheme(String)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: MobilePane = .home
    @State private var selectedSchemeID: String?
    @State private var addItemTarget: AddItemTarget?
    @State private var showingCalendarAdd = false
    @State private var showingMonthView = false
    @State private var showingNewFolder = false
    @State private var eventEditor: EventEditorTarget?
    @State private var pendingOccurrenceMove: PendingOccurrenceMove?
    @State private var keyboardVisible = false
    @State private var titleFocusSchemeID: String?
    @State private var homeNavigationDepth = 0
    @State private var timelineResetToken = 0
    // iPad NavigationSplitView state.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingUpcoming = true

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    private func applyWindowBackground(_ color: Color) {
        let uiColor = UIColor(color)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.backgroundColor = uiColor
            }
        }
    }

    private var selectedScheme: MobileScheme? {
        model.scheme(id: selectedSchemeID)
    }

    private var title: String {
        return pane.title
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            Group {
                if wide {
                    iPadRoot()
                } else {
                    iPhoneRoot()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bgApp.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .onChange(of: wide) { _, isWide in
                if !isWide, pane == .search {
                    pane = .home
                }
            }
            // The window itself is black by default, so it shows through the
            // bottom safe-area lip and behind the transparent keyboard toolbar.
            // Paint it with the theme background so those gaps match the app.
            .onAppear { applyWindowBackground(theme.bgApp) }
            .onChange(of: theme.isDark) { _, _ in applyWindowBackground(theme.bgApp) }
            .alert("KnotQ", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { showing in
                    if !showing {
                        model.errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    model.errorMessage = nil
                }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .background(theme.bgApp.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.24)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.24)) { keyboardVisible = false }
        }
        .sheet(item: $addItemTarget) { target in
            Group {
                switch target {
                case .scheme(let id):
                    AddItemSheet(schemeID: id)
                case .todayDaily:
                    AddItemSheet(todayDaily: true)
                }
            }
            .presentationDetents([.fraction(0.50)])
        }
        .sheet(item: $eventEditor) { target in
            EventEditorSheet(theme: theme, target: target)
                .presentationDetents([.fraction(0.50)])
        }
        .sheet(isPresented: $showingCalendarAdd) {
            AddCalendarItemSheet()
                .presentationDetents([.fraction(0.50)])
        }
        .sheet(isPresented: $showingMonthView) {
            MonthGridView(theme: theme, initialDate: model.selectedDate) { date in
                model.selectedDate = date
                model.weekOffset = 0
                model.refresh()
                showingMonthView = false
            }
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingNewFolder) {
            NameSheet(title: "New Folder", placeholder: "Folder name", validator: { name in
                WorkspaceNameValidation.folderError(name, root: model.snapshot?.root)
            }) { name in
                model.createFolder(name: name)
                pane = .home
            }
            .presentationDetents([.height(220)])
        }
        .confirmationDialog("Recurring Task", isPresented: Binding(
            get: { pendingOccurrenceMove != nil },
            set: { showing in
                if !showing { cancelPendingOccurrenceMove() }
            }
        ), titleVisibility: .visible) {
            Button(EventOccurrenceScope.thisEvent.label) {
                applyPendingOccurrenceMove(scope: .thisEvent)
            }
            Button(EventOccurrenceScope.allFuture.label) {
                applyPendingOccurrenceMove(scope: .allFuture)
            }
            Button(EventOccurrenceScope.allEvents.label) {
                applyPendingOccurrenceMove(scope: .allEvents)
            }
            Button("Cancel", role: .cancel) { cancelPendingOccurrenceMove() }
        } message: {
            Text("Which tasks should this move apply to?")
        }
        .onAppear { model.ensureTodayDailyQueue() }
    }

    // MARK: - iPhone (compact) root

    @ViewBuilder
    private func iPhoneRoot() -> some View {
        mainPane(wide: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if !keyboardVisible && homeNavigationDepth == 0 {
                    // Floating liquid-glass nav. It hovers over the content
                    // rather than reserving a strip.
                    MobileDock(
                        selected: (pane == .scheme || pane == .daily || pane == .search) ? .home : pane,
                        theme: theme,
                        onSelect: { selected in
                            // Re-tapping Calendar while already there jumps back
                            // to today (there's no nav bar to do it otherwise).
                            if selected == .calendar, pane == .calendar,
                               AppModel.dateOnly(model.selectedDate) != AppModel.dateOnly(Date()) {
                                model.selectedDate = Date()
                                model.weekOffset = 0
                                model.refresh()
                            }
                            pane = selected
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    // MARK: - iPad (regular) root — native NavigationSplitView

    @ViewBuilder
    private func iPadRoot() -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IPadSidebar(
                root: model.snapshot?.root,
                selection: sidebarSelectionBinding,
                selectedSchemeID: pane == .scheme ? selectedSchemeID : nil,
                theme: theme,
                onSelectScheme: selectScheme,
                onNewScheme: quickCreateScheme,
                onNewFolder: { showingNewFolder = true },
                onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 340)
            .navigationTitle("KnotQ")
        } detail: {
            NavigationStack {
                iPadDetail()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Maps the existing `pane`/`selectedSchemeID` state to/from the sidebar's
    /// selection so native rows highlight and selecting drives the detail.
    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: {
                switch pane {
                case .home: return .home
                case .calendar: return .calendar
                case .daily: return .daily
                case .settings: return .settings
                case .scheme: return selectedSchemeID.map(SidebarItem.scheme)
                case .search: return nil
                }
            },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .home: returnHome()
                case .calendar: selectedSchemeID = nil; pane = .calendar
                case .daily: openDaily()
                case .settings: selectedSchemeID = nil; pane = .settings
                case .scheme(let id): selectScheme(id)
                }
            }
        )
    }

    @ViewBuilder
    private func iPadDetail() -> some View {
        switch pane {
        case .home:
            HomeDashboardPane(
                snapshot: model.snapshot,
                selectedDate: model.selectedDate,
                theme: theme,
                onOpenDaily: openDaily,
                onOpenScheme: selectScheme,
                onToggleOccurrence: handleOccurrenceTap,
                onOpenOccurrence: { eventEditor = .edit($0) },
                onNewScheme: quickCreateScheme,
                onNewFolder: { showingNewFolder = true },
                onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) }
            )
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    searchToolbarButton
                    upcomingToggleButton
                }
            }
            .inspector(isPresented: $showingUpcoming) { upcomingInspector }
        case .calendar:
            DayTimelinePane(
                calendar: model.snapshot?.calendar,
                selectedDate: model.selectedDate,
                theme: theme,
                timeFormat: currentTimeFormat,
                onSetDate: { date in
                    model.selectedDate = date
                    model.weekOffset = 0
                    model.refresh()
                },
                onCreate: { date in eventEditor = .create(date) },
                onOpenOccurrence: { occ in eventEditor = .edit(occ) },
                onMoveOccurrence: moveOccurrence,
                onTapTitle: { showingMonthView = true },
                isCreatingEvent: isCreatingEventDraft,
                resetToken: timelineResetToken,
                preferredVisibleDays: 5
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingCalendarAdd = true } label: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    searchToolbarButton
                    upcomingToggleButton
                }
            }
            .inspector(isPresented: $showingUpcoming) { upcomingInspector }
        case .scheme:
            if let selectedScheme {
                IntegratedSchemeEditorPane(
                    scheme: selectedScheme,
                    theme: theme,
                    onBack: nil,
                    onAdd: { addItemTarget = .scheme(selectedScheme.id) },
                    usesNativeNavigation: true,
                    showsEditorNavigation: true,
                    autoFocusTitleOnAppear: titleFocusSchemeID == selectedScheme.id,
                    onAutoFocusTitleConsumed: { consumeTitleFocus(for: selectedScheme.id) }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { addItemTarget = .scheme(selectedScheme.id) } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(selectedScheme.isReadOnly)
                    }
                }
            } else {
                EmptyState(title: "Pick a scheme", detail: "Choose a scheme from the sidebar.", theme: theme)
            }
        case .daily:
            DailyFeedPane(
                entries: model.snapshot?.daily ?? [],
                selectedDate: model.selectedDate,
                theme: theme,
                onPrevious: { selectDailyDate(Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                onNext: { selectDailyDate(Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                onDate: selectDailyDate,
                onBack: {},
                onAdd: { addItemTarget = .todayDaily },
                usesNativeNavigation: true
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addItemTarget = .todayDaily } label: { Image(systemName: "plus") }
                }
            }
        case .settings:
            SettingsForm(theme: theme)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        case .search:
            IPadSearchDetail(theme: theme, onOpenScheme: selectScheme)
        }
    }

    private var upcomingInspector: some View {
        DesktopUpcomingRail(
            calendar: model.snapshot?.calendar,
            theme: theme,
            timeFormat: currentTimeFormat,
            onToggleOccurrence: handleOccurrenceTap,
            onOpenOccurrence: { eventEditor = .edit($0) }
        )
        .inspectorColumnWidth(min: 240, ideal: 282, max: 360)
    }

    private var upcomingToggleButton: some View {
        Button { showingUpcoming.toggle() } label: {
            Image(systemName: "sidebar.right")
        }
    }

    private var searchToolbarButton: some View {
        Button { pane = .search } label: {
            Image(systemName: "magnifyingglass")
        }
    }

    @ViewBuilder
    private func mainPane(wide: Bool) -> some View {
        switch pane {
        case .home:
            if wide {
                HomeDashboardPane(
                    snapshot: model.snapshot,
                    selectedDate: model.selectedDate,
                    theme: theme,
                    onOpenDaily: openDaily,
                    onOpenScheme: selectScheme,
                    onToggleOccurrence: handleOccurrenceTap,
                    onOpenOccurrence: { eventEditor = .edit($0) },
                    onNewScheme: quickCreateScheme,
                    onNewFolder: { showingNewFolder = true },
                    onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) }
                )
            } else {
                HomeNavigationPane(
                    snapshot: model.snapshot,
                    selectedDate: model.selectedDate,
                    theme: theme,
                    onToggleOccurrence: handleOccurrenceTap,
                    onOpenOccurrence: { eventEditor = .edit($0) },
                    onOpenCalendar: { pane = .calendar },
                    onCreateScheme: quickCreateSchemeID,
                    onNewFolder: { showingNewFolder = true },
                    onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) },
                    onAddItem: queueAddItem,
                    onPrepareDaily: prepareDaily,
                    onSelectDailyDate: selectDailyDate,
                    titleFocusSchemeID: $titleFocusSchemeID,
                    navigationDepth: $homeNavigationDepth
                )
            }
        case .calendar:
            // Same hour-grid timeline on every size; the iPad just shows more
            // active days (5) alongside the sidebar and upcoming rail.
            DayTimelinePane(
                calendar: model.snapshot?.calendar,
                selectedDate: model.selectedDate,
                theme: theme,
                timeFormat: currentTimeFormat,
                onSetDate: { date in
                    model.selectedDate = date
                    model.weekOffset = 0
                    model.refresh()
                },
                onCreate: { date in eventEditor = .create(date) },
                onOpenOccurrence: { occ in eventEditor = .edit(occ) },
                onMoveOccurrence: moveOccurrence,
                onTapTitle: { showingMonthView = true },
                isCreatingEvent: isCreatingEventDraft,
                resetToken: timelineResetToken,
                preferredVisibleDays: wide ? 5 : nil
            )
            // Extend the timeline to the screen's bottom edge so it scrolls
            // all the way down with no leftover safe-area lip.
            .ignoresSafeArea(.container, edges: .bottom)
        case .scheme:
            if let selectedScheme {
                DesktopSchemePane(
                    scheme: selectedScheme,
                    theme: theme,
                    onBack: returnHome,
                    onAdd: { addItemTarget = .scheme(selectedScheme.id) },
                    autoFocusTitle: titleFocusSchemeID == selectedScheme.id,
                    onTitleFocusConsumed: { consumeTitleFocus(for: selectedScheme.id) }
                )
            } else {
                EmptyState(title: "Pick a scheme", detail: "Choose a scheme from Home.", theme: theme)
            }
        case .daily:
            DailyFeedPane(
                entries: model.snapshot?.daily ?? [],
                selectedDate: model.selectedDate,
                theme: theme,
                onPrevious: { selectDailyDate(Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                onNext: { selectDailyDate(Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                onDate: selectDailyDate,
                onBack: returnHome,
                onAdd: { addItemTarget = .todayDaily }
            )
        case .search:
            DesktopSearchPane(theme: theme, keyboardVisible: keyboardVisible, onOpenScheme: selectScheme)
        case .settings:
            DesktopSettingsPane(theme: theme)
        }
    }

    private var currentTimeFormat: String {
        model.snapshot?.settings.timeFormat ?? "twelve_hour"
    }

    /// True while the new-task editor popover is open, so the calendar keeps
    /// its create-draft block visible until the popover is dismissed.
    private var isCreatingEventDraft: Bool {
        if case .create = eventEditor { return true }
        return false
    }

    private func openDaily() {
        prepareDaily()
        pane = .daily
    }

    private func prepareDaily() {
        model.ensureTodayDailyQueue()
        selectedSchemeID = nil
    }

    private func queueAddItem(for schemeID: String) {
        if model.snapshot?.daily.contains(where: { $0.scheme.id == schemeID }) == true {
            addItemTarget = .todayDaily
        } else {
            addItemTarget = .scheme(schemeID)
        }
    }

    private func selectScheme(_ id: String) {
        selectedSchemeID = id
        pane = .scheme
    }

    private func returnHome() {
        selectedSchemeID = nil
        pane = .home
    }

    private func quickCreateSchemeID() -> String? {
        let name = nextUntitledSchemeName()
        guard let id = model.createScheme(name: name) else {
            return nil
        }
        titleFocusSchemeID = id
        return id
    }

    private func quickCreateScheme() {
        guard let id = quickCreateSchemeID() else {
            pane = .home
            return
        }
        selectScheme(id)
    }

    private func consumeTitleFocus(for id: String) {
        if titleFocusSchemeID == id {
            titleFocusSchemeID = nil
        }
    }

    private func nextUntitledSchemeName() -> String {
        let base = "Untitled"
        if WorkspaceNameValidation.schemeError(base, root: model.snapshot?.root) == nil {
            return base
        }
        for index in 2..<10_000 {
            let candidate = "\(base) \(index)"
            if WorkspaceNameValidation.schemeError(candidate, root: model.snapshot?.root) == nil {
                return candidate
            }
        }
        return "\(base) \(Int(Date().timeIntervalSince1970))"
    }

    private func selectDailyDate(_ date: Date) {
        let newKey = AppModel.dateOnly(date)
        let currentKey = AppModel.dateOnly(model.selectedDate)
        if newKey != currentKey {
            model.selectDate(date)
        }
    }

    private func moveOccurrence(_ occurrence: MobileOccurrence, start: Date?, end: Date?) {
        guard !occurrence.isReadOnly else { return }
        guard let moveDates = normalizedMoveDates(for: occurrence, start: start, end: end) else { return }
        if occurrence.isRecurring {
            pendingOccurrenceMove = PendingOccurrenceMove(
                occurrence: occurrence,
                start: moveDates.start,
                end: moveDates.end
            )
        } else {
            applyOccurrenceMove(occurrence, start: moveDates.start, end: moveDates.end, scope: .allEvents)
        }
    }

    private func normalizedMoveDates(for occurrence: MobileOccurrence, start: Date?, end: Date?) -> (start: Date?, end: Date?)? {
        if occurrence.kind == "assignment" {
            return (nil, end)
        }
        if occurrence.kind == "reminder" {
            return (start, nil)
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    private func applyPendingOccurrenceMove(scope: EventOccurrenceScope) {
        guard let pending = pendingOccurrenceMove else { return }
        pendingOccurrenceMove = nil
        applyOccurrenceMove(pending.occurrence, start: pending.start, end: pending.end, scope: scope)
    }

    private func cancelPendingOccurrenceMove() {
        guard pendingOccurrenceMove != nil else { return }
        pendingOccurrenceMove = nil
        timelineResetToken += 1
    }

    private func applyOccurrenceMove(_ occurrence: MobileOccurrence, start: Date?, end: Date?, scope: EventOccurrenceScope) {
        model.commitEventEdit(
            occurrence: occurrence,
            title: occurrence.title,
            start: start,
            end: end,
            rrule: occurrence.repeatRule,
            notificationOffsetSecs: occurrence.notificationOffsetSecs,
            notificationDirty: false,
            done: occurrence.done,
            scope: scope
        )
    }

    private func handleOccurrenceTap(_ occurrence: MobileOccurrence) {
        if occurrence.isReadOnly {
            eventEditor = .edit(occurrence)
        } else {
            model.toggleOccurrence(occurrence)
        }
    }

    private func startGoogleCalendarImport(parentID: String? = nil) {
        Task {
            await model.connectGoogleCalendar(parentID: parentID)
        }
    }

}
