import SwiftUI
import UIKit

private enum MobilePane: String, CaseIterable, Identifiable {
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

private enum HomeRoute: Hashable {
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
    @State private var showingNewFolder = false
    @State private var eventEditor: EventEditorTarget?
    @State private var keyboardVisible = false
    @State private var titleFocusSchemeID: String?
    @State private var homeNavigationDepth = 0

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
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
                            onNewFolder: { showingNewFolder = true }
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
            // Dark panes without a navigation bar can use a soft status-bar
            // shadow; in light mode it reads as an unintended drop shadow.
            .overlay(alignment: .top) {
                if theme.isDark && !wide && pane != .scheme && pane != .daily && pane != .settings && homeNavigationDepth == 0 && !keyboardVisible {
                    LinearGradient(
                        colors: [Color.black.opacity(0.30), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 10)
                    .allowsHitTesting(false)
                }
            }
            .background(theme.bgApp.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .preferredColorScheme(theme.isDark ? .dark : .light)
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
                    onNewFolder: { showingNewFolder = true }
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
                    onShiftDay: { delta in
                        let next = Calendar.current.date(byAdding: .day, value: delta, to: model.selectedDate) ?? model.selectedDate
                        model.selectedDate = next
                        model.weekOffset = 0
                        model.refresh()
                    },
                    onCreate: { date in eventEditor = .create(date) },
                    onOpenOccurrence: { occ in eventEditor = .edit(occ) },
                    onMoveOccurrence: moveOccurrence
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

}

struct KnotQTheme {
    let isDark: Bool
    let bgApp: Color
    let bgSidebar: Color
    let bgToolbar: Color
    let bgModal: Color
    let rowAlt: Color
    let rowHover: Color
    let rowSelected: Color
    let buttonBg: Color
    let divider: Color
    let dividerSoft: Color
    let dividerTiny: Color
    let borderOverlay: Color
    let textPrimary: Color
    let textDim: Color
    let textMuted: Color
    let textSoft: Color
    let textToday: Color
    let accent: Color
    let danger: Color

    static func resolve(mode: String?, systemScheme: ColorScheme) -> KnotQTheme {
        switch mode {
        case "light": .light
        case "system": systemScheme == .dark ? .dark : .light
        default: .dark
        }
    }

    // Apple Calendar-style dark: pure-black canvas, near-black raised surfaces,
    // bright text, red "today" accent.
    static let dark = KnotQTheme(
        isDark: true,
        bgApp: Color(hex: 0x000000),
        bgSidebar: Color(hex: 0x0b0b0c),
        bgToolbar: Color(hex: 0x161618),
        bgModal: Color(hex: 0x141416),
        rowAlt: Color.white.opacity(0.04),
        rowHover: Color.white.opacity(0.08),
        rowSelected: Color.white.opacity(0.14),
        buttonBg: Color.white.opacity(0.09),
        divider: Color.white.opacity(0.12),
        dividerSoft: Color.white.opacity(0.08),
        dividerTiny: Color.white.opacity(0.045),
        borderOverlay: Color.white.opacity(0.14),
        textPrimary: Color(hex: 0xf2f2f7),
        textDim: Color(hex: 0xb4bcc4).opacity(0.74),
        textMuted: Color(hex: 0x98a0aa).opacity(0.55),
        textSoft: Color(hex: 0xd2dae2).opacity(0.64),
        textToday: Color(hex: 0xff453a),
        accent: Color(hex: 0x7aa0ff),
        danger: Color(hex: 0xff453a)
    )

    static let light = KnotQTheme(
        isDark: false,
        bgApp: Color(hex: 0xe8e2d8),
        bgSidebar: Color(hex: 0xe0d8cc),
        bgToolbar: Color(hex: 0xe3dcd2),
        bgModal: Color(hex: 0xece6dd),
        rowAlt: Color(hex: 0x5a4635).opacity(0.047),
        rowHover: Color(hex: 0x5a4635).opacity(0.094),
        rowSelected: Color(hex: 0xe66f1f).opacity(0.102),
        buttonBg: Color(hex: 0x5a4635).opacity(0.094),
        divider: Color(hex: 0x5a4635).opacity(0.141),
        dividerSoft: Color(hex: 0x5a4635).opacity(0.094),
        dividerTiny: Color(hex: 0x5a4635).opacity(0.051),
        borderOverlay: Color(hex: 0x3d2a18).opacity(0.188),
        textPrimary: Color(hex: 0x2c2420),
        textDim: Color(hex: 0x302520).opacity(0.878),
        textMuted: Color(hex: 0x5a4a3c).opacity(0.753),
        textSoft: Color(hex: 0x382c22).opacity(0.847),
        textToday: Color(hex: 0xd04e1a),
        accent: Color(hex: 0xc04510),
        danger: Color(hex: 0xc72f24)
    )
}

private struct DesktopTitleBar: View {
    let title: String
    let pane: MobilePane
    let scheme: MobileScheme?
    let theme: KnotQTheme
    let onSearch: () -> Void
    let onAddCalendar: () -> Void
    let onAddItem: () -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(markerColor)
                .frame(width: 14, height: 14)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(TitleIconButton(theme: theme))

                Menu {
                    Button("Calendar Item", systemImage: "calendar.badge.plus", action: onAddCalendar)
                    Button("Item", systemImage: "plus", action: onAddItem)
                        .disabled(!(pane == .daily || (pane == .scheme && scheme?.isReadOnly != true)))
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(TitleIconButton(theme: theme))

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
        .background(theme.bgToolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }

    private var markerColor: Color {
        if let scheme, pane == .scheme {
            return schemeColor(scheme.colorIndex, dark: theme.isDark)
        }
        if pane == .daily {
            return theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad)
        }
        if pane == .home {
            return theme.accent
        }
        if pane == .calendar {
            return theme.textPrimary
        }
        return theme.textDim
    }
}

struct TitleIconButton: ButtonStyle {
    let theme: KnotQTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 25, height: 25)
            .background(configuration.isPressed ? theme.rowSelected : theme.buttonBg, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SyncSignInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme

    @State private var apiBase = "http://127.0.0.1:8787"
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                if let session = model.syncSession {
                    Section("Current account") {
                        LabeledContent("Email", value: session.email)
                        LabeledContent("Backend", value: session.apiBase)
                        Button("Sign out", role: .destructive) {
                            model.signOutSync()
                            password = ""
                        }
                    }
                }

                Section("Local sync backend") {
                    TextField("Sync API", text: $apiBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                    Button {
                        Task {
                            await model.signInToSync(apiBase: apiBase, email: email, password: password)
                            if model.syncSession != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        if model.syncAuthInProgress {
                            ProgressView()
                        } else {
                            Text("Sign in")
                        }
                    }
                    .disabled(model.syncAuthInProgress)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Sync account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                apiBase = model.syncSession?.apiBase ?? apiBase
                email = model.syncSession?.email ?? email
            }
        }
        .tint(theme.accent)
    }
}

private struct DesktopNavigator: View {
    let root: MobileNode?
    let selectedPane: MobilePane
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectPane: (MobilePane) -> Void
    let onSelectScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                NavigatorSpecialRow(title: "Home", color: theme.accent, selected: selectedPane == .home, theme: theme) {
                    onSelectPane(.home)
                }
                NavigatorSpecialRow(title: "Calendar", color: theme.textPrimary, selected: selectedPane == .calendar, theme: theme) {
                    onSelectPane(.calendar)
                }
                NavigatorSpecialRow(title: "Daily", color: theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad), selected: selectedPane == .daily, theme: theme) {
                    onSelectPane(.daily)
                }
            }
            .padding(.bottom, 7)

            Rectangle().fill(theme.divider).frame(height: 1).padding(.horizontal, 3).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let root {
                        ForEach(root.children) { node in
                            NavigatorNodeRow(
                                node: node,
                                depth: 0,
                                parentFolderID: root.id,
                                root: root,
                                selectedSchemeID: selectedSchemeID,
                                theme: theme,
                                onSelectScheme: onSelectScheme
                            )
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textDim)

                Button {
                    onSelectPane(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }
            .padding(.top, 5)
        }
        .padding(.top, 10)
        .padding(.horizontal, 7)
        .padding(.bottom, 8)
        .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(theme.borderOverlay, lineWidth: 1)
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.18 : 0.035), radius: theme.isDark ? 9 : 5, x: 0, y: theme.isDark ? 5 : 2)
    }
}

private struct NavigatorSpecialRow: View {
    let title: String
    let color: Color
    let selected: Bool
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 11, height: 11)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 25)
            .padding(.horizontal, 6)
            .foregroundStyle(theme.textPrimary)
            .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

private struct FolderDestination: Identifiable {
    let id: String
    let title: String
    let depth: Int
}

private struct MoveToFolderMenu: View {
    @EnvironmentObject private var model: AppModel
    let nodeKind: String
    let nodeID: String
    let currentParentID: String
    let root: MobileNode
    var excludingFolderID: String?

    private var destinations: [FolderDestination] {
        var values = [FolderDestination(id: root.id, title: "Home", depth: 0)]
        appendFolderDestinations(from: root.children, depth: 1, excludingFolderID: excludingFolderID, into: &values)
        return values
    }

    var body: some View {
        Menu {
            ForEach(destinations) { destination in
                Button {
                    model.moveNode(
                        kind: nodeKind,
                        id: nodeID,
                        folderID: destination.id,
                        position: childrenCount(for: destination.id)
                    )
                } label: {
                    Label(
                        String(repeating: "  ", count: destination.depth) + destination.title,
                        systemImage: destination.id == root.id ? "square.stack.3d.up" : "folder"
                    )
                }
                .disabled(destination.id == currentParentID)
            }
        } label: {
            Label("Move To Folder", systemImage: "folder")
        }
    }

    private func childrenCount(for folderID: String) -> Int {
        findNode(id: folderID, in: root)?.children.count ?? 0
    }
}

private func appendFolderDestinations(
    from nodes: [MobileNode],
    depth: Int,
    excludingFolderID: String?,
    into destinations: inout [FolderDestination]
) {
    for node in nodes where node.kind == "folder" {
        if node.id == excludingFolderID {
            continue
        }
        destinations.append(FolderDestination(id: node.id, title: node.name, depth: depth))
        appendFolderDestinations(from: node.children, depth: depth + 1, excludingFolderID: excludingFolderID, into: &destinations)
    }
}

private func findNode(id: String, in node: MobileNode) -> MobileNode? {
    if node.id == id {
        return node
    }
    for child in node.children {
        if let found = findNode(id: id, in: child) {
            return found
        }
    }
    return nil
}

