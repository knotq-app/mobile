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
    case calendar
    case daily
    case settings
    case scheme(String)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: MobilePane = UIDevice.current.userInterfaceIdiom == .pad ? .calendar : .home
    @State private var selectedSchemeID: String?
    /// Pushed submenu stack for the iPad detail column (e.g. Archive). Reset when
    /// the sidebar selection changes so picking a new item leaves the submenu.
    @State private var detailPath = NavigationPath()
    @State private var addItemTarget: AddItemTarget?
    @State private var showingMonthView = false
    @State private var showingNewFolder = false
    @State private var eventEditor: EventEditorTarget?
    @State private var pendingOccurrenceMove: PendingOccurrenceMove?
    @State private var keyboardVisible = false
    @State private var titleFocusSchemeID: String?
    @State private var iPadSearchQuery = ""
    @State private var homeNavigationDepth = 0
    @State private var timelineResetToken = 0
    @State private var appliedScreenshotRoute = false
    @AppStorage("knotq.mobile.onboardingCompleted.v1") private var onboardingCompleted = false
    // Start with the short tutorial; the sign-in / stay-local prompt follows it
    // (see `OnboardingOverlay`). Already-signed-in users skip the prompt entirely.
    @State private var onboardingPhase: OnboardingPhase = .guide
    @State private var onboardingStep = 0
    // Last-open screen, restored on the next launch (see restoreLastScreenIfNeeded).
    @AppStorage("knotq.mobile.lastPane.v1") private var storedPaneRaw = ""
    @AppStorage("knotq.mobile.lastSchemeID.v1") private var storedSchemeID = ""
    @State private var didRestoreLastScreen = false

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

    private var showOnboarding: Bool {
        !onboardingCompleted && model.snapshot != nil
    }

    /// Drives the app to the pane a tour step describes, so the spotlighted
    /// content matches what's behind the scrim (mirrors desktop, which navigates
    /// to each view rather than pointing at entry points).
    private func focusOnboardingPane(_ target: MobilePane?) {
        guard let target else { return }
        homeNavigationDepth = 0
        switch target {
        case .scheme:
            // Open a real scheme into the editor; fall back to Home when the
            // workspace has none yet (mirrors desktop's union fallback).
            if let id = firstRegularSchemeID {
                selectScheme(id)
            } else {
                returnHome()
            }
        case .home where isPadLayout:
            pane = .calendar
        case .daily:
            openDaily()
        default:
            selectedSchemeID = nil
            pane = target
        }
    }

    /// First user-authored scheme (excludes Daily Queue and read-only imports),
    /// used to land the onboarding Schemes step on real content.
    private var firstRegularSchemeID: String? {
        model.snapshot?.schemes.first { !$0.isDailyQueue && !$0.isReadOnly }?.id
    }

    private func finishOnboarding() {
        homeNavigationDepth = 0
        pane = defaultHomePane
        withAnimation(.easeOut(duration: 0.2)) {
            onboardingCompleted = true
        }
        MobileNotificationScheduler.shared.requestAuthorizationIfNeeded()
    }

    private var title: String {
        return pane.title
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 760
            Group {
                if isPadLayout {
                    iPadRoot()
                } else {
                    iPhoneRoot(isWide: isWide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bgApp.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .onChange(of: isWide) { _, value in
                if !isPadLayout, !value, pane == .search {
                    pane = .home
                }
            }
            .onChange(of: iPadSearchQuery) { _, value in
                guard isPadLayout else { return }
                model.search(value.trimmingCharacters(in: .whitespacesAndNewlines))
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
                        model.dismissErrorMessage()
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    model.dismissErrorMessage()
                }
            } message: {
                Text(model.errorMessage ?? "")
            }
            // Spotlight onboarding lives in the app's own coordinate space (not a
            // cover) so it can ring the real dock / sidebar controls behind it.
            .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
                if showOnboarding {
                    GeometryReader { proxy in
                        OnboardingOverlay(
                            theme: theme,
                            size: proxy.size,
                            resolve: { target in anchors[target].map { proxy[$0] } },
                            phase: $onboardingPhase,
                            step: $onboardingStep,
                            onFocus: focusOnboardingPane,
                            onComplete: finishOnboarding
                        )
                        .environmentObject(model)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        .background(theme.bgApp.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.24)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.24)) { keyboardVisible = false }
        }
        // The browser sign-in sheet hosts its own keyboard in a separate window; its
        // keyboardWillHide can be lost when the sheet dismisses, leaving keyboardVisible
        // stuck true (which would hide the dock). Reconcile when the auth flow ends.
        .onChange(of: model.syncAuthInProgress) { _, inProgress in
            if !inProgress { keyboardVisible = false }
        }
        .adaptiveEditorPresentation(item: $addItemTarget, isPad: isPadLayout, detents: [.fraction(0.50)]) { target in
            switch target {
            case .scheme(let id):
                AddItemSheet(schemeID: id)
            case .todayDaily:
                AddItemSheet(todayDaily: true)
            }
        }
        .adaptiveEditorPresentation(item: $eventEditor, isPad: isPadLayout, detents: [.fraction(0.50)]) { target in
            EventEditorSheet(theme: theme, target: target)
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
                    pane = defaultHomePane
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
        .onAppear {
            model.ensureTodayDailyQueue()
            #if DEBUG
            applyScreenshotInitialRouteIfNeeded()
            #endif
        }
        // Restore the last-open screen once the workspace is available (so a saved
        // scheme can be validated), then persist navigation as it changes.
        .onChange(of: model.snapshot != nil, initial: true) { _, hasSnapshot in
            if hasSnapshot { restoreLastScreenIfNeeded() }
        }
        .onChange(of: pane) { _, newValue in
            guard didRestoreLastScreen else { return }
            storedPaneRaw = newValue.rawValue
        }
        .onChange(of: selectedSchemeID) { _, newValue in
            guard didRestoreLastScreen else { return }
            storedSchemeID = newValue ?? ""
        }
    }

    // MARK: - iPhone (compact) root

    @ViewBuilder
    private func iPhoneRoot(isWide: Bool) -> some View {
        ZStack(alignment: .bottom) {
            // Content keeps normal keyboard avoidance (e.g. the scheme editor scrolls its
            // caret above the keyboard).
            mainPane(wide: isWide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !keyboardVisible && homeNavigationDepth == 0 {
                // Floating liquid-glass nav. It hovers over the content rather than
                // reserving a strip.
                MobileDock(
                    selected: (pane == .scheme || pane == .daily || pane == .search) ? .home : pane,
                    theme: theme,
                    onSelect: { selected in
                        // Re-tapping Calendar while already there jumps back to today
                        // (there's no nav bar to do it otherwise).
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
                // The dock lives on its OWN full-screen layer that ignores the keyboard
                // safe area, so its bottom anchor is the real screen bottom (home
                // indicator) — NOT mainPane's keyboard-shrunk frame. This keeps it pinned
                // even when a stale keyboard inset lingers after the sign-in web-auth sheet
                // (whose keyboard is in a separate window) dismisses; previously the
                // bottom-anchored dock rendered pushed "way up" by that stale inset. The
                // dock is hidden while a keyboard is genuinely up, so ignoring it is safe.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - iPad (regular) root — native NavigationSplitView

    @ViewBuilder
    private func iPadRoot() -> some View {
        // Sidebar is permanent: pin both columns and drop the toggle so it
        // can't be collapsed (landscape-only iPad always has room for it).
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            IPadSidebar(
                root: model.snapshot?.root,
                selection: sidebarSelectionBinding,
                selectedSchemeID: pane == .scheme ? selectedSchemeID : nil,
                theme: theme,
                onSelectScheme: selectScheme,
                onNewScheme: quickCreateScheme,
                onNewFolder: { showingNewFolder = true },
                onGoogleCalendar: { startGoogleCalendarImport(parentID: $0) },
                searchQuery: $iPadSearchQuery,
                searchHits: model.searchHits,
                onSearch: {
                    iPadSearchQuery = iPadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.search(iPadSearchQuery)
                },
                onOpenSearchHit: { hit in
                    if let schemeID = hit.schemeId {
                        selectScheme(schemeID)
                    }
                }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 340)
            .navigationTitle("KnotQ")
        } detail: {
            HStack(spacing: 0) {
                // Separator right after the sidebar — shown for every detail view,
                // not just the calendar.
                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .bottom)

                NavigationStack(path: $detailPath) {
                    iPadDetail()
                        .toolbar(removing: .sidebarToggle)
                        .navigationDestination(for: SettingsRoute.self) { route in
                            settingsRouteDestination(route)
                        }
                }
                // Picking any sidebar item resets the pushed submenu (e.g. Archive)
                // so the detail shows that item's root instead of staying stuck.
                .onChange(of: pane) { _, _ in detailPath = NavigationPath() }
                .onChange(of: selectedSchemeID) { _, _ in detailPath = NavigationPath() }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func settingsRouteDestination(_ route: SettingsRoute) -> some View {
        switch route {
        case .archive:
            SettingsArchiveList(theme: theme)
        }
    }

    private var ipadActivePane: MobilePane {
        guard isPadLayout else { return pane }
        if pane == .home && screenshotHomeRouteRequested {
            return .home
        }
        switch pane {
        case .home, .search:
            return .calendar
        default:
            return pane
        }
    }

    /// Maps the existing `pane`/`selectedSchemeID` state to/from the sidebar's
    /// selection so native rows highlight and selecting drives the detail.
    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: {
                switch pane {
                    case .home, .search: return .calendar
                    case .calendar: return .calendar
                    case .daily: return .daily
                    case .settings: return .settings
                    case .scheme: return selectedSchemeID.map(SidebarItem.scheme)
                }
            },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
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
        switch ipadActivePane {
        case .home where screenshotHomeRouteRequested:
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
        case .calendar, .home, .search:
            // Upcoming rail between the sidebar and the timeline, mirroring the
            // desktop calendar's upcoming panel. It eats some width, so the
            // timeline shows a few fewer days.
            HStack(spacing: 0) {
                DesktopUpcomingRail(
                    calendar: model.snapshot?.calendar,
                    theme: theme,
                    timeFormat: currentTimeFormat,
                    onToggleOccurrence: handleOccurrenceTap,
                    onOpenOccurrence: { eventEditor = .edit($0) }
                )
                .frame(width: 248)
                .ignoresSafeArea(.container, edges: .bottom)

                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .bottom)

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
                    preferredVisibleDays: 4
                )
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // The timeline carries its own month-title header, so the empty
            // nav bar was pure dead space at the top — hide it so the calendar
            // sits flush under the safe area.
            .toolbar(.hidden, for: .navigationBar)
            .onboardingTarget(.calendar)
        case .scheme:
            if let selectedScheme {
                IntegratedSchemeEditorPane(
                    scheme: selectedScheme,
                    theme: theme,
                    onBack: returnHome,
                    onAdd: { addItemTarget = .scheme(selectedScheme.id) },
                    usesNativeNavigation: true,
                    showsEditorNavigation: true,
                    autoFocusTitleOnAppear: titleFocusSchemeID == selectedScheme.id,
                    onAutoFocusTitleConsumed: { consumeTitleFocus(for: selectedScheme.id) }
                )
                .onboardingTarget(.scheme)
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
                onLoadOlder: { oldestDate in
                    model.loadOlderDailyEntries(from: oldestDate)
                },
                isLoadingOlder: model.dailyHistoryLoadInProgress,
                canLoadOlder: model.canLoadOlderDailyHistory,
                loadAnchorDate: model.dailyHistoryLoadAnchorDate,
                onLoadAnchorRestored: {
                    model.clearDailyHistoryLoadAnchor()
                },
                onBack: {},
                onAdd: { addItemTarget = .todayDaily },
                usesNativeNavigation: true,
                autoFocusSelectedDay: false
            )
            // No in-pane header here, so drop the empty nav bar and let the
            // daily content rise to the top (the sidebar's Daily row gives
            // context). Mirrors the calendar pane.
            .toolbar(.hidden, for: .navigationBar)
            .onboardingTarget(.daily)
        case .settings:
            SettingsForm(theme: theme)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
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
            .onboardingTarget(.calendar)
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
                .onboardingTarget(.scheme)
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
                onLoadOlder: { oldestDate in
                    model.loadOlderDailyEntries(from: oldestDate)
                },
                isLoadingOlder: model.dailyHistoryLoadInProgress,
                canLoadOlder: model.canLoadOlderDailyHistory,
                loadAnchorDate: model.dailyHistoryLoadAnchorDate,
                onLoadAnchorRestored: {
                    model.clearDailyHistoryLoadAnchor()
                },
                onBack: returnHome,
                onAdd: { addItemTarget = .todayDaily },
                autoFocusSelectedDay: !screenshotDailyRouteRequested
            )
            .onboardingTarget(.daily)
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

    #if DEBUG
    private func applyScreenshotInitialRouteIfNeeded() {
        guard !appliedScreenshotRoute, AppModel.screenshotFixtureRequested else { return }
        appliedScreenshotRoute = true

        switch screenshotInitialRoute {
        case "home":
            selectedSchemeID = nil
            pane = .home
        case "calendar", nil:
            selectedSchemeID = nil
            pane = .calendar
        case "scheme":
            if let id = model.snapshot?.schemes.first(where: { $0.name == "Semester Plan" })?.id
                ?? firstRegularSchemeID {
                selectScheme(id)
            }
        case "daily":
            openDaily()
        default:
            break
        }
    }

    private var screenshotInitialRoute: String? {
        let process = ProcessInfo.processInfo
        let args = process.arguments
        if args.contains("--knotq-screenshot-home") { return "home" }
        if args.contains("--knotq-screenshot-calendar") { return "calendar" }
        if args.contains("--knotq-screenshot-scheme") { return "scheme" }
        if args.contains("--knotq-screenshot-daily") { return "daily" }
        return process.environment["KNOTQ_SCREENSHOT_ROUTE"]?.lowercased()
    }
    #endif

    private var screenshotHomeRouteRequested: Bool {
        #if DEBUG
        AppModel.screenshotFixtureRequested && screenshotInitialRoute == "home"
        #else
        false
        #endif
    }

    private var screenshotDailyRouteRequested: Bool {
        #if DEBUG
        AppModel.screenshotFixtureRequested && screenshotInitialRoute == "daily"
        #else
        false
        #endif
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
        pane = defaultHomePane
    }

    /// Re-open the screen the user last had open. Runs once after the workspace
    /// loads so a saved scheme can be validated; if that scheme was deleted in
    /// the meantime we fall back to the home screen. First-launch onboarding and
    /// the screenshot harness drive their own routes, so we don't override them.
    private func restoreLastScreenIfNeeded() {
        guard !didRestoreLastScreen, let snapshot = model.snapshot else { return }
        didRestoreLastScreen = true

        guard onboardingCompleted else { return }
        #if DEBUG
        if AppModel.screenshotFixtureRequested { return }
        #endif

        guard let restored = MobilePane(rawValue: storedPaneRaw) else { return }
        switch restored {
        case .scheme:
            if !storedSchemeID.isEmpty,
               snapshot.schemes.contains(where: { $0.id == storedSchemeID }) {
                selectScheme(storedSchemeID)
            } else {
                returnHome()
            }
        case .daily:
            openDaily()
        case .search:
            // Search is a transient pane; land on home instead of restoring it.
            pane = defaultHomePane
        case .home, .calendar, .settings:
            selectedSchemeID = nil
            // `.home` isn't a destination in the iPad layout; use its default.
            pane = (isPadLayout && restored == .home) ? .calendar : restored
        }
    }

    private func quickCreateSchemeID() async -> String? {
        let name = nextUntitledSchemeName()
        guard let id = await model.createScheme(name: name) else {
            return nil
        }
        titleFocusSchemeID = id
        return id
    }

    private func quickCreateScheme() {
        Task {
            guard let id = await quickCreateSchemeID() else {
                pane = defaultHomePane
                return
            }
            selectScheme(id)
        }
    }

    private var isPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var defaultHomePane: MobilePane {
        isPadLayout ? .calendar : .home
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

private extension View {
    /// The create/edit forms present as a centered form sheet on iPad — covering
    /// roughly the middle of the screen — while iPhone keeps the half-height
    /// bottom sheet.
    @ViewBuilder
    func adaptiveEditorPresentation<Item: Identifiable, FormContent: View>(
        item: Binding<Item?>,
        isPad: Bool,
        detents: Set<PresentationDetent>,
        @ViewBuilder content: @escaping (Item) -> FormContent
    ) -> some View {
        if isPad {
            sheet(item: item, content: content)
        } else {
            sheet(item: item) { content($0).presentationDetents(detents) }
        }
    }
}
