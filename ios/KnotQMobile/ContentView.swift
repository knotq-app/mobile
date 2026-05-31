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

private struct SheetID: Identifiable {
    let id: String
}

enum HomeRoute: Hashable {
    case scheme(String)
    case daily
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: MobilePane = .home
    @State private var selectedSchemeID: String?
    @State private var addItemTarget: SheetID?
    @State private var showingCalendarAdd = false
    @State private var showingMonthView = false
    @State private var showingNewFolder = false
    @State private var eventEditor: EventEditorTarget?
    @State private var keyboardVisible = false
    @State private var titleFocusSchemeID: String?
    @State private var homeNavigationDepth = 0

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
            VStack(spacing: 0) {
                if wide {
                    DesktopTitleBar(
                        title: title,
                        pane: pane,
                        scheme: selectedScheme,
                        theme: theme,
                        onSearch: { pane = .search },
                        onAddCalendar: { showingCalendarAdd = true },
                        onAddItem: {
                            if pane == .daily, let daily = currentDailyScheme {
                                addItemTarget = SheetID(id: daily.id)
                            } else if let selectedSchemeID {
                                addItemTarget = SheetID(id: selectedSchemeID)
                            }
                        },
                        onNewScheme: quickCreateScheme,
                        onNewFolder: { showingNewFolder = true },
                        onGoogleCalendar: { startGoogleCalendarImport() },
                        onSettings: { pane = .settings }
                    )
                }

                HStack(spacing: 0) {
                    if wide {
                        DesktopNavigator(
                            root: model.snapshot?.root,
                            selectedPane: pane,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme,
                            onSelectPane: { pane = $0 },
                            onSelectScheme: selectScheme,
                            onNewScheme: quickCreateScheme,
                            onNewFolder: { showingNewFolder = true },
                            onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) }
                        )
                        .frame(width: 168)
                        .padding(.leading, 6)
                        .padding(.vertical, 6)

                        if pane != .home {
                        DesktopUpcomingRail(
                            calendar: model.snapshot?.calendar,
                            theme: theme,
                            timeFormat: currentTimeFormat,
                            onToggleOccurrence: handleOccurrenceTap,
                            onOpenOccurrence: { eventEditor = .edit($0) }
                        )
                            .frame(width: 258)
                        }
                    }

                    Rectangle()
                        .fill(theme.dividerTiny)
                        .frame(width: wide ? 1 : 0)

                    mainPane(wide: wide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if !wide && !keyboardVisible && homeNavigationDepth == 0 {
                    // Floating liquid-glass nav. It hovers over the content
                    // rather than reserving a strip.
                    MobileDock(
                        selected: (pane == .scheme || pane == .daily) ? .home : pane,
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
                }
            }
            .background(theme.bgApp.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .preferredColorScheme(theme.isDark ? .dark : .light)
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .sheet(item: $addItemTarget) { target in
            AddItemSheet(schemeID: target.id)
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
        .onAppear { model.ensureDailyQueue(date: model.selectedDate) }
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
                    onCreateScheme: quickCreateSchemeID,
                    onNewFolder: { showingNewFolder = true },
                    onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) },
                    onAddItem: { addItemTarget = SheetID(id: $0) },
                    onPrepareDaily: prepareDaily,
                    onSelectDailyDate: selectDailyDate,
                    titleFocusSchemeID: $titleFocusSchemeID,
                    navigationDepth: $homeNavigationDepth
                )
            }
        case .calendar:
            if wide {
                DesktopCalendarPane(
                    calendar: model.snapshot?.calendar,
                    theme: theme,
                    wide: wide,
                    onPrevious: { model.weekOffset -= 1; model.refresh() },
                    onNext: { model.weekOffset += 1; model.refresh() },
                    onToday: {
                        model.weekOffset = 0
                        model.selectedDate = Date()
                        model.refresh()
                    },
                    onAdd: { showingCalendarAdd = true },
                    timeFormat: currentTimeFormat,
                    onOpenScheme: selectScheme
                )
            } else {
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
                    isCreatingEvent: isCreatingEventDraft
                )
            }
        case .scheme:
            if let selectedScheme {
                DesktopSchemePane(
                    scheme: selectedScheme,
                    theme: theme,
                    onBack: returnHome,
                    onAdd: { addItemTarget = SheetID(id: selectedScheme.id) },
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
                onPrevious: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                onNext: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                onDate: selectDailyDate,
                onBack: returnHome,
                onAdd: {
                    if let daily = currentDailyScheme {
                        addItemTarget = SheetID(id: daily.id)
                    }
                }
            )
        case .search:
            DesktopSearchPane(theme: theme, onOpenScheme: selectScheme)
        case .settings:
            DesktopSettingsPane(theme: theme)
        }
    }

    private var currentDailyScheme: MobileScheme? {
        model.snapshot?.daily.first { $0.date == AppModel.dateOnly(model.selectedDate) }?.scheme
    }

    private var currentTimeFormat: String {
        model.snapshot?.settings.timeFormat ?? "twelve_hour"
    }

    /// True while the new-event editor popover is open, so the calendar keeps
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
        model.ensureDailyQueue(date: model.selectedDate)
        selectedSchemeID = nil
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
        if newKey != currentKey || currentDailyScheme == nil {
            model.ensureDailyQueue(date: date)
        }
    }

    private func moveOccurrence(_ occurrence: MobileOccurrence, start: Date?, end: Date?) {
        guard !occurrence.isReadOnly else { return }
        if occurrence.kind == "assignment" {
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "end", date: end)
            return
        }
        if occurrence.kind == "reminder" {
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "start", date: start)
            return
        }
        guard let start, let end else { return }
        let oldStart = MobileDate.parseDateTime(occurrence.start)
        if oldStart.map({ start > $0 }) == true {
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "end", date: end)
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "start", date: start)
        } else {
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "start", date: start)
            model.setItemDate(schemeID: occurrence.schemeId, itemID: occurrence.itemId, kind: "end", date: end)
        }
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