private struct NavigatorNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let depth: Int
    let parentFolderID: String
    let root: MobileNode
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectScheme: (String) -> Void

    @State private var expanded = true
    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false
    @State private var newFolderInFolder = false

    var body: some View {
        if node.kind == "folder" {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.textMuted)
                            .frame(width: 10)
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 15)
                        Text(node.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 10)
                    .padding(.horizontal, 6)
                    .frame(height: 25)
                    .foregroundStyle(theme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(node.children) { child in
                            NavigatorNodeRow(
                                node: child,
                                depth: depth + 1,
                                parentFolderID: node.id,
                                root: root,
                                selectedSchemeID: selectedSchemeID,
                                theme: theme,
                                onSelectScheme: onSelectScheme
                            )
                        }
                    }
                }
            }
            .contextMenu {
                Button("New Scheme") { newSchemeInFolder = true }
                Button("New Folder") { newFolderInFolder = true }
                MoveToFolderMenu(nodeKind: "folder", nodeID: node.id, currentParentID: parentFolderID, root: root, excludingFolderID: node.id)
                Button("Rename") { renameNode = node }
                Button("Archive", systemImage: "archivebox") {
                    model.archiveFolder(id: node.id)
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Folder", placeholder: "Folder name", initialText: target.name, validator: { name in
                    WorkspaceNameValidation.folderError(name, root: root, excludingID: target.id)
                }) { name in
                    model.renameFolder(id: target.id, name: name)
                }
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $newSchemeInFolder) {
                NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: { name in
                    WorkspaceNameValidation.schemeError(name, root: root, folderID: node.id)
                }) { name in
                    if let id = model.createScheme(name: name, folderID: node.id) {
                        onSelectScheme(id)
                    }
                }
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $newFolderInFolder) {
                NameSheet(title: "New Folder", placeholder: "Folder name", validator: { name in
                    WorkspaceNameValidation.folderError(name, root: root)
                }) { name in
                    model.createFolder(name: name, parentID: node.id)
                }
                .presentationDetents([.height(220)])
            }
        } else {
            SwipeActionRow(actionTint: theme.danger, action: {
                model.archiveScheme(id: node.id)
            }) {
                Label("Archive", systemImage: "archivebox")
            } content: {
                Button { onSelectScheme(node.id) } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                            .frame(width: 11, height: 11)
                        Text(node.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 10)
                    .padding(.horizontal, 6)
                    .frame(height: 25)
                    .foregroundStyle(theme.textPrimary)
                    .background(selectedSchemeID == node.id ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .contextMenu {
                Button("Rename") { renameNode = node }
                MoveToFolderMenu(nodeKind: "scheme", nodeID: node.id, currentParentID: parentFolderID, root: root)
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Archive", systemImage: "archivebox") {
                    model.archiveScheme(id: node.id)
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Scheme", placeholder: "Scheme name", initialText: target.name, validator: { name in
                    WorkspaceNameValidation.schemeError(name, root: root, folderID: parentFolderID, excludingID: target.id)
                }) { name in
                    model.renameScheme(id: target.id, name: name)
                }
                .presentationDetents([.height(220)])
            }
        }
    }
}

private struct DesktopUpcomingRail: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpcomingSection(title: "Overdue", empty: "None", occurrences: calendar?.overdue ?? [], theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Today", empty: "None today", occurrences: todayOccurrences, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Upcoming", empty: "None", occurrences: calendar?.upcoming ?? [], theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
        .background(theme.bgApp)
    }

    private var todayOccurrences: [MobileOccurrence] {
        guard let today = calendar?.days.first(where: { $0.date == AppModel.dateOnly(Date()) }) else {
            return []
        }
        return today.occurrences
    }
}

private struct HomeDashboardPane: View {
    let snapshot: MobileSnapshot?
    let selectedDate: Date
    let theme: KnotQTheme
    let onOpenDaily: () -> Void
    let onOpenScheme: (String) -> Void
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let schemePreviewMaxHeight = max(260, proxy.size.height * 0.50)
            ZStack(alignment: .bottomTrailing) {
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
                        onNewFolder: onNewFolder
                    )

                    HomeUpcomingSection(
                        occurrences: upcomingOccurrences,
                        theme: theme,
                        timeFormat: timeFormat,
                        onToggleOccurrence: onToggleOccurrence,
                        onOpenOccurrence: onOpenOccurrence
                    )
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .padding(.bottom, 92)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HomeQuickWriteButtons(theme: theme, onNewScheme: onNewScheme, onOpenDaily: onOpenDaily)
                    .padding(.trailing, 22)
                    .padding(.bottom, 74)
            }
            .background(theme.bgApp)
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

private struct HomeUpcomingSection: View {
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
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                            ForEach(Array(occurrences.enumerated()), id: \.element.id) { idx, occurrence in
                            OccurrenceCompactRow(
                                occurrence: occurrence,
                                theme: theme,
                                timeFormat: timeFormat,
                                striped: idx % 2 == 1,
                                showDayLabel: true,
                                moreAction: { onOpenOccurrence(occurrence) }
                            ) {
                                onToggleOccurrence(occurrence)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HomeNavigationPane: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: MobileSnapshot?
    let selectedDate: Date
    let theme: KnotQTheme
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onCreateScheme: () -> String?
    let onNewFolder: () -> Void
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
                onNewFolder: onNewFolder
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

private struct HomeSchemesSection: View {
    let root: MobileNode?
    let dailyEntry: MobileDailyEntry?
    let selectedDate: Date
    let maxHeight: CGFloat
    let theme: KnotQTheme
    let onOpenDaily: () -> Void
    let onOpenScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Schemes")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(theme.buttonBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 3)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if let root, !root.children.isEmpty {
                            ForEach(Array(root.children.enumerated()), id: \.element.id) { index, node in
                                HomeSchemeNodeRow(
                                    node: node,
                                    position: index,
                                    siblingCount: root.children.count,
                                    depth: 0,
                                    parentFolderID: root.id,
                                    root: root,
                                    theme: theme,
                                    onOpenScheme: onOpenScheme
                                )
                            }
                        } else {
                            Text("No schemes yet")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textMuted)
                                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                .padding(.horizontal, 10)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: maxHeight)

                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(height: 0.5)
                    .padding(.leading, 10)
                    .padding(.trailing, 10)

                HomeDailySchemeRow(
                    entry: dailyEntry,
                    selectedDate: selectedDate,
                    theme: theme,
                    onOpenDaily: onOpenDaily
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(theme.rowSelected.opacity(theme.isDark ? 0.52 : 0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.borderOverlay, lineWidth: 0.8)
            }
        }
    }
}

private struct HomeDailySchemeRow: View {
    let entry: MobileDailyEntry?
    let selectedDate: Date
    let theme: KnotQTheme
    let onOpenDaily: () -> Void

    var body: some View {
        Button(action: onOpenDaily) {
            HStack(spacing: 9) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.isDark ? Color(hex: 0xc0d6ff) : Color(hex: 0x4f71a6))
                Text("Daily")
                    .font(.system(size: 15, weight: .medium))
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
            .padding(.leading, 5)
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
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

private struct HomeSchemeNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let position: Int
    let siblingCount: Int
    let depth: Int
    let parentFolderID: String
    let root: MobileNode
    let theme: KnotQTheme
    let onOpenScheme: (String) -> Void

    @State private var expanded = true
    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false
    @State private var newFolderInFolder = false

    var body: some View {
        if node.kind == "folder" {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textMuted)
                            .frame(width: 12)
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textMuted)
                            .frame(width: 18)
                        Text(node.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                            HomeSchemeNodeRow(
                                node: child,
                                position: index,
                                siblingCount: node.children.count,
                                depth: depth + 1,
                                parentFolderID: node.id,
                                root: root,
                                theme: theme,
                                onOpenScheme: onOpenScheme
                            )
                        }
                    }
                }
            }
            .contextMenu {
                Button("New Scheme") { newSchemeInFolder = true }
                Button("New Folder") { newFolderInFolder = true }
                MoveToFolderMenu(nodeKind: "folder", nodeID: node.id, currentParentID: parentFolderID, root: root, excludingFolderID: node.id)
                Button("Move Up", systemImage: "arrow.up") {
                    model.moveNode(kind: "folder", id: node.id, folderID: parentFolderID, position: max(position - 1, 0))
                }
                .disabled(position == 0)
                Button("Move Down", systemImage: "arrow.down") {
                    model.moveNode(kind: "folder", id: node.id, folderID: parentFolderID, position: min(position + 2, siblingCount))
                }
                .disabled(position >= siblingCount - 1)
                Button("Rename") { renameNode = node }
                Button("Archive", systemImage: "archivebox") {
                    model.archiveFolder(id: node.id)
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Folder", placeholder: "Folder name", initialText: target.name, validator: { name in
                    WorkspaceNameValidation.folderError(name, root: root, excludingID: target.id)
                }) { name in
                    model.renameFolder(id: target.id, name: name)
                }
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $newSchemeInFolder) {
                NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: { name in
                    WorkspaceNameValidation.schemeError(name, root: root, folderID: node.id)
                }) { name in
                    if let id = model.createScheme(name: name, folderID: node.id) {
                        onOpenScheme(id)
                    }
                }
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $newFolderInFolder) {
                NameSheet(title: "New Folder", placeholder: "Folder name", validator: { name in
                    WorkspaceNameValidation.folderError(name, root: root)
                }) { name in
                    model.createFolder(name: name, parentID: node.id)
                }
                .presentationDetents([.height(220)])
            }
        } else {
            SwipeActionRow(actionTint: theme.danger, action: {
                model.archiveScheme(id: node.id)
            }) {
                Label("Archive", systemImage: "archivebox")
            } content: {
                Button {
                    onOpenScheme(node.id)
                } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                            .frame(width: 13, height: 13)
                        Text(node.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textMuted)
                    }
                    .padding(.leading, CGFloat(depth) * 14 + 5)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contextMenu {
                Button("Rename") { renameNode = node }
                MoveToFolderMenu(nodeKind: "scheme", nodeID: node.id, currentParentID: parentFolderID, root: root)
                Button("Move Up", systemImage: "arrow.up") {
                    model.moveNode(kind: "scheme", id: node.id, folderID: parentFolderID, position: max(position - 1, 0))
                }
                .disabled(position == 0)
                Button("Move Down", systemImage: "arrow.down") {
                    model.moveNode(kind: "scheme", id: node.id, folderID: parentFolderID, position: min(position + 2, siblingCount))
                }
                .disabled(position >= siblingCount - 1)
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Archive", systemImage: "archivebox") {
                    model.archiveScheme(id: node.id)
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Scheme", placeholder: "Scheme name", initialText: target.name, validator: { name in
                    WorkspaceNameValidation.schemeError(name, root: root, folderID: parentFolderID, excludingID: target.id)
                }) { name in
                    model.renameScheme(id: target.id, name: name)
                }
                .presentationDetents([.height(220)])
            }
        }
    }
}

private struct SwipeActionRow<Content: View, ActionLabel: View>: View {
    let actionWidth: CGFloat
    let actionTint: Color
    let allowsFullSwipe: Bool
    let action: () -> Void
    let actionLabel: () -> ActionLabel
    let content: () -> Content

    @State private var restingOffset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    init(
        actionWidth: CGFloat = 88,
        actionTint: Color,
        allowsFullSwipe: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder actionLabel: @escaping () -> ActionLabel,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.actionWidth = actionWidth
        self.actionTint = actionTint
        self.allowsFullSwipe = allowsFullSwipe
        self.action = action
        self.actionLabel = actionLabel
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: performAction) {
                actionLabel()
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
                    .labelStyle(.iconOnly)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(actionTint)
            .opacity(currentOffset < -1 ? 1 : 0)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear)
                .offset(x: currentOffset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(rowDragGesture)
        .animation(.snappy(duration: 0.18), value: restingOffset)
    }

