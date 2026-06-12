import SwiftUI
import UIKit

private struct NavigationStackInteractivePopEnabler: UIViewControllerRepresentable {
    let enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled)
    }

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: HostController, context: Context) {
        context.coordinator.enabled = enabled
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

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        private weak var navigationController: UINavigationController?
        private weak var configuredGesture: UIGestureRecognizer?
        private weak var originalDelegate: UIGestureRecognizerDelegate?

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func configure(from controller: UIViewController) {
            guard let navigationController = controller.navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if configuredGesture !== gesture {
                restoreIfNeeded()
                configuredGesture = gesture
                originalDelegate = gesture.delegate
            }
            self.navigationController = navigationController
            gesture.isEnabled = enabled
            gesture.delegate = self
        }

        func restoreIfNeeded() {
            guard let gesture = configuredGesture else { return }
            if gesture.delegate === self {
                gesture.delegate = originalDelegate
            }
            configuredGesture = nil
            originalDelegate = nil
            navigationController = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled,
                  let navigationController,
                  navigationController.viewControllers.count > 1 else {
                return false
            }
            return navigationController.transitionCoordinator?.isAnimated != true
        }
    }
}

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

    @State private var schemePreviewLayout: SchemePreviewLayout?

    var body: some View {
        GeometryReader { proxy in
            let schemePreviewMaxHeight = schemePreviewLayout?.height ?? Self.schemePreviewHeight(for: proxy.size)
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
                        .onboardingTarget(.upcoming)
                        // Dock clearance lives outside the spotlight target so the
                        // highlight hugs the list instead of 180pt of empty space.
                        .padding(.bottom, 180)
                    }
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
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
            .onAppear {
                updateSchemePreviewLayout(for: proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                updateSchemePreviewLayout(for: size)
            }
        }
        // Fill the bottom safe-area lip so content scrolls to the screen edge.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private struct SchemePreviewLayout {
        let containerSize: CGSize
        let height: CGFloat
    }

    private static func schemePreviewHeight(for size: CGSize) -> CGFloat {
        max(180, size.height * 0.34).rounded()
    }

    private func updateSchemePreviewLayout(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let schemePreviewLayout,
           abs(schemePreviewLayout.containerSize.width - size.width) <= 48,
           abs(schemePreviewLayout.containerSize.height - size.height) <= 120 {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            schemePreviewLayout = SchemePreviewLayout(
                containerSize: size,
                height: Self.schemePreviewHeight(for: size)
            )
        }
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
    let onOpenCalendar: () -> Void
    let onCreateScheme: () async -> String?
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void
    let onAddItem: (String) -> Void
    let onPrepareDaily: () -> Void
    let onSelectDailyDate: @MainActor (Date) -> Void
    @Binding var titleFocusSchemeID: String?
    @Binding var navigationDepth: Int
    @State private var path: [HomeRoute] = []
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                HomeInlineSearchField(query: $searchQuery, theme: theme)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                Group {
                    if isSearching {
                        HomeSearchResultsPane(
                            hits: model.searchHits,
                            query: trimmedSearchQuery,
                            theme: theme,
                            onOpenHit: openSearchHit
                        )
                    } else {
                        HomeDashboardPane(
                            snapshot: snapshot,
                            selectedDate: selectedDate,
                            theme: theme,
                            onOpenDaily: openDailyInStack,
                            onOpenScheme: openSchemeInStack,
                            onToggleOccurrence: onToggleOccurrence,
                            onOpenOccurrence: onOpenOccurrence,
                            onNewScheme: createSchemeInStack,
                            onNewFolder: onNewFolder,
                            onGoogleCalendar: onGoogleCalendar
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.bgApp)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onSubmit(of: .search) {
                updateSearchResults(for: searchQuery)
            }
            .onChange(of: searchQuery) { _, value in
                updateSearchResults(for: value)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .scheme(let id):
                    if let scheme = model.scheme(id: id) {
                        IntegratedSchemeEditorPane(
                            scheme: scheme,
                            theme: theme,
                            onBack: { popHomeRoute() },
                            onAdd: { onAddItem(scheme.id) },
                            usesNativeNavigation: true,
                            showsEditorNavigation: true,
                            transparentOverlayNavigation: true,
                            autoFocusOnAppear: titleFocusSchemeID != scheme.id,
                            autoFocusTitleOnAppear: titleFocusSchemeID == scheme.id,
                            onAutoFocusTitleConsumed: { consumeTitleFocus(for: scheme.id) }
                        )
                        .toolbar(.hidden, for: .navigationBar)
                        .background {
                            NavigationStackInteractivePopEnabler(enabled: true)
                        }
                    } else {
                        EmptyState(title: "Scheme missing", detail: "It may have been archived or deleted.", theme: theme)
                            .toolbar(.visible, for: .navigationBar)
                    }
                case .daily:
                    DailyFeedPane(
                        entries: model.snapshot?.daily ?? [],
                        selectedDate: model.selectedDate,
                        theme: theme,
                        onPrevious: { model.selectDate(Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                        onNext: { model.selectDate(Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                        onDate: onSelectDailyDate,
                        onLoadOlder: { oldestDate in
                            model.loadOlderDailyEntries(from: oldestDate)
                        },
                        loadAnchorDate: model.dailyHistoryLoadAnchorDate,
                        onLoadAnchorRestored: {
                            model.clearDailyHistoryLoadAnchor()
                        },
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

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchQuery.isEmpty
    }

    private func updateSearchResults(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            model.searchHits = []
        } else {
            model.search(query)
        }
    }

    private func consumeTitleFocus(for id: String) {
        if titleFocusSchemeID == id {
            titleFocusSchemeID = nil
        }
    }

    private func createSchemeInStack() {
        Task {
            guard let id = await onCreateScheme() else { return }
            openSchemeInStack(id)
        }
    }

    private func openSchemeInStack(_ id: String) {
        closeHomeSearch()
        path.append(.scheme(id))
    }

    private func openDailyInStack() {
        closeHomeSearch()
        onPrepareDaily()
        path.append(.daily)
    }

    private func closeHomeSearch() {
        searchQuery = ""
        model.searchHits = []
    }

    private func popHomeRoute() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func openSearchHit(_ hit: MobileSearchHit) {
        if hit.targetKind == "calendar" {
            closeHomeSearch()
            onOpenCalendar()
        } else if hit.targetKind == "daily_queue", hit.schemeId == nil {
            openDailyInStack()
        } else if let schemeID = hit.schemeId {
            openSchemeInStack(schemeID)
        }
    }
}

private struct HomeInlineSearchField: View {
    @Binding var query: String
    let theme: KnotQTheme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.textMuted)

            TextField("Search KnotQ", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .focused($focused)

            if !query.isEmpty {
                Button {
                    query = ""
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.buttonBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.borderOverlay.opacity(theme.isDark ? 0.35 : 0.55), lineWidth: 1)
        }
    }
}

struct HomeSearchResultsPane: View {
    let hits: [MobileSearchHit]
    let query: String
    let theme: KnotQTheme
    let onOpenHit: (MobileSearchHit) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if hits.isEmpty {
                    EmptyState(
                        title: "No Results",
                        detail: "Nothing matches \"\(query)\".",
                        theme: theme
                    )
                    .padding(.top, 56)
                } else {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { idx, hit in
                        Button {
                            onOpenHit(hit)
                        } label: {
                            HomeSearchHitRow(hit: hit, theme: theme, striped: idx % 2 == 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.bottom, 180)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bgApp)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

struct HomeSearchHitRow: View {
    let hit: MobileSearchHit
    let theme: KnotQTheme
    let striped: Bool

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(searchHitColor(hit, dark: theme.isDark))
                .frame(width: 2)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(hit.schemeName.isEmpty ? hit.targetKind.capitalized : hit.schemeName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(searchHitColor(hit, dark: theme.isDark))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(hit.detail)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textSoft)
                        .lineLimit(1)
                }

                Text(hit.title)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 8)
        }
        .background(striped ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
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