    private var currentOffset: CGFloat {
        max(-actionWidth, min(0, restingOffset + dragOffset))
    }

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.18 else { return }
                state = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.18 else { return }
                let projected = restingOffset + value.predictedEndTranslation.width
                if allowsFullSwipe && projected < -actionWidth * 1.35 {
                    performAction()
                    return
                }
                withAnimation(.snappy(duration: 0.18)) {
                    restingOffset = projected < -actionWidth * 0.42 ? -actionWidth : 0
                }
            }
    }

    private func performAction() {
        withAnimation(.snappy(duration: 0.14)) {
            restingOffset = 0
        }
        action()
    }
}

private struct HomeGlassSurface: ViewModifier {
    let theme: KnotQTheme
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(theme.isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(theme.bgModal))
                    shape.fill(theme.isDark ? Color.white.opacity(0.035) : Color.clear)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.isDark ? 0.20 : 0.16),
                            theme.borderOverlay.opacity(theme.isDark ? 0.55 : 0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(shadow ? (theme.isDark ? 0.20 : 0.018) : 0), radius: shadow ? (theme.isDark ? 12 : 4) : 0, x: 0, y: shadow ? (theme.isDark ? 5 : 1) : 0)
    }
}

private extension View {
    func homeGlassSurface(theme: KnotQTheme, cornerRadius: CGFloat = 8, shadow: Bool = true) -> some View {
        modifier(HomeGlassSurface(theme: theme, cornerRadius: cornerRadius, shadow: shadow))
    }
}

private struct HomeQuickActions: View {
    let theme: KnotQTheme
    let onOpenDaily: () -> Void

    var body: some View {
        glassButton("Daily", "checklist", action: onOpenDaily)
    }

    private func glassButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(theme.isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(theme.buttonBg), in: Capsule())
            .overlay { Capsule().stroke(theme.borderOverlay, lineWidth: 0.7) }
            .shadow(color: .black.opacity(theme.isDark ? 0.20 : 0.035), radius: theme.isDark ? 10 : 5, x: 0, y: theme.isDark ? 4 : 2)
        }
        .buttonStyle(.plain)
    }
}

private struct HomeQuickWriteButtons: View {
    let theme: KnotQTheme
    let onNewScheme: () -> Void
    let onOpenDaily: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            quickButton(icon: "checklist", label: "Daily", action: onOpenDaily)
            quickButton(icon: "pencil", label: "New Scheme", action: onNewScheme)
        }
    }

    private func quickButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 56, height: 56)
                .background(theme.isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(theme.bgToolbar), in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.24 : 0.16),
                                theme.borderOverlay.opacity(theme.isDark ? 0.60 : 0.90)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                }
                .shadow(color: .black.opacity(theme.isDark ? 0.28 : 0.06), radius: theme.isDark ? 14 : 7, x: 0, y: theme.isDark ? 6 : 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct HomeDailyPreview: View {
    let entry: MobileDailyEntry?
    let selectedDate: Date
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenDaily: () -> Void

    var body: some View {
        Button(action: onOpenDaily) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad))
                        .frame(width: 12, height: 12)
                    Text("Daily")
                        .font(.system(size: 15, weight: .semibold))
                    Text(AppModel.displayDate(entry?.date ?? AppModel.dateOnly(selectedDate)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSoft)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                }

                if previewItems.isEmpty {
                    Text("No open daily items")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                } else {
                    HomeDailyPreviewRenderedList(rows: previewRows, theme: theme, timeFormat: timeFormat)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.rowAlt.opacity(theme.isDark ? 0.82 : 0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.borderOverlay.opacity(theme.isDark ? 0.85 : 0.65), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private var previewRows: [HomeDailyPreviewRenderedRow] {
        guard let entry else { return [] }
        return previewItems.prefix(3).map { item in
            HomeDailyPreviewRenderedRow(item: item, ordinal: numberedOrdinal(for: item, in: entry.scheme.items))
        }
    }

    private var previewItems: [MobileItem] {
        guard let entry else { return [] }
        return entry.scheme.items.filter { item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !item.done
        }
    }

    private func numberedOrdinal(for item: MobileItem, in items: [MobileItem]) -> Int {
        guard item.marker == "numbered",
              let index = items.firstIndex(where: { $0.id == item.id }) else { return 1 }
        guard index > items.startIndex else { return 1 }
        let indent = Int(item.indent)
        var ordinal = 1
        var cursor = items.index(before: index)
        while cursor >= items.startIndex {
            let previous = items[cursor]
            let previousIndent = Int(previous.indent)
            if previousIndent > indent {
                if cursor == items.startIndex { break }
                cursor = items.index(before: cursor)
                continue
            }
            if previousIndent < indent || previous.marker != "numbered" {
                break
            }
            ordinal += 1
            if cursor == items.startIndex { break }
            cursor = items.index(before: cursor)
        }
        return ordinal
    }
}

private struct HomeDailyPreviewRenderedRow: Identifiable {
    let item: MobileItem
    let ordinal: Int
    var id: String { item.id }
}

private struct HomeDailyPreviewRenderedList: UIViewRepresentable {
    let rows: [HomeDailyPreviewRenderedRow]
    let theme: KnotQTheme
    let timeFormat: String

    func makeUIView(context: Context) -> HomeDailyPreviewRendererView {
        let view = HomeDailyPreviewRendererView()
        view.configure(rows: rows, theme: theme, timeFormat: timeFormat)
        return view
    }

    func updateUIView(_ uiView: HomeDailyPreviewRendererView, context: Context) {
        uiView.configure(rows: rows, theme: theme, timeFormat: timeFormat)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HomeDailyPreviewRendererView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? UIScreen.main.bounds.width - 52)
        return CGSize(width: width, height: uiView.height(for: width))
    }
}

private final class HomeDailyPreviewRendererView: UIView {
    private enum Metrics {
        static let baseX: CGFloat = 18
        static let markerSlot: CGFloat = 21
        static let indentWidth: CGFloat = 15
        static let checkboxSize: CGFloat = 14
        static let textFontSize: CGFloat = 16
        static let textLineHeight: CGFloat = 22
        static let annotationFontSize: CGFloat = 11
        static let annotationHeight: CGFloat = 14
        static let annotationBarGap: CGFloat = 8
        static let annotationTextGap: CGFloat = 7
        static let indentGuideXShift: CGFloat = 2
        static let rowGap: CGFloat = 2
        static let trailingInset: CGFloat = 2
        static let maxTextLines: CGFloat = 2
    }

    private struct LayoutRow {
        let row: HomeDailyPreviewRenderedRow
        let annotation: String?
        let textHeight: CGFloat
        let rowHeight: CGFloat
        let y: CGFloat
    }

    private var rows: [HomeDailyPreviewRenderedRow] = []
    private var theme: KnotQTheme = .dark
    private var timeFormat = "twelve_hour"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(rows: [HomeDailyPreviewRenderedRow], theme: KnotQTheme, timeFormat: String) {
        self.rows = rows
        self.theme = theme
        self.timeFormat = timeFormat
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height(for: bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width - 52))
    }

    func height(for width: CGFloat) -> CGFloat {
        layoutRows(width: width).last.map { $0.y + $0.rowHeight } ?? 0
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 1 else { return }
        let layout = layoutRows(width: bounds.width)
        let items = rows.map(\.item)
        for index in layout.indices {
            let row = layout[index]
            let item = row.row.item
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            drawIndentGuides(item: item, previous: previous, next: next, row: row, context: context)
            drawMarker(row.row, y: row.y, context: context)
            drawText(row, width: bounds.width)
            if let annotation = row.annotation {
                let previousAnnotated = index > 0 && layout[index - 1].annotation != nil
                let nextAnnotated = index + 1 < layout.count && layout[index + 1].annotation != nil
                drawAnnotationBar(item: item, row: row, connectsToPrevious: previousAnnotated, connectsToNext: nextAnnotated, context: context)
                drawAnnotation(annotation, item: item, row: row)
            }
        }
    }

    private func layoutRows(width: CGFloat) -> [LayoutRow] {
        var result: [LayoutRow] = []
        var y: CGFloat = 0
        for row in rows {
            let annotation = annotationText(for: row.item)
            let measured = textHeight(for: row.item, width: width)
            let rowHeight = measured + (annotation == nil ? 0 : Metrics.annotationHeight)
            result.append(LayoutRow(row: row, annotation: annotation, textHeight: measured, rowHeight: rowHeight, y: y))
            y += rowHeight + Metrics.rowGap
        }
        return result
    }

    private func textHeight(for item: MobileItem, width: CGFloat) -> CGFloat {
        let text = item.text.isEmpty ? item.kind.capitalized : item.text
        let availableWidth = max(1, width - Metrics.trailingInset)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(for: item),
            context: nil
        )
        let lines = min(Metrics.maxTextLines, max(1, ceil(bounds.height / Metrics.textLineHeight)))
        return lines * Metrics.textLineHeight
    }

    private func textAttributes(for item: MobileItem) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let indent = CGFloat(item.indent) * Metrics.indentWidth + Metrics.baseX
        let markerOffset = item.marker == "blank" ? CGFloat(0) : Metrics.markerSlot
        paragraph.firstLineHeadIndent = indent + markerOffset
        paragraph.headIndent = indent
        paragraph.minimumLineHeight = Metrics.textLineHeight
        paragraph.maximumLineHeight = Metrics.textLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: Metrics.textFontSize),
            .foregroundColor: UIColor(item.done ? theme.textMuted : theme.textPrimary),
            .paragraphStyle: paragraph
        ]
        if item.done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func drawText(_ row: LayoutRow, width: CGFloat) {
        let text = row.row.item.text.isEmpty ? row.row.item.kind.capitalized : row.row.item.text
        let rect = CGRect(x: 0, y: row.y, width: max(1, width - Metrics.trailingInset), height: row.textHeight)
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: textAttributes(for: row.row.item),
            context: nil
        )
    }

    private func drawIndentGuides(item: MobileItem, previous: MobileItem?, next: MobileItem?, row: LayoutRow, context: CGContext) {
        let indent = min(Int(item.indent), 8)
        guard indent > 0 else { return }
        context.setFillColor(UIColor(theme.dividerSoft).cgColor)
        let marker = markerRect(for: item, y: row.y)
        let ownBarX = marker.minX - (Metrics.annotationBarGap + Metrics.indentGuideXShift)
        let guideMargin: CGFloat = 3
        for guideIndent in 1...indent {
            let previousHasGuide = min(Int(previous?.indent ?? 0), 8) >= guideIndent
            let nextHasGuide = min(Int(next?.indent ?? 0), 8) >= guideIndent
            let topMargin = previousHasGuide ? CGFloat(0) : guideMargin
            let bottomMargin = nextHasGuide ? CGFloat(0) : guideMargin
            let levelOffset = CGFloat(indent - guideIndent) * Metrics.indentWidth
            context.fill(CGRect(
                x: ownBarX - levelOffset,
                y: row.y + topMargin,
                width: 1,
                height: max(1, row.rowHeight - topMargin - bottomMargin)
            ))
        }
    }

    private func drawMarker(_ row: HomeDailyPreviewRenderedRow, y: CGFloat, context: CGContext) {
        let item = row.item
        let rect = markerRect(for: item, y: y)
        let chrome = chromeColor
        switch item.marker {
        case "bullet":
            context.setFillColor(chrome.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
        case "numbered":
            let label = "\(row.ordinal)." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: chrome
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        case "checkbox":
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            (item.done ? chrome : UIColor(theme.buttonBg)).setFill()
            path.fill()
            chrome.setStroke()
            path.lineWidth = 1
            path.stroke()
            if item.done {
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + 3.2, y: rect.minY + 7.2))
                check.addLine(to: CGPoint(x: rect.minX + 5.8, y: rect.minY + 9.7))
                check.addLine(to: CGPoint(x: rect.maxX - 3.0, y: rect.minY + 4.3))
                UIColor(theme.bgApp).setStroke()
                check.lineWidth = 1.8
                check.stroke()
            }
        default:
            return
        }
    }

    private func drawAnnotationBar(item: MobileItem, row: LayoutRow, connectsToPrevious: Bool, connectsToNext: Bool, context: CGContext) {
        let marker = markerRect(for: item, y: row.y)
        let x = annotationGuideX(marker: marker)
        let top = connectsToPrevious ? row.y : marker.minY
        let bottom = row.y + row.rowHeight - (connectsToNext ? 0 : 3)
        context.setFillColor(chromeColor.cgColor)
        context.fill(CGRect(x: x, y: top, width: 1, height: max(1, bottom - top)))
    }

    private func drawAnnotation(_ annotation: String, item: MobileItem, row: LayoutRow) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: Metrics.annotationFontSize, weight: .medium),
            .foregroundColor: chromeColor
        ]
        let marker = markerRect(for: item, y: row.y)
        let x = annotationGuideX(marker: marker) + Metrics.annotationTextGap
        let y = row.y + row.textHeight - 1
        (annotation as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    private func markerRect(for item: MobileItem, y: CGFloat) -> CGRect {
        CGRect(
            x: Metrics.baseX + CGFloat(item.indent) * Metrics.indentWidth,
            y: y + (Metrics.textLineHeight - Metrics.checkboxSize) / 2,
            width: Metrics.checkboxSize,
            height: Metrics.checkboxSize
        )
    }

    private func annotationGuideX(marker: CGRect) -> CGFloat {
        marker.minX - (Metrics.annotationBarGap + Metrics.indentGuideXShift)
    }

    private func annotationText(for item: MobileItem) -> String? {
        let start = MobileDate.formatTime(item.start, timeFormat: timeFormat)
        let end = MobileDate.formatTime(item.end, timeFormat: timeFormat)
        switch (start, end) {
        case let (.some(start), .some(end)): return "\(start) → \(end)"
        case let (.some(start), .none): return "At \(start)"
        case let (.none, .some(end)): return "Due \(end)"
        default: return nil
        }
    }

    private var chromeColor: UIColor {
        UIColor(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x536a8f))
    }
}


private struct UpcomingSection: View {
    let title: String
    let empty: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 4)
            if occurrences.isEmpty {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(occurrences.enumerated()), id: \.element.id) { idx, occurrence in
                    OccurrenceCompactRow(
                        occurrence: occurrence,
                        theme: theme,
                        timeFormat: timeFormat,
                        striped: idx % 2 == 1,
                        moreAction: { onOpenOccurrence(occurrence) }
                    ) {
                        onToggleOccurrence(occurrence)
                    }
                }
            }
        }
    }
}

private struct DesktopCalendarPane: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let wide: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onAdd: () -> Void
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(calendar: calendar, theme: theme, onPrevious: onPrevious, onNext: onNext, onToday: onToday, onAdd: onAdd)
            ScrollView([.vertical, wide ? .horizontal : []]) {
                VStack(alignment: .leading, spacing: 12) {
                    if let overdue = calendar?.overdue, !overdue.isEmpty {
                        CalendarListSection(title: "Overdue", occurrences: overdue, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                    }

                    if wide {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(calendar?.days ?? []) { day in
                                CalendarDayColumn(day: day, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                                    .frame(width: 132)
                            }
                        }
                        .padding(.horizontal, 12)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(calendar?.days ?? []) { day in
                                CalendarDayColumn(day: day, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(theme.bgApp)
    }
}

// MARK: - DayTimelinePane (Apple Calendar-style day timeline)

private struct DayTimelinePane: View {
    let calendar: MobileCalendar?
    let selectedDate: Date
    let theme: KnotQTheme
    let timeFormat: String
    let onSetDate: (Date) -> Void
    let onShiftDay: (Int) -> Void
    let onCreate: (Date) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void

    @GestureState private var swipePreviewX: CGFloat = 0
    @State private var draggingOccurrenceID: String?
    @State private var draggingTranslation: CGSize = .zero
    @State private var lastDragSnap: Int?
    @State private var timelineScrollY: CGFloat = 0
    @State private var timelineViewportHeight: CGFloat = 0
    @State private var createDraft: CreateDraft?

    private struct CreateDraft: Equatable {
        let dayIndex: Int
        let startMinute: CGFloat
    }

    private static let hourHeight: CGFloat = 44
    private static let gutterWidth: CGFloat = 50
    private static let timeYOffset: CGFloat = 8
    private static let hoursInDay: Int = 24
    private static let weekStripDayCount: Int = 8
    private static let renderLeadDays: Int = 1
    private static let timelineCoordinateSpace = "mobile-day-timeline-scroll"
    private static let stickyTopPadding: CGFloat = 6
    private static let stickyBottomPadding: CGFloat = 82
    private static let stickySpacing: CGFloat = 4
    private static let maxStickyPerEdge = 3

    var body: some View {
        GeometryReader { proxy in
            let visibleCount = visibleDayCount(for: proxy.size.width)
            let colWidth = max(1, (proxy.size.width - Self.gutterWidth) / CGFloat(visibleCount))
            let contentOffsetX = swipePreviewX + eventDragRevealOffset(colWidth: colWidth)
            VStack(spacing: 0) {
                dateBanner()
                weekStrip(
                    visibleCount: visibleCount,
                    availableWidth: proxy.size.width,
                    colWidth: colWidth,
                    contentOffsetX: contentOffsetX
                )
                    .offset(x: contentOffsetX)
                Divider().overlay(theme.dividerSoft)
                timeline(colWidth: colWidth, visibleCount: visibleCount, contentOffsetX: contentOffsetX)
            }
            .background(theme.bgApp)
            .clipped()
        }
    }

    private func dateBanner() -> some View {
        Text(currentDateTitle)
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private func weekStrip(
        visibleCount: Int,
        availableWidth: CGFloat,
        colWidth: CGFloat,
        contentOffsetX: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.weekStripDayCount, id: \.self) { index in
                let date = weekDate(index)
                Button(action: { onSetDate(date) }) {
                    VStack(spacing: 5) {
                        Text(weekdayInitial(date))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isToday(date) || isVisibleDay(date, visibleCount: visibleCount) ? theme.textPrimary : theme.textMuted)
                        // Selection capsule wraps only the day-number row, not
                        // the weekday header; segments butt against neighbours
                        // (−1 horizontal padding) to read as one continuous pill.
                        ZStack {
                            if isVisibleDay(date, visibleCount: visibleCount) {
                                CalendarRangeSegment(
                                    leadingRounded: isFirstVisibleDay(date),
                                    trailingRounded: isLastVisibleDay(date, visibleCount: visibleCount)
                                )
                                .fill(calendarRangeFill)
                                .padding(.horizontal, -1)
                            }
                            Text(dayNumberLabel(date))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(dayNumberColor(date))
                                .frame(width: 34, height: 34)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .simultaneousGesture(
            daySwipeGesture(
                visibleCount: visibleCount,
                availableWidth: availableWidth,
                colWidth: colWidth,
                contentOffsetX: contentOffsetX
            ),
            including: .subviews
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: selectedDateKey)
    }

    private func daySwipeGesture(
        visibleCount: Int,
        availableWidth: CGFloat,
        colWidth: CGFloat? = nil,
        contentOffsetX: CGFloat = 0
    ) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($swipePreviewX) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                let adjustedStart = CGPoint(x: value.startLocation.x - contentOffsetX, y: value.startLocation.y)
                if let colWidth,
                   pointHitsEvent(adjustedStart, colWidth: colWidth, visibleCount: visibleCount) {
                    return
                }
                guard abs(dx) > abs(dy) * 1.35 else { return }
                let limit = colWidth ?? max(1, availableWidth / CGFloat(max(1, visibleCount)))
                state = rubberBandDayOffset(dx, colWidth: limit)
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let projected = abs(value.predictedEndTranslation.width) > abs(dx)
                    ? value.predictedEndTranslation.width
                    : dx
                let adjustedStart = CGPoint(x: value.startLocation.x - contentOffsetX, y: value.startLocation.y)
                if let colWidth,
                   pointHitsEvent(adjustedStart, colWidth: colWidth, visibleCount: visibleCount) {
                    return
                }
                guard abs(dx) > abs(dy) * 1.35,
                      abs(projected) > max(48, min(availableWidth * 0.15, colWidth ?? max(1, availableWidth / CGFloat(max(1, visibleCount))) * 0.68)) else { return }
                withAnimation(.interpolatingSpring(stiffness: 320, damping: 34)) {
                    onShiftDay(projected < 0 ? 1 : -1)
                }
            }
    }

    private func rubberBandDayOffset(_ value: CGFloat, colWidth: CGFloat) -> CGFloat {
        let limit = colWidth * 0.92
        let magnitude = abs(value)
        let sign: CGFloat = value < 0 ? -1 : 1
        if magnitude <= limit {
            return value
        }
        return sign * (limit + (magnitude - limit) * 0.18)
    }

    // MARK: Timeline

    private func timeline(colWidth: CGFloat, visibleCount: Int, contentOffsetX: CGFloat) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        scrollOffsetReader()
                        scrollAnchors()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        timeLegend()
                            .allowsHitTesting(false)
                        hourGrid(colWidth: colWidth, visibleCount: visibleCount)
                            .offset(x: contentOffsetX)
                            .allowsHitTesting(false)
                        eventsLayer(colWidth: colWidth, visibleCount: visibleCount, contentOffsetX: contentOffsetX)
                        createDraftLayer(colWidth: colWidth)
                            .offset(x: contentOffsetX)
                        nowLine(colWidth: colWidth, visibleCount: visibleCount)
                            .offset(x: contentOffsetX)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .frame(height: Self.timeYOffset + CGFloat(Self.hoursInDay) * Self.hourHeight)
                    .padding(.bottom, 88)
                .simultaneousGesture(
                        createGesture(colWidth: colWidth, visibleCount: visibleCount, contentOffsetX: contentOffsetX),
                        including: .subviews
                    )
                    .simultaneousGesture(
                        daySwipeGesture(
                            visibleCount: visibleCount,
                            availableWidth: viewport.size.width,
                            colWidth: colWidth,
                            contentOffsetX: contentOffsetX
                        ),
                        including: .subviews
                    )
                }
                .coordinateSpace(name: Self.timelineCoordinateSpace)
                .onAppear {
                    timelineViewportHeight = viewport.size.height
                    scrollToFocusHour(proxy)
                }
                .onChange(of: viewport.size.height) { _, height in
                    timelineViewportHeight = height
                }
                .onChange(of: selectedDateKey) { _, _ in scrollToFocusHour(proxy) }
                .onPreferenceChange(TimelineScrollOffsetPreferenceKey.self) { minY in
                    timelineScrollY = max(0, -minY)
                }
            }
        }
    }

    private func scrollOffsetReader() -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TimelineScrollOffsetPreferenceKey.self,
                value: proxy.frame(in: .named(Self.timelineCoordinateSpace)).minY
            )
        }
        .frame(height: 0)
    }

    private func scrollAnchors() -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Self.timeYOffset)
            ForEach(0..<Self.hoursInDay, id: \.self) { hour in
                Color.clear
                    .frame(height: Self.hourHeight)
                    .id("hour-\(hour)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func scrollToFocusHour(_ proxy: ScrollViewProxy) {
        let focus = hasToday
            ? max(0, Calendar.current.component(.hour, from: Date()) - 1)
            : 7
        proxy.scrollTo("hour-\(focus)", anchor: .top)
    }

    private func createGesture(colWidth: CGFloat, visibleCount: Int, contentOffsetX: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(_, drag?) = value else { return }
                let adjusted = CGPoint(
                    x: drag.startLocation.x - contentOffsetX,
                    y: drag.startLocation.y
                )
                let moving = CGPoint(
                    x: drag.location.x - contentOffsetX,
                    y: drag.location.y
                )
                if createDraft == nil {
                    guard !pointHitsEvent(adjusted, colWidth: colWidth, visibleCount: visibleCount) else { return }
                    createDraft = createTarget(point: adjusted, colWidth: colWidth, visibleCount: visibleCount)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    let moved = createTarget(point: moving, colWidth: colWidth, visibleCount: visibleCount)
                    if moved != createDraft {
                        createDraft = moved
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            }
            .onEnded { _ in
                let draft = createDraft
                createDraft = nil
                if let draft, let date = createDate(for: draft) {
                    onCreate(date)
                }
            }
    }

    private func pointHitsEvent(_ point: CGPoint, colWidth: CGFloat, visibleCount: Int) -> Bool {
        allLaidEvents(colWidth: colWidth, visibleCount: visibleCount).contains { laid in
            point.x >= laid.x
                && point.x <= laid.x + laid.width
                && point.y >= laid.y
                && point.y <= laid.y + laid.height
        }
    }

    private func createTarget(point: CGPoint, colWidth: CGFloat, visibleCount: Int) -> CreateDraft {
        let dayIndex = max(0, min(visibleCount - 1, Int((point.x - Self.gutterWidth) / colWidth)))
        let rawMinute = (point.y - Self.timeYOffset) / Self.hourHeight * 60
        let snapped = (rawMinute / 15).rounded() * 15
        let clamped = max(0, min(CGFloat(Self.hoursInDay * 60 - 60), snapped))
        return CreateDraft(dayIndex: dayIndex, startMinute: clamped)
    }

    private func createDate(for draft: CreateDraft) -> Date? {
        let base = Calendar.current.startOfDay(for: dayDate(draft.dayIndex))
        return Calendar.current.date(byAdding: .minute, value: Int(draft.startMinute), to: base)
    }

    @ViewBuilder
    private func createDraftLayer(colWidth: CGFloat) -> some View {
        if let draft = createDraft {
            let y = Self.timeYOffset + draft.startMinute / 60.0 * Self.hourHeight
            let x = Self.gutterWidth + CGFloat(draft.dayIndex) * colWidth
            VStack(spacing: 1) {
                Text(draftTimeLabel(draft))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                Text("New Event")
                    .font(.system(size: 11, weight: .bold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 3)
            .foregroundStyle(theme.isDark ? Color.white : Color(hex: 0x24272d))
            .frame(width: colWidth - 2, height: Self.hourHeight - 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(theme.isDark ? 0.32 : 0.22)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 1.5))
            .offset(x: x + 1, y: y)
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(theme.isDark ? 0.32 : 0.12), radius: theme.isDark ? 7 : 4, x: 0, y: theme.isDark ? 4 : 2)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: draft)
        }
    }

    private func draftTimeLabel(_ draft: CreateDraft) -> String {
        guard let start = createDate(for: draft) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm a"
        return formatter.string(from: start)
    }

    private func timeLegend() -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Self.hoursInDay, id: \.self) { hour in
                let y = Self.timeYOffset + CGFloat(hour) * Self.hourHeight
                Text(hourLabel(hour))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: Self.gutterWidth - 8, alignment: .trailing)
                    .offset(y: y - 6)
            }
            Rectangle()
                .fill(theme.divider)
                .frame(width: 0.75, height: Self.timeYOffset + CGFloat(Self.hoursInDay) * Self.hourHeight)
                .offset(x: Self.gutterWidth - 0.5)
        }
        .frame(width: Self.gutterWidth)
    }

    private func hourGrid(colWidth: CGFloat, visibleCount: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Self.hoursInDay, id: \.self) { hour in
                let y = Self.timeYOffset + CGFloat(hour) * Self.hourHeight
                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(height: 0.5)
                    .frame(width: colWidth * CGFloat(visibleCount))
                    .offset(x: Self.gutterWidth)
                    .offset(y: y)
            }
            ForEach(1..<visibleCount, id: \.self) { index in
                Rectangle()
                    .fill(theme.divider.opacity(theme.isDark ? 0.95 : 0.85))
                    .frame(width: 1, height: Self.timeYOffset + CGFloat(Self.hoursInDay) * Self.hourHeight)
                    .offset(x: Self.gutterWidth + CGFloat(index) * colWidth - 0.5)
            }
            Rectangle()
                .fill(theme.divider)
                .frame(width: colWidth * CGFloat(visibleCount), height: 1)
                .offset(x: Self.gutterWidth)
                .offset(y: Self.timeYOffset + CGFloat(Self.hoursInDay) * Self.hourHeight - 1)
        }
    }

    private func eventsLayer(colWidth: CGFloat, visibleCount: Int, contentOffsetX: CGFloat) -> some View {
        ForEach(allLaidEvents(colWidth: colWidth, visibleCount: visibleCount)) { laid in
            let dragOffset = eventDragOffset(for: laid, colWidth: colWidth, visibleCount: visibleCount)
            let isDragging = draggingOccurrenceID == laid.id
            TimelineEventBlock(
                occurrence: laid.occurrence,
                theme: theme,
                timeFormat: timeFormat,
                onTap: { onOpenOccurrence(laid.occurrence) }
            )
            .frame(width: laid.width, height: laid.height)
            .offset(x: laid.x + dragOffset.width + (isDragging ? 0 : contentOffsetX), y: laid.y + dragOffset.height)
            .zIndex(isDragging ? 10 : 0)
            .shadow(
                color: .black.opacity(isDragging ? (theme.isDark ? 0.32 : 0.07) : 0),
                radius: isDragging ? (theme.isDark ? 7 : 4) : 0,
                x: 0,
                y: isDragging ? (theme.isDark ? 4 : 2) : 0
            )
            .simultaneousGesture(
                eventDragGesture(for: laid, colWidth: colWidth, visibleCount: visibleCount),
                including: .subviews
            )
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: draggingOccurrenceID)
        }
    }

    private func stickyEventsLayer(colWidth: CGFloat, visibleCount: Int) -> some View {
        ForEach(stickyLaidEvents(colWidth: colWidth, visibleCount: visibleCount)) { sticky in
            TimelineEventBlock(
                occurrence: sticky.laid.occurrence,
                theme: theme,
                timeFormat: timeFormat,
                onTap: { onOpenOccurrence(sticky.laid.occurrence) }
            )
            .frame(width: sticky.laid.width, height: sticky.height)
            .offset(x: sticky.laid.x, y: sticky.y)
            .shadow(color: .black.opacity(theme.isDark ? 0.30 : 0.06), radius: theme.isDark ? 6 : 3, x: 0, y: sticky.edge == .top ? (theme.isDark ? 3 : 1.5) : (theme.isDark ? -2 : -1))
            .zIndex(30 + Double(sticky.rank))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func nowLine(colWidth: CGFloat, visibleCount: Int) -> some View {
        if let todayIndex = renderedDayOffsets(visibleCount: visibleCount).first(where: { isToday(dayDate($0)) }) {
            let cal = Calendar.current
            let now = Date()
            let minute = CGFloat(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now))
            let y = Self.timeYOffset + minute / 60.0 * Self.hourHeight
            let x = Self.gutterWidth + CGFloat(todayIndex) * colWidth
            ZStack(alignment: .leading) {
                Circle().fill(theme.danger).frame(width: 7, height: 7).offset(x: x - 3.5)
                Rectangle().fill(theme.danger).frame(width: colWidth, height: 1.5).offset(x: x)
            }
            .offset(y: y - 1)
        }
    }

    // MARK: Layout

    private struct LaidOccurrence: Identifiable {
        let id: String
        let occurrence: MobileOccurrence
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let dayIndex: Int
        let startMinute: CGFloat
        let endMinute: CGFloat
    }

    private enum StickyEdge {
        case top
        case bottom
    }

    private struct StickyLaidOccurrence: Identifiable {
        let id: String
        let laid: LaidOccurrence
        let y: CGFloat
        let height: CGFloat
        let edge: StickyEdge
        let rank: Int
    }

    private func allLaidEvents(colWidth: CGFloat, visibleCount: Int) -> [LaidOccurrence] {
        renderedDayOffsets(visibleCount: visibleCount).flatMap { laid(forDayIndex: $0, colWidth: colWidth) }
    }

    private func stickyLaidEvents(colWidth: CGFloat, visibleCount: Int) -> [StickyLaidOccurrence] {
        guard timelineViewportHeight > 120 else { return [] }

        let visibleTop = timelineScrollY
        let actualVisibleBottom = timelineScrollY + timelineViewportHeight
        let stickyBottom = actualVisibleBottom - Self.stickyBottomPadding
        let candidates = allLaidEvents(colWidth: colWidth, visibleCount: visibleCount).filter { laid in
            draggingOccurrenceID != laid.id && laid.dayIndex >= 0 && laid.dayIndex < visibleCount
        }
        let above = candidates
            .filter { $0.y + $0.height < visibleTop - 6 }
            .sorted { $0.y > $1.y }
            .prefix(Self.maxStickyPerEdge)
        let below = candidates
            .filter { $0.y > actualVisibleBottom + 6 }
            .sorted { $0.y < $1.y }
            .prefix(Self.maxStickyPerEdge)

        var sticky: [StickyLaidOccurrence] = []
        var topCursor = visibleTop + Self.stickyTopPadding
        for (rank, laid) in above.enumerated() {
            let height = stickyHeight(for: laid)
            sticky.append(StickyLaidOccurrence(
                id: "sticky-top-\(laid.id)",
                laid: laid,
                y: topCursor,
                height: height,
                edge: .top,
                rank: rank
            ))
            topCursor += height + Self.stickySpacing
        }

        var bottomCursor = max(visibleTop + 80, stickyBottom)
        for (rank, laid) in below.enumerated() {
            let height = stickyHeight(for: laid)
            bottomCursor -= height
            sticky.append(StickyLaidOccurrence(
                id: "sticky-bottom-\(laid.id)",
                laid: laid,
                y: bottomCursor,
                height: height,
                edge: .bottom,
                rank: rank
            ))
            bottomCursor -= Self.stickySpacing
        }
        return sticky
    }

    private func stickyHeight(for laid: LaidOccurrence) -> CGFloat {
        min(42, max(24, laid.height))
    }

    /// Lays out one day's occurrences within its column, packing overlapping
    /// events into sub-columns so they sit side-by-side.
    private func laid(forDayIndex dayIndex: Int, colWidth: CGFloat) -> [LaidOccurrence] {
        struct Slot {
            let occurrence: MobileOccurrence
            let startMinute: CGFloat
            let endMinute: CGFloat
        }
        var slots: [Slot] = []
        for occurrence in occurrences(forDayIndex: dayIndex) {
            let anchor = minuteOfDay(for: occurrence.start) ?? minuteOfDay(for: occurrence.end)
            guard let startMinute = anchor else { continue }
            let endMinute: CGFloat = {
                if let m = minuteOfDay(for: occurrence.end), m > startMinute { return m }
                return startMinute + 30
            }()
            slots.append(Slot(occurrence: occurrence, startMinute: startMinute, endMinute: endMinute))
        }
        slots.sort { $0.startMinute < $1.startMinute }

        var columnEnd: [CGFloat] = []
        var slotColumn: [Int] = Array(repeating: 0, count: slots.count)
        for (i, slot) in slots.enumerated() {
            var placed = false
            for (col, end) in columnEnd.enumerated() where slot.startMinute >= end {
                columnEnd[col] = slot.endMinute
                slotColumn[i] = col
                placed = true
                break
            }
            if !placed {
                slotColumn[i] = columnEnd.count
                columnEnd.append(slot.endMinute)
            }
        }
        let subCount = max(1, columnEnd.count)
        let subWidth = colWidth / CGFloat(subCount)
        let columnX = Self.gutterWidth + CGFloat(dayIndex) * colWidth

        return slots.enumerated().map { (i, slot) in
            let y = Self.timeYOffset + slot.startMinute / 60.0 * Self.hourHeight
            let height = max(16, (slot.endMinute - slot.startMinute) / 60.0 * Self.hourHeight - 2)
            return LaidOccurrence(
                id: "\(dayIndex)-\(slot.occurrence.id)",
                occurrence: slot.occurrence,
                x: columnX + CGFloat(slotColumn[i]) * subWidth + 1,
                y: y,
                width: subWidth - 2,
                height: height,
                dayIndex: dayIndex,
                startMinute: slot.startMinute,
                endMinute: slot.endMinute
            )
        }
    }

    private struct OccurrenceMoveTarget {
        let dayIndex: Int
        let startMinute: CGFloat
        let start: Date?
        let end: Date?
    }

    /// Long-press to "pick up" the event, then drag to reschedule. A plain tap
    /// still falls through to the block's button (opens the editor).
    private func eventDragGesture(for laid: LaidOccurrence, colWidth: CGFloat, visibleCount: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard !laid.occurrence.isReadOnly else { return }
                switch value {
                case .first(true):
                    if draggingOccurrenceID != laid.id {
                        draggingOccurrenceID = laid.id
                        draggingTranslation = .zero
                        lastDragSnap = nil
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                case let .second(_, drag?):
                    draggingTranslation = drag.translation
                    let snap = eventSnapIndex(for: laid, translation: drag.translation, colWidth: colWidth, visibleCount: visibleCount)
                    if let snap, snap != lastDragSnap {
                        lastDragSnap = snap
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                guard !laid.occurrence.isReadOnly else { return }
                var moveTarget: OccurrenceMoveTarget?
                if case let .second(_, drag?) = value,
                   abs(drag.translation.width) > 2 || abs(drag.translation.height) > 2 {
                    moveTarget = occurrenceMoveTarget(for: laid, translation: drag.translation, colWidth: colWidth, visibleCount: visibleCount)
                }
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    draggingOccurrenceID = nil
                    draggingTranslation = .zero
                    lastDragSnap = nil
                }
                if let moveTarget {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onMoveOccurrence(laid.occurrence, moveTarget.start, moveTarget.end)
                }
            }
    }

    private func eventDragOffset(for laid: LaidOccurrence, colWidth: CGFloat, visibleCount: Int) -> CGSize {
        guard !laid.occurrence.isReadOnly else { return .zero }
        guard draggingOccurrenceID == laid.id,
              let target = occurrenceMoveTarget(for: laid, translation: draggingTranslation, colWidth: colWidth, visibleCount: visibleCount) else {
            return .zero
        }
        let y = Self.timeYOffset + target.startMinute / 60.0 * Self.hourHeight - laid.y
        return CGSize(width: draggingTranslation.width, height: y)
    }

    private func eventSnapIndex(for laid: LaidOccurrence, translation: CGSize, colWidth: CGFloat, visibleCount: Int) -> Int? {
        occurrenceMoveTarget(for: laid, translation: translation, colWidth: colWidth, visibleCount: visibleCount).map {
            $0.dayIndex * 96 + Int($0.startMinute / 15.0)
        }
    }

    private func occurrenceMoveTarget(for laid: LaidOccurrence, translation: CGSize, colWidth: CGFloat, visibleCount: Int) -> OccurrenceMoveTarget? {
        let movingCenterX = laid.x + laid.width / 2 + translation.width
        let rawDayIndex = Int(floor((movingCenterX - Self.gutterWidth) / colWidth))
        let dayIndex = min(visibleCount, max(-1, rawDayIndex))
        let duration = max(15, laid.endMinute - laid.startMinute)
        let maxStart = laid.occurrence.kind == "event"
            ? CGFloat(Self.hoursInDay * 60) - duration
            : CGFloat(Self.hoursInDay * 60 - 15)
        let rawMinute = (laid.y + translation.height - Self.timeYOffset) / Self.hourHeight * 60
        let snapped = (rawMinute / 15).rounded() * 15
        let startMinute = max(0, min(maxStart, snapped))
        let base = Calendar.current.startOfDay(for: dayDate(dayIndex))
        guard let anchor = Calendar.current.date(byAdding: .minute, value: Int(startMinute), to: base) else {
            return nil
        }
        if laid.occurrence.kind == "assignment" {
            return OccurrenceMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: nil, end: anchor)
        }
        if laid.occurrence.kind == "reminder" {
            return OccurrenceMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: nil)
        }
        let end = Calendar.current.date(byAdding: .minute, value: Int(duration), to: anchor) ?? anchor.addingTimeInterval(TimeInterval(duration * 60))
        return OccurrenceMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: end)
    }

    private func eventDragRevealOffset(colWidth: CGFloat) -> CGFloat {
        guard draggingOccurrenceID != nil else { return 0 }
        let threshold = colWidth * 0.20
        let dx = draggingTranslation.width
        if dx < -threshold {
            return min(colWidth * 0.72, (-dx - threshold) * 0.55)
        }
        if dx > threshold {
            return -min(colWidth * 0.72, (dx - threshold) * 0.55)
        }
        return 0
    }

    // MARK: Data helpers

    private func visibleDayCount(for width: CGFloat) -> Int {
        width >= 620 ? 3 : 2
    }

    private func renderedDayOffsets(visibleCount: Int) -> Range<Int> {
        (-Self.renderLeadDays)..<(visibleCount + Self.renderLeadDays)
    }

    private func dayDate(_ index: Int) -> Date {
        let base = Calendar.current.startOfDay(for: selectedDate)
        return Calendar.current.date(byAdding: .day, value: index, to: base) ?? base
    }

    private func occurrences(forDayIndex index: Int) -> [MobileOccurrence] {
        let key = AppModel.dateOnly(dayDate(index))
        return calendar?.days.first { $0.date == key }?.occurrences ?? []
    }

    private func minuteOfDay(for raw: String?) -> CGFloat? {
        guard let raw, let date = MobileDate.parseDateTime(raw) else { return nil }
        let comp = Calendar.current.dateComponents([.hour, .minute], from: date)
        return CGFloat((comp.hour ?? 0) * 60 + (comp.minute ?? 0))
    }

    private func hourLabel(_ hour: Int) -> String {
        if timeFormat == "twenty_four_hour" {
            return String(format: "%02d:00", hour)
        }
        switch hour {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case ..<12: return "\(hour) AM"
        default: return "\(hour - 12) PM"
        }
    }

    private func weekDate(_ index: Int) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: selectedDate)
        let sundayOffset = weekday - 1
        let sunday = calendar.date(byAdding: .day, value: -sundayOffset, to: calendar.startOfDay(for: selectedDate)) ?? selectedDate
        return calendar.date(byAdding: .day, value: index, to: sunday) ?? sunday
    }

    private func isVisibleDay(_ date: Date, visibleCount: Int) -> Bool {
        (0..<visibleCount).contains { AppModel.dateOnly(dayDate($0)) == AppModel.dateOnly(date) }
    }

    private func isFirstVisibleDay(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(dayDate(0))
    }

    private func isLastVisibleDay(_ date: Date, visibleCount: Int) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(dayDate(visibleCount - 1))
    }

    private func isSelectedDay(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == selectedDateKey
    }

    private func dayNumberColor(_ date: Date) -> Color {
        isToday(date) ? theme.accent : theme.textPrimary
    }

    private var calendarRangeFill: Color {
        theme.isDark ? Color.white.opacity(0.09) : Color(hex: 0x3f6fd5).opacity(0.08)
    }

    private var currentDateTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: selectedDate)
    }

    private func monthName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: date)
    }

    private var weekRangeLabel: String {
        "\(shortMonthDay(weekDate(0))) - \(shortMonthDay(weekDate(Self.weekStripDayCount - 1)))"
    }

    private func monthLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func shortMonthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func weekdayInitial(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f.string(from: date).uppercased()
    }

    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func dayNumberLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private var selectedDateKey: String {
        AppModel.dateOnly(selectedDate)
    }

    private func isToday(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(Date())
    }

    private var hasToday: Bool {
        (0..<3).contains { isToday(dayDate($0)) }
    }
}

/// Matches the desktop `render_event_chunk` styling: neutral event background,
/// cal-event-text border, centered time/title lines, and desktop calendar text
/// colors instead of a scheme-tinted fill.
private struct TimelineEventBlock: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
                .padding(.horizontal, isPill ? 8 : 6)
                .padding(.top, contentTopPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(background)
                .overlay(overlay)
                .clipped()
        }
        .buttonStyle(.plain)
        .opacity(occurrence.done ? 0.55 : 1)
    }

    private var content: some View {
        VStack(alignment: .center, spacing: 0) {
            if !hideTime, !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(timeColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 10, alignment: .center)
                    .truncationMode(.tail)
            }
            Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                .font(.system(size: hideTime ? 10 : 11, weight: .bold))
                .lineLimit(1)
                .strikethrough(occurrence.done)
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity, minHeight: hideTime ? 13 : 15, alignment: .center)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isPill {
            Rectangle().fill(eventBg)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(eventBg)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if isPill {
            VStack(spacing: 0) {
                if isReminder {
                    Rectangle().fill(borderColor).frame(height: pillStrokeWidth)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Rectangle().fill(borderColor).frame(height: pillStrokeWidth)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 3)
                .stroke(borderColor, lineWidth: eventBorderWidth)
        }
    }

    private var isReminder: Bool {
        occurrence.kind == "reminder"
    }

    private var isAssignment: Bool {
        occurrence.kind == "assignment"
    }

    private var isPill: Bool {
        isReminder || isAssignment
    }

    private var contentTopPadding: CGFloat {
        if isReminder { return 6 }
        if isAssignment { return 3 }
        return hideTime ? 1 : 3
    }

    private var eventBorderWidth: CGFloat {
        1.5
    }

    private var pillStrokeWidth: CGFloat {
        2
    }

    private var hideTime: Bool {
        guard occurrence.kind == "event",
              let start = MobileDate.parseDateTime(occurrence.start),
              let end = MobileDate.parseDateTime(occurrence.end) else {
            return false
        }
        return end.timeIntervalSince(start) <= 30 * 60
    }

    private var timeColor: Color {
        guard !occurrence.done,
              let start = MobileDate.parseDateTime(occurrence.start ?? occurrence.end) else {
            return defaultTimeColor
        }
        let now = Date()
        if let end = MobileDate.parseDateTime(occurrence.end), start <= now, end > now {
            return todayTimeColor
        }
        if start < now {
            return theme.isDark ? Color(hex: 0xff5a53) : Color(hex: 0xd20f39)
        }
        let startDay = Calendar.current.startOfDay(for: start)
        let today = Calendar.current.startOfDay(for: now)
        let dayDiff = Calendar.current.dateComponents([.day], from: today, to: startDay).day ?? 0
        if dayDiff <= 0 {
            return todayTimeColor
        }
        if dayDiff <= 1 {
            return theme.isDark ? Color(hex: 0xe5e5ff) : Color(hex: 0x4f5f8f)
        }
        return defaultTimeColor
    }

    private var defaultTimeColor: Color {
        theme.isDark ? Color(hex: 0xe8edf2).opacity(0.90) : Color(hex: 0x2e291f).opacity(0.90)
    }

    private var todayTimeColor: Color {
        theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
    }

    private var titleColor: Color {
        calendarItemTextColor(index: occurrence.colorIndex, done: occurrence.done, dark: theme.isDark)
    }

    private func calendarItemTextColor(index: Int32, done: Bool, dark: Bool) -> Color {
        let darkPalette: [(Double, Double, Double)] = [
            (1.00, 0.270, 0.227),
            (1.00, 0.624, 0.039),
            (0.188, 0.820, 0.345),
            (0.039, 0.518, 1.000),
            (0.749, 0.353, 0.949),
            (1.000, 0.839, 0.039),
        ]
        let lightPalette: [(Double, Double, Double)] = [
            (0.831, 0.153, 0.110),
            (0.769, 0.455, 0.000),
            (0.118, 0.620, 0.251),
            (0.000, 0.392, 0.824),
            (0.541, 0.239, 0.710),
            (0.878, 0.659, 0.000),
        ]
        let palette = dark ? darkPalette : lightPalette
        let rgb = palette[Int(index) % palette.count]
        let amount = done ? (dark ? 0.35 : 0.45) : (dark ? 0.70 : 0.90)
        let luma = rgb.0 * 0.299 + rgb.1 * 0.587 + rgb.2 * 0.114
        let color = Color(
            red: luma + (rgb.0 - luma) * amount,
            green: luma + (rgb.1 - luma) * amount,
            blue: luma + (rgb.2 - luma) * amount
        )
        return done ? color.opacity(0.78) : color
    }

    /// Neutral background: matches desktop's `event_bg` token (≈ #333 dark /
    /// off-white light, alpha-blended onto bgApp).
    private var eventBg: Color {
        theme.isDark ? Color(hex: 0x333333).opacity(0.62) : Color(hex: 0xe6e8ec).opacity(0.62)
    }

    /// Desktop border = `cal_event_text` (off-white / near-black). Mirror it.
    private var borderColor: Color {
        theme.isDark ? Color.white.opacity(0.84) : Color(hex: 0x24272d).opacity(0.80)
    }

    private var timeLabel: String {
        if isReminder, let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat) {
            return "At \(start)"
        }
        if isAssignment, let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat) {
            return "Due \(end)"
        }
        let start = formatEventTime(occurrence.start, includePeriod: false)
        let end = formatEventTime(occurrence.end, includePeriod: true)
        if let start, let end { return "\(start) to \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return ""
    }

    private func formatEventTime(_ raw: String?, includePeriod: Bool) -> String? {
        guard let date = MobileDate.parseDateTime(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if timeFormat == "twenty_four_hour" {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = includePeriod ? "h:mm a" : "h:mm"
        }
        return formatter.string(from: date)
    }
}

private struct CalendarRangeSegment: Shape {
    let leadingRounded: Bool
    let trailingRounded: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(9, rect.height * 0.28)
        var corners: UIRectCorner = []
        if leadingRounded {
            corners.insert(.topLeft)
            corners.insert(.bottomLeft)
        }
        if trailingRounded {
            corners.insert(.topRight)
            corners.insert(.bottomRight)
        }
        return Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}

private struct TimelineScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CalendarToolbar: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrevious) { Image(systemName: "chevron.left") }
                .buttonStyle(TitleIconButton(theme: theme))
            VStack(alignment: .leading, spacing: 2) {
                Text(monthText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSoft)
                Text(rangeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Button("Today", action: onToday)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "calendar.badge.plus") }
                .buttonStyle(TitleIconButton(theme: theme))
            Button(action: onNext) { Image(systemName: "chevron.right") }
                .buttonStyle(TitleIconButton(theme: theme))
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }

    private var rangeText: String {
        guard let calendar else { return "Calendar" }
        return "\(MobileDate.formatDay(calendar.startDate)) - \(MobileDate.formatDay(calendar.endDate))"
    }

    private var monthText: String {
        guard let start = calendar?.startDate,
              let date = AppModel.date(from: start) else {
            return "Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

private struct CalendarDayColumn: View {
    let day: MobileCalendarDay
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MobileDate.formatFullDay(day.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(day.date == AppModel.dateOnly(Date()) ? theme.textToday : theme.textDim)
                .lineLimit(1)
            if day.occurrences.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.rowAlt, in: RoundedRectangle(cornerRadius: 4))
            } else {
                ForEach(day.occurrences) { occurrence in
                    CalendarEventBlock(occurrence: occurrence, theme: theme, timeFormat: timeFormat) {
                        onOpenScheme(occurrence.schemeId)
                    }
                }
            }
        }
        .padding(8)
        .background(theme.bgModal.opacity(theme.isDark ? 0.35 : 0.45), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(theme.dividerSoft, lineWidth: 1) }
    }
}

private struct CalendarDayList: View {
    let day: MobileCalendarDay
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MobileDate.formatFullDay(day.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(day.date == AppModel.dateOnly(Date()) ? theme.textToday : theme.textDim)
            if day.occurrences.isEmpty {
                Text("No calendar items")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .padding(.vertical, 6)
            } else {
                ForEach(day.occurrences) { occurrence in
                    OccurrenceCompactRow(occurrence: occurrence, theme: theme, timeFormat: timeFormat, striped: false) {
                        onOpenScheme(occurrence.schemeId)
                    }
                }
            }
        }
    }
}

private struct CalendarListSection: View {
    let title: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.danger)
            ForEach(occurrences) { occurrence in
                OccurrenceCompactRow(occurrence: occurrence, theme: theme, timeFormat: timeFormat, striped: false) {
                    onOpenScheme(occurrence.schemeId)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct CalendarEventBlock: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(3)
                    .strikethrough(occurrence.done)
                Text(occurrenceTimeLabel(occurrence, timeFormat: timeFormat))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSoft)
                Text(occurrence.schemeName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(schemeColor(occurrence.colorIndex, dark: theme.isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(theme.isDark ? Color(hex: 0x333333).opacity(0.82) : Color(hex: 0xd3d2ce).opacity(0.86), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(schemeColor(occurrence.colorIndex, dark: theme.isDark))
                    .frame(width: 2)
                    .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .opacity(occurrence.done ? 0.45 : 1)
    }
}

private struct OccurrenceCompactRow: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let striped: Bool
    let moreAction: (() -> Void)?
    let action: () -> Void
    let showDayLabel: Bool

    init(
        occurrence: MobileOccurrence,
        theme: KnotQTheme,
        timeFormat: String,
        striped: Bool,
        showDayLabel: Bool = false,
        moreAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.theme = theme
        self.timeFormat = timeFormat
        self.striped = striped
        self.moreAction = moreAction
        self.action = action
        self.showDayLabel = showDayLabel
    }

    var body: some View {
        rowContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .onLongPressGesture {
            if let moreAction {
                moreAction()
            }
        }
        .opacity(occurrence.done ? 0.45 : 1)
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(schemeColor(occurrence.colorIndex, dark: theme.isDark))
                .frame(width: 1.5)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(occurrence.schemeName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(schemeColor(occurrence.colorIndex, dark: theme.isDark))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(occurrenceTimeLabel(occurrence, timeFormat: timeFormat, showDay: showDayLabel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(occurrenceStatusTimeColor(occurrence, theme: theme))
                        .lineLimit(1)
                }
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .strikethrough(occurrence.done)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(striped ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct ArchiveNavigatorSection: View {
    @EnvironmentObject private var model: AppModel
    let schemes: [MobileScheme]
    let theme: KnotQTheme
    let compact: Bool
    @State private var expanded = false
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .frame(width: compact ? 12 : 14)
                    Text("Archive")
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                    Spacer(minLength: 0)
                    if !schemes.isEmpty {
                        Text("\(schemes.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textMuted)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                }
                .frame(height: compact ? 22 : 25)
                .padding(.horizontal, compact ? 6 : 8)
                .foregroundStyle(theme.textPrimary)
                .background(expanded ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Empty Archive", systemImage: "trash", role: .destructive) {
                    confirmEmptyArchive = .emptyArchive(count: schemes.count)
                }
                .disabled(schemes.isEmpty)
            }

            if expanded {
                if schemes.isEmpty {
                    Text("No archived schemes")
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(theme.textMuted)
                        .padding(.horizontal, compact ? 25 : 28)
                        .frame(height: compact ? 20 : 24)
                } else {
                    ForEach(schemes) { scheme in
                        ArchiveSchemeRow(scheme: scheme, theme: theme, compact: compact)
                    }
                }
            }
        }
        .destructiveConfirmation(target: $confirmEmptyArchive) { _ in
            model.emptyArchive()
        }
    }
}

private struct ArchiveSchemeRow: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    let compact: Bool
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?

    var body: some View {
        SwipeActionRow(
            actionWidth: compact ? 70 : 82,
            actionTint: theme.danger,
            allowsFullSwipe: false,
            action: { confirmPermanentDelete = .permanentlyDeleteScheme(scheme) }
        ) {
            Label("Delete", systemImage: "trash")
        } content: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(schemeColor(scheme.colorIndex, dark: theme.isDark).opacity(0.7))
                    .frame(width: compact ? 9 : 10, height: compact ? 9 : 10)
                Text(scheme.displayName)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, compact ? 22 : 26)
            .padding(.trailing, compact ? 6 : 8)
            .frame(height: compact ? 22 : 25)
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                model.restoreScheme(id: scheme.id)
            }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { _ in
            model.permanentlyDeleteScheme(id: scheme.id)
        }
    }
}

private struct SettingsArchiveSection: View {
    let schemes: [MobileScheme]
    let theme: KnotQTheme

    var body: some View {
        Section {
            NavigationLink {
                SettingsArchiveList(theme: theme)
            } label: {
                HStack(spacing: 10) {
                    Label("Archived Schemes", systemImage: "archivebox")
                    Spacer(minLength: 0)
                    Text("\(schemes.count)")
                        .foregroundStyle(theme.textMuted)
                }
            }
        } header: {
            Text("Archive")
        } footer: {
            if !schemes.isEmpty {
                Text("Open Archive to restore schemes.")
            }
        }
    }
}

private struct SettingsArchiveList: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        Form {
            Section {
                if schemes.isEmpty {
                    Text("No archived schemes")
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(schemes) { scheme in
                        SettingsArchiveRow(scheme: scheme, theme: theme)
                    }
                    Button("Empty Archive", systemImage: "trash", role: .destructive) {
                        confirmEmptyArchive = .emptyArchive(count: schemes.count)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .navigationTitle("Archive")
        .destructiveConfirmation(target: $confirmEmptyArchive) { _ in
            model.emptyArchive()
        }
    }

    private var schemes: [MobileScheme] {
        model.snapshot?.archivedSchemes ?? []
    }
}

private struct SettingsArchiveRow: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(schemeColor(scheme.colorIndex, dark: theme.isDark).opacity(0.72))
                .frame(width: 11, height: 11)
            Text(scheme.displayName)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Restore") {
                model.restoreScheme(id: scheme.id)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                model.restoreScheme(id: scheme.id)
            }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { _ in
            model.permanentlyDeleteScheme(id: scheme.id)
        }
    }
}

private struct DesktopSchemePane: View {
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
        .background(theme.bgApp)
        .navigationTitle(usesNativeNavigation ? "Daily" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesNativeNavigation {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
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

private struct DailyEditorNavigationBar: View {
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

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(TitleIconButton(theme: theme))
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }
}

private struct DailyDayEditorSection: View {
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

private struct DesktopItemRow: View {
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

private struct DesktopSearchPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    let onOpenScheme: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @GestureState private var searchBarDragOffset: CGFloat = 0

    var body: some View {
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
                                .fill(schemeColor(hit.colorIndex ?? 0, dark: theme.isDark))
                                .frame(width: 1.5)
                                .padding(.vertical, 7)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.schemeName.isEmpty ? hit.targetKind.capitalized : hit.schemeName)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(schemeColor(hit.colorIndex ?? 0, dark: theme.isDark))
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
            .padding(.bottom, searchFocused ? 16 : 28)
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
            .background(
                LinearGradient(
                    colors: [theme.bgApp.opacity(0), theme.bgApp.opacity(0.95), theme.bgApp],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
        .onAppear {
            model.search(query)
            // Prefill the cursor: focus the field as soon as the pane appears.
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

private struct DesktopSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var showingSyncSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: themeBinding) {
                        Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                        Label("Dark", systemImage: "moon.fill").tag("dark")
                        Label("Light", systemImage: "sun.max.fill").tag("light")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Appearance")
                }

                Section {
                    Picker("Clock", selection: timeBinding) {
                        Text("12-hour").tag("twelve_hour")
                        Text("24-hour").tag("twenty_four_hour")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Time")
                }

                SettingsArchiveSection(schemes: model.snapshot?.archivedSchemes ?? [], theme: theme)

                GoogleCalendarSettingsSection(theme: theme)

                Section {
                    if let session = model.syncSession {
                        LabeledContent("Account", value: session.email)
                        LabeledContent("Backend", value: session.apiBase)
                        LabeledContent("Status") {
                            if model.syncInProgress {
                                ProgressView()
                            } else {
                                Text(session.supportsSync ? "Enabled" : "Not allowed")
                                    .foregroundStyle(session.supportsSync ? theme.textDim : theme.danger)
                            }
                        }
                        Button("Manage Sync Account", systemImage: "person.crop.circle") {
                            showingSyncSignIn = true
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            model.signOutSync()
                        }
                    } else {
                        LabeledContent("Status") {
                            Text("Not signed in")
                                .foregroundStyle(theme.textDim)
                        }
                        Button("Sign in to Sync", systemImage: "person.crop.circle") {
                            showingSyncSignIn = true
                        }
                    }
                } header: {
                    Text("Sync")
                }

            }
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Settings")
        }
        .tint(theme.accent)
        .sheet(isPresented: $showingSyncSignIn) {
            SyncSignInSheet(theme: theme)
                .environmentObject(model)
                .presentationDetents([.medium])
        }
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { model.snapshot?.settings.themeMode ?? "dark" },
            set: { model.setThemeMode($0) }
        )
    }

    private var timeBinding: Binding<String> {
        Binding(
            get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
            set: { model.setTimeFormat($0) }
        )
    }

}

private struct MobileDock: View {
    let selected: MobilePane
    let theme: KnotQTheme
    let onSelect: (MobilePane) -> Void

    private let panes: [MobilePane] = [.home, .calendar, .search, .settings]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(panes) { pane in
                Button { onSelect(pane) } label: {
                    Image(systemName: pane.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selected == pane ? theme.textPrimary : theme.textMuted)
                        .frame(width: 46, height: 48)
                        .background {
                            if selected == pane {
                                Circle()
                                    .fill(theme.rowSelected)
                                    .frame(width: 40, height: 40)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.title)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(theme.isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(theme.bgToolbar), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.borderOverlay, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(theme.isDark ? 0.28 : 0.025), radius: theme.isDark ? 12 : 4, y: theme.isDark ? 4 : 1)
    }
}

private struct ColorSwatchStrip: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach([0, 1, 5, 2, 3, 4], id: \.self) { index in
                Button {
                    model.setSchemeColor(id: scheme.id, colorIndex: Int32(index))
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(schemeColor(Int32(index), dark: theme.isDark))
                        .frame(width: 18, height: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(scheme.colorIndex == Int32(index) ? theme.accent : Color.clear, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ColorMenu: View {
    @EnvironmentObject private var model: AppModel
    let nodeID: String
    let colorIndex: Int32
    let theme: KnotQTheme

    var body: some View {
        Menu {
            ForEach(0..<6, id: \.self) { index in
                Button {
                    model.setSchemeColor(id: nodeID, colorIndex: Int32(index))
                } label: {
                    Label {
                        Text(index == Int(colorIndex) ? "Selected" : "")
                    } icon: {
                        Image(systemName: colorIndex == Int32(index) ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                colorIndex == Int32(index) ? theme.textPrimary : schemeColor(Int32(index), dark: theme.isDark),
                                schemeColor(Int32(index), dark: theme.isDark)
                            )
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    let theme: KnotQTheme

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textDim)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String) -> String {
    return occurrenceTimeLabel(occurrence, timeFormat: timeFormat, showDay: false)
}

private func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String, showDay: Bool) -> String {
    let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat)
    let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat)
    if !showDay {
        if occurrence.kind == "reminder", let start { return "At \(start)" }
        if occurrence.kind == "assignment", let end { return "Due \(end)" }
        if let start, let end { return "\(start) - \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return occurrence.kind.capitalized
    }

    if occurrence.kind == "reminder", let raw = occurrence.start, let date = MobileDate.parseDateTime(raw) {
        if let rawTime = upcomingTimeLabel(raw: raw, timeFormat: timeFormat) {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "At \(rawTime)" : "At \(dayPrefix) \(rawTime)"
        }
    }
    if occurrence.kind == "assignment", let raw = occurrence.end, let date = MobileDate.parseDateTime(raw) {
        if let rawTime = upcomingTimeLabel(raw: raw, timeFormat: timeFormat) {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "Due \(rawTime)" : "Due \(dayPrefix) \(rawTime)"
        }
    }
    if let rawStart = occurrence.start, let rawEnd = occurrence.end,
       let startDate = MobileDate.parseDateTime(rawStart),
       let endDate = MobileDate.parseDateTime(rawEnd),
       let startTime = upcomingTimeLabel(raw: rawStart, timeFormat: timeFormat),
       let endTime = upcomingTimeLabel(raw: rawEnd, timeFormat: timeFormat)
    {
        let from = upcomingDatePrefix(date: startDate)
        let to = upcomingDatePrefix(date: endDate)
        let fromText = from.isEmpty ? startTime : "\(from) \(startTime)"
        let toText = to.isEmpty ? endTime : "\(to) \(endTime)"
        return "\(fromText) → \(toText)"
    }
    if let rawStart = occurrence.start, let startDate = MobileDate.parseDateTime(rawStart), let startTime = upcomingTimeLabel(raw: rawStart, timeFormat: timeFormat) {
        let dayPrefix = upcomingDatePrefix(date: startDate)
        return dayPrefix.isEmpty ? startTime : "\(dayPrefix) \(startTime)"
    }
    if let rawEnd = occurrence.end, let endDate = MobileDate.parseDateTime(rawEnd), let endTime = upcomingTimeLabel(raw: rawEnd, timeFormat: timeFormat) {
        let dayPrefix = upcomingDatePrefix(date: endDate)
        return dayPrefix.isEmpty ? "Due \(endTime)" : "Due \(dayPrefix) \(endTime)"
    }
    return occurrence.kind.capitalized
}

private func upcomingTimeLabel(raw: String, timeFormat: String) -> String? {
    guard let date = MobileDate.parseDateTime(raw) else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if timeFormat == "twenty_four_hour" {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: date)
}

private func upcomingDatePrefix(date: Date) -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let target = calendar.startOfDay(for: date)
    if target == today { return "" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), target == tomorrow {
        return "Tomorrow"
    }
    if let inAWeek = calendar.date(byAdding: .day, value: 7, to: today), target < inAWeek && target > today {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}

    private func occurrenceStatusTimeColor(_ occurrence: MobileOccurrence, theme: KnotQTheme) -> Color {
    guard !occurrence.done else { return theme.textMuted }
    let now = Date()
    let anchorRaw = occurrence.kind == "assignment"
        ? occurrence.end
        : (occurrence.start ?? occurrence.end)
    guard let anchorRaw, let anchor = MobileDate.parseDateTime(anchorRaw) else {
        return theme.textSoft
    }
    if occurrence.kind == "event",
       let end = MobileDate.parseDateTime(occurrence.end),
       anchor <= now,
       end > now {
        return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
    }
    if anchor < now {
        return theme.isDark ? Color(hex: 0xff5a53) : Color(hex: 0xd20f39)
    }
    let startDay = Calendar.current.startOfDay(for: anchor)
    let today = Calendar.current.startOfDay(for: now)
    let dayDiff = Calendar.current.dateComponents([.day], from: today, to: startDay).day ?? 0
    if dayDiff <= 0 {
        return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
    }
    if dayDiff <= 1 {
        return theme.isDark ? Color(hex: 0xe5e5ff) : Color(hex: 0x4f5f8f)
    }
    return theme.textSoft
}

func schemeColor(_ index: Int32, dark: Bool) -> Color {
    let darkPalette: [UInt32] = [0xff453a, 0xff9f0a, 0x30d158, 0x0a84ff, 0xbf5af2, 0xffd60a]
    let lightPalette: [UInt32] = [0xd4271c, 0xc47400, 0x1e9e40, 0x0064d2, 0x8a3db5, 0xe0a800]
    let palette = dark ? darkPalette : lightPalette
    return Color(hex: palette[Int(index) % palette.count])
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0
        )
    }
}
