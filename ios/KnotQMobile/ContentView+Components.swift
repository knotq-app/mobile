import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

struct DesktopTitleBar: View {
    let title: String
    let pane: MobilePane
    let scheme: MobileScheme?
    let theme: KnotQTheme
    let onSearch: () -> Void
    let onAddCalendar: () -> Void
    let onAddItem: () -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: () -> Void
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
                    Button("Google Calendar", systemImage: "calendar.badge.plus", action: onGoogleCalendar)
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
                    .listRowBackground(theme.bgModal)
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
                .listRowBackground(theme.bgModal)
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

struct DesktopNavigator: View {
    let root: MobileNode?
    let selectedPane: MobilePane
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectPane: (MobilePane) -> Void
    let onSelectScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void

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

            SchemeNavigatorListView(
                root: root,
                selectedSchemeID: selectedSchemeID,
                theme: theme,
                compact: true,
                onOpenScheme: onSelectScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    Button("Google Calendar", systemImage: "calendar.badge.plus") {
                        onGoogleCalendar(nil)
                    }
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

struct NavigatorSpecialRow: View {
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

func findNode(id: String, in node: MobileNode) -> MobileNode? {
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

func findChildPlacement(childID: String, in node: MobileNode) -> (parentID: String, position: Int)? {
    for (index, child) in node.children.enumerated() {
        if child.id == childID {
            return (node.id, index)
        }
        if let found = findChildPlacement(childID: childID, in: child) {
            return found
        }
    }
    return nil
}

func containsNode(_ targetID: String, within container: MobileNode) -> Bool {
    for child in container.children {
        if child.id == targetID || containsNode(targetID, within: child) {
            return true
        }
    }
    return false
}

struct SchemeTreePrefix: View {
    let depth: Int
    let showsDisclosure: Bool
    let expanded: Bool
    let compact: Bool
    let theme: KnotQTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<visibleDepth, id: \.self) { _ in
                Color.clear
                    .frame(width: indentUnit, height: rowHeight)
            }
            if showsDisclosure {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: disclosureWidth)
            } else {
                Color.clear
                    .frame(width: 0, height: rowHeight)
            }
        }
        .frame(height: rowHeight)
    }

    private var indentUnit: CGFloat { compact ? 8 : 9 }
    private var disclosureWidth: CGFloat { compact ? 12 : 14 }
    private var rowHeight: CGFloat { compact ? 25 : 30 }
    private var visibleDepth: Int { max(0, depth) }
}

struct SchemeTreeIconSlot<Content: View>: View {
    let compact: Bool
    let content: Content

    init(compact: Bool, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: compact ? 14 : 17, height: compact ? 14 : 17)
    }
}

struct DesktopUpcomingRail: View {
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
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HomeQuickWriteButtons(theme: theme, onNewScheme: onNewScheme, onOpenDaily: onOpenDaily)
                    .padding(.trailing, 22)
                    .padding(.bottom, 92)
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
                    .padding(.bottom, 92)
                }
                .scrollDismissesKeyboard(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

struct SchemeNavigatorListView: UIViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let root: MobileNode?
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let compact: Bool
    let onOpenScheme: (String) -> Void

    func makeUIView(context: Context) -> SchemeNavigatorUIKitView {
        SchemeNavigatorUIKitView()
    }

    func updateUIView(_ uiView: SchemeNavigatorUIKitView, context: Context) {
        uiView.configure(
            root: root,
            selectedSchemeID: selectedSchemeID,
            theme: theme,
            compact: compact,
            onOpenScheme: onOpenScheme,
            onMoveNode: { kind, id, folderID, position in
                model.moveNode(kind: kind, id: id, folderID: folderID, position: position)
            },
            onArchiveScheme: { id in
                model.archiveScheme(id: id)
            },
            onArchiveFolder: { id in
                model.archiveFolder(id: id)
            }
        )
    }
}

final class SchemeNavigatorUIKitView: UIView, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate {
    private struct Row: Equatable {
        let node: MobileNode
        let depth: Int
        let parentID: String
        let siblingIndex: Int

        var id: String { node.id }
    }

    private struct Placement {
        let folderID: String
        let position: Int
        let intent: UITableViewDropProposal.Intent
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var root: MobileNode?
    private var rows: [Row] = []
    private var expandedFolderIDs = Set<String>()
    private var knownFolderIDs = Set<String>()
    private var selectedSchemeID: String?
    private var theme: KnotQTheme = .dark
    private var compact = false
    private var onOpenScheme: (String) -> Void = { _ in }
    private var onMoveNode: (String, String, String, Int) -> Void = { _, _, _, _ in }
    private var onArchiveScheme: (String) -> Void = { _ in }
    private var onArchiveFolder: (String) -> Void = { _ in }

    private var rowHeight: CGFloat { compact ? 27 : 34 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(tableView)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.register(SchemeNavigatorCell.self, forCellReuseIdentifier: SchemeNavigatorCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.showsVerticalScrollIndicator = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.keyboardDismissMode = .none
        tableView.alwaysBounceVertical = true
        tableView.delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
    }

    func configure(
        root: MobileNode?,
        selectedSchemeID: String?,
        theme: KnotQTheme,
        compact: Bool,
        onOpenScheme: @escaping (String) -> Void,
        onMoveNode: @escaping (String, String, String, Int) -> Void,
        onArchiveScheme: @escaping (String) -> Void,
        onArchiveFolder: @escaping (String) -> Void
    ) {
        let styleChanged = self.selectedSchemeID != selectedSchemeID || self.compact != compact || self.theme.isDark != theme.isDark
        self.onOpenScheme = onOpenScheme
        self.onMoveNode = onMoveNode
        self.onArchiveScheme = onArchiveScheme
        self.onArchiveFolder = onArchiveFolder
        tableView.contentInset = UIEdgeInsets(top: compact ? 1 : 4, left: 0, bottom: compact ? 4 : 5, right: 0)
        tableView.backgroundColor = .clear
        syncExpandedFolders(root)
        let nextRows = makeRows(root: root)
        let rowsChanged = rows != nextRows
        self.root = root
        self.selectedSchemeID = selectedSchemeID
        self.theme = theme
        self.compact = compact
        rows = nextRows
        if rowsChanged || styleChanged {
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SchemeNavigatorCell.reuseIdentifier, for: indexPath) as? SchemeNavigatorCell
            ?? SchemeNavigatorCell(style: .default, reuseIdentifier: SchemeNavigatorCell.reuseIdentifier)
        let row = rows[indexPath.row]
        cell.configure(
            row: row.node,
            depth: row.depth,
            expanded: expandedFolderIDs.contains(row.id),
            selected: selectedSchemeID == row.id,
            theme: theme,
            compact: compact
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = rows[indexPath.row]
        if row.node.kind == "folder" {
            toggleFolder(row.id)
        } else {
            onOpenScheme(row.id)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let row = rows[indexPath.row]
        let action = UIContextualAction(style: .normal, title: "Archive") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            if row.node.kind == "folder" {
                self.onArchiveFolder(row.id)
            } else {
                self.onArchiveScheme(row.id)
            }
            completion(true)
        }
        action.image = UIImage(systemName: "archivebox")
        action.backgroundColor = UIColor(theme.danger)
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        let row = rows[indexPath.row]
        let provider = NSItemProvider(object: row.id as NSString)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = row.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return [item]
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        draggedID(from: session) != nil
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard let draggedID = draggedID(from: session),
              let placement = placement(for: draggedID, at: session.location(in: tableView)) else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: placement.intent)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let draggedID = draggedID(from: coordinator.session),
              let root,
              let draggedNode = findNode(id: draggedID, in: root),
              let placement = placement(for: draggedID, at: coordinator.session.location(in: tableView)) else {
            return
        }
        let destinationIndexPath = applyOptimisticMove(draggedID: draggedID, placement: placement)
        if let item = coordinator.items.first {
            coordinator.drop(
                item.dragItem,
                to: dropPreviewTarget(
                    for: destinationIndexPath,
                    fallback: coordinator.session.location(in: tableView)
                )
            )
        }
        onMoveNode(
            draggedNode.kind == "folder" ? "folder" : "scheme",
            draggedID,
            placement.folderID,
            placement.position
        )
    }

    private func toggleFolder(_ id: String) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
        rows = makeRows(root: root)
        tableView.reloadData()
    }

    private func makeRows(root: MobileNode?) -> [Row] {
        guard let root else { return [] }
        var next: [Row] = []
        appendRows(root.children, parentID: root.id, depth: 0, into: &next)
        return next
    }

    private func appendRows(_ nodes: [MobileNode], parentID: String, depth: Int, into rows: inout [Row]) {
        for (index, node) in nodes.enumerated() {
            rows.append(Row(node: node, depth: depth, parentID: parentID, siblingIndex: index))
            if node.kind == "folder", expandedFolderIDs.contains(node.id) {
                appendRows(node.children, parentID: node.id, depth: depth + 1, into: &rows)
            }
        }
    }

    private func syncExpandedFolders(_ root: MobileNode?) {
        var folderIDs = Set<String>()
        if let root {
            collectFolderIDs(from: root.children, into: &folderIDs)
        }
        if knownFolderIDs.isEmpty {
            expandedFolderIDs = folderIDs
        } else {
            expandedFolderIDs = expandedFolderIDs.intersection(folderIDs)
            expandedFolderIDs.formUnion(folderIDs.subtracting(knownFolderIDs))
        }
        knownFolderIDs = folderIDs
    }

    private func collectFolderIDs(from nodes: [MobileNode], into folderIDs: inout Set<String>) {
        for node in nodes where node.kind == "folder" {
            folderIDs.insert(node.id)
            collectFolderIDs(from: node.children, into: &folderIDs)
        }
    }

    private func applyOptimisticMove(draggedID: String, placement: Placement) -> IndexPath? {
        guard let optimistic = optimisticTree(moving: draggedID, placement: placement) else {
            return nil
        }
        let nextRoot = optimistic.root
        let nextRows = optimistic.rows
        guard rows != nextRows else {
            root = nextRoot
            return targetIndexPath(draggedID: draggedID, placement: placement, rows: nextRows)
        }

        applyRowDiff(root: nextRoot, rows: nextRows)
        return targetIndexPath(draggedID: draggedID, placement: placement, rows: nextRows)
    }

    private func applyRowDiff(root nextRoot: MobileNode, rows nextRows: [Row]) {
        let oldIDs = rows.map(\.id)
        let newIDs = nextRows.map(\.id)
        let diff = newIDs.difference(from: oldIDs).inferringMoves()

        var deletes: [IndexPath] = []
        var inserts: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []

        for change in diff {
            switch change {
            case .remove(let offset, _, let associatedWith):
                if let associatedWith {
                    moves.append((
                        from: IndexPath(row: offset, section: 0),
                        to: IndexPath(row: associatedWith, section: 0)
                    ))
                } else {
                    deletes.append(IndexPath(row: offset, section: 0))
                }
            case .insert(let offset, _, let associatedWith):
                if associatedWith == nil {
                    inserts.append(IndexPath(row: offset, section: 0))
                }
            }
        }

        tableView.performBatchUpdates {
            root = nextRoot
            rows = nextRows
            tableView.deleteRows(at: deletes, with: .automatic)
            tableView.insertRows(at: inserts, with: .automatic)
            for move in moves {
                tableView.moveRow(at: move.from, to: move.to)
            }
        }
        tableView.layoutIfNeeded()
    }

    private func targetIndexPath(draggedID: String, placement: Placement, rows: [Row]) -> IndexPath? {
        if let index = rows.firstIndex(where: { $0.id == draggedID }) {
            return IndexPath(row: index, section: 0)
        }
        if let index = rows.firstIndex(where: { $0.id == placement.folderID }) {
            return IndexPath(row: index, section: 0)
        }
        return nil
    }

    private func optimisticTree(moving draggedID: String, placement: Placement) -> (root: MobileNode, rows: [Row])? {
        guard var nextRoot = root,
              let draggedNode = removeNode(id: draggedID, from: &nextRoot),
              insertNode(draggedNode, intoFolderID: placement.folderID, position: placement.position, in: &nextRoot) else {
            return nil
        }
        return (nextRoot, makeRows(root: nextRoot))
    }

    private func dropPreviewTarget(for indexPath: IndexPath?, fallback: CGPoint) -> UIDragPreviewTarget {
        guard let indexPath, rows.indices.contains(indexPath.row) else {
            return UIDragPreviewTarget(container: tableView, center: fallback)
        }
        tableView.layoutIfNeeded()
        let rect = tableView.rectForRow(at: indexPath)
        let visible = tableView.bounds.insetBy(dx: 0, dy: 4)
        let center = CGPoint(
            x: min(max(rect.midX, visible.minX), visible.maxX),
            y: min(max(rect.midY, visible.minY), visible.maxY)
        )
        return UIDragPreviewTarget(container: tableView, center: center)
    }

    private func removeNode(id: String, from parent: inout MobileNode) -> MobileNode? {
        if let index = parent.children.firstIndex(where: { $0.id == id }) {
            return parent.children.remove(at: index)
        }
        for index in parent.children.indices {
            if let removed = removeNode(id: id, from: &parent.children[index]) {
                return removed
            }
        }
        return nil
    }

    private func insertNode(_ node: MobileNode, intoFolderID folderID: String, position: Int, in parent: inout MobileNode) -> Bool {
        if parent.id == folderID {
            parent.children.insert(node, at: max(0, min(position, parent.children.count)))
            return true
        }
        for index in parent.children.indices where parent.children[index].kind == "folder" {
            if insertNode(node, intoFolderID: folderID, position: position, in: &parent.children[index]) {
                return true
            }
        }
        return false
    }

    private func draggedID(from session: UIDropSession) -> String? {
        session.localDragSession?.items.compactMap { $0.localObject as? String }.first
    }

    private func placement(for draggedID: String, at location: CGPoint) -> Placement? {
        guard let root,
              let draggedNode = findNode(id: draggedID, in: root),
              let source = findChildPlacement(childID: draggedID, in: root) else {
            return nil
        }

        guard let indexPath = tableView.indexPathForRow(at: location), rows.indices.contains(indexPath.row) else {
            let targetPosition = root.children.count
            return adjustedPlacement(
                source: source,
                draggedNode: draggedNode,
                folderID: root.id,
                position: targetPosition,
                intent: .insertAtDestinationIndexPath
            )
        }

        let row = rows[indexPath.row]
        guard row.id != draggedID else { return nil }
        let frame = tableView.rectForRow(at: indexPath)
        let localY = max(0, min(frame.height, location.y - frame.minY))

        if row.node.kind == "folder",
           localY > frame.height * 0.30,
           localY < frame.height * 0.70 {
            guard draggedNode.kind != "folder" || !containsNode(row.id, within: draggedNode) else {
                return nil
            }
            return adjustedPlacement(
                source: source,
                draggedNode: draggedNode,
                folderID: row.id,
                position: row.node.children.count,
                intent: .insertIntoDestinationIndexPath
            )
        }

        let insertAfter = localY >= frame.height * 0.5
        let targetPosition = row.siblingIndex + (insertAfter ? 1 : 0)
        return adjustedPlacement(
            source: source,
            draggedNode: draggedNode,
            folderID: row.parentID,
            position: targetPosition,
            intent: .insertAtDestinationIndexPath
        )
    }

    private func adjustedPlacement(
        source: (parentID: String, position: Int),
        draggedNode: MobileNode,
        folderID: String,
        position: Int,
        intent: UITableViewDropProposal.Intent
    ) -> Placement? {
        guard let root,
              let targetParent = findNode(id: folderID, in: root) else {
            return nil
        }
        if draggedNode.kind == "folder" {
            guard folderID != draggedNode.id && !containsNode(folderID, within: draggedNode) else {
                return nil
            }
        }

        let sameParent = source.parentID == folderID
        var adjustedPosition = position
        if sameParent, source.position < position {
            adjustedPosition = max(0, adjustedPosition - 1)
        }
        let targetCount = targetParent.children.count - (sameParent ? 1 : 0)
        adjustedPosition = max(0, min(adjustedPosition, max(0, targetCount)))
        if sameParent, adjustedPosition == source.position {
            return nil
        }
        return Placement(folderID: folderID, position: adjustedPosition, intent: intent)
    }
}

private final class SchemeNavigatorCell: UITableViewCell {
    static let reuseIdentifier = "SchemeNavigatorCell"

    private let selectedFill = UIView()
    private let iconView = UIImageView()
    private let colorSquare = UIView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var depth = 0
    private var compact = false
    private var nodeKind = "scheme"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        selectedFill.layer.cornerRadius = 4
        selectedFill.layer.cornerCurve = .continuous
        contentView.addSubview(selectedFill)
        contentView.addSubview(iconView)
        contentView.addSubview(colorSquare)
        contentView.addSubview(titleLabel)
        contentView.addSubview(chevronView)
        colorSquare.layer.cornerRadius = 3
        colorSquare.layer.cornerCurve = .continuous
        titleLabel.lineBreakMode = .byTruncatingTail
        chevronView.contentMode = .scaleAspectFit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row node: MobileNode,
        depth: Int,
        expanded: Bool,
        selected: Bool,
        theme: KnotQTheme,
        compact: Bool
    ) {
        self.depth = depth
        self.compact = compact
        self.nodeKind = node.kind

        selectedFill.backgroundColor = selected ? UIColor(theme.rowSelected) : .clear
        titleLabel.text = node.name
        titleLabel.textColor = UIColor(theme.textPrimary)
        titleLabel.font = .systemFont(ofSize: compact ? 13 : 14, weight: node.kind == "folder" ? .semibold : .medium)
        chevronView.tintColor = UIColor(theme.textMuted)
        chevronView.isHidden = node.kind == "folder"

        if node.kind == "folder" {
            iconView.isHidden = false
            colorSquare.isHidden = true
            let config = UIImage.SymbolConfiguration(pointSize: compact ? 12 : 14, weight: .semibold)
            iconView.image = UIImage(systemName: expanded ? "folder.fill" : "folder", withConfiguration: config)
            iconView.tintColor = UIColor(theme.textMuted)
        } else {
            iconView.isHidden = true
            colorSquare.isHidden = false
            colorSquare.backgroundColor = UIColor(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leftInset: CGFloat = compact ? 6 : 8
        let rightInset: CGFloat = compact ? 6 : 8
        let indent = CGFloat(max(0, depth)) * (compact ? 12 : 14)
        let iconSize: CGFloat = compact ? 14 : 17
        let squareSize: CGFloat = compact ? 11 : 12
        let rowY: CGFloat = compact ? 1 : 2
        selectedFill.frame = CGRect(x: 3, y: rowY, width: bounds.width - 6, height: bounds.height - rowY * 2)

        let iconX = leftInset + indent
        let iconY = (bounds.height - iconSize) * 0.5
        iconView.frame = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        colorSquare.frame = CGRect(
            x: iconX + (iconSize - squareSize) * 0.5,
            y: (bounds.height - squareSize) * 0.5,
            width: squareSize,
            height: squareSize
        )

        let chevronSize: CGFloat = compact ? 12 : 14
        let chevronX = bounds.width - rightInset - chevronSize
        chevronView.frame = CGRect(x: chevronX, y: (bounds.height - chevronSize) * 0.5, width: chevronSize, height: chevronSize)

        let titleX = iconX + iconSize + 8
        let titleRight = nodeKind == "folder" ? bounds.width - rightInset : chevronX - 4
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, titleRight - titleX), height: bounds.height)
    }
}

struct SwipeActionRow<Content: View, ActionLabel: View>: View {
    let actionWidth: CGFloat
    let actionTint: Color
    let allowsFullSwipe: Bool
    private let openThreshold: CGFloat = 0.38
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
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.17), value: restingOffset)
    }

    private var currentOffset: CGFloat {
        let raw = restingOffset + dragOffset
        if raw <= -actionWidth {
            // Give a tiny overscroll feel after reveal instead of a hard stop.
            let overdraw = raw + actionWidth
            return -actionWidth + overdraw * 0.28
        }
        return max(-actionWidth * 1.2, min(0, raw))
    }

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.25 else { return }
                let raw = restingOffset + dx
                if raw <= -actionWidth {
                    state = -actionWidth + (raw + actionWidth) * 0.28 - restingOffset
                } else {
                    state = dx
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.25 else { return }
                let projected = restingOffset + value.predictedEndTranslation.width
                let velocity = value.velocity.width
                if allowsFullSwipe && (
                    projected < -actionWidth * 1.35
                    || (velocity < -1100 && projected < -actionWidth * 0.55)
                ) {
                    performAction()
                    return
                }
                withAnimation(.interactiveSpring(response: 0.27, dampingFraction: 0.9, blendDuration: 0.16)) {
                    if projected < -actionWidth * openThreshold {
                        restingOffset = -actionWidth
                    } else {
                        restingOffset = 0
                    }
                }
            }
    }

    private func performAction() {
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.86, blendDuration: 0.16)) {
            restingOffset = 0
        }
        action()
    }
}

struct HomeGlassSurface: ViewModifier {
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

extension View {
    func homeGlassSurface(theme: KnotQTheme, cornerRadius: CGFloat = 8, shadow: Bool = true) -> some View {
        modifier(HomeGlassSurface(theme: theme, cornerRadius: cornerRadius, shadow: shadow))
    }
}

struct HomeQuickActions: View {
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

struct HomeQuickWriteButtons: View {
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

struct HomeDailyPreview: View {
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

struct HomeDailyPreviewRenderedRow: Identifiable {
    let item: MobileItem
    let ordinal: Int
    var id: String { item.id }
}

struct HomeDailyPreviewRenderedList: UIViewRepresentable {
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

final class HomeDailyPreviewRendererView: UIView {
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


struct UpcomingSection: View {
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

struct DesktopCalendarPane: View {
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

// MARK: - DayTimelinePane (UIKit-backed Apple Calendar-style day timeline)

struct DayTimelinePane: UIViewRepresentable {
    let calendar: MobileCalendar?
    let selectedDate: Date
    let theme: KnotQTheme
    let timeFormat: String
    let onSetDate: (Date) -> Void
    let onShiftDay: (Int) -> Void
    let onCreate: (Date) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void

    func makeUIView(context: Context) -> DayTimelineUIKitView {
        DayTimelineUIKitView()
    }

    func updateUIView(_ uiView: DayTimelineUIKitView, context: Context) {
        uiView.configure(
            calendar: calendar,
            selectedDate: selectedDate,
            theme: theme,
            timeFormat: timeFormat,
            onSetDate: onSetDate,
            onShiftDay: onShiftDay,
            onCreate: onCreate,
            onOpenOccurrence: onOpenOccurrence,
            onMoveOccurrence: onMoveOccurrence
        )
    }
}

final class DayTimelineUIKitView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private struct CreateDraft: Equatable {
        let dayIndex: Int
        let startMinute: CGFloat
    }

    private struct LaidOccurrence {
        let occurrence: MobileOccurrence
        let dayIndex: Int
        let frame: CGRect
        let startMinute: CGFloat
        let endMinute: CGFloat
    }

    private struct MoveTarget: Equatable {
        let dayIndex: Int
        let startMinute: CGFloat
        let start: Date?
        let end: Date?
    }

    private final class DayCell: UIControl {
        let weekdayLabel = UILabel()
        let dayLabel = UILabel()
        let rangeBackground = UIView()
        var date = Date()

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(rangeBackground)
            addSubview(weekdayLabel)
            addSubview(dayLabel)
            weekdayLabel.textAlignment = .center
            weekdayLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            dayLabel.textAlignment = .center
            dayLabel.font = .systemFont(ofSize: 18, weight: .medium)
            rangeBackground.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            weekdayLabel.frame = CGRect(x: 0, y: 3, width: bounds.width, height: 14)
            rangeBackground.frame = CGRect(x: 2, y: 23, width: max(0, bounds.width - 4), height: 34)
            rangeBackground.layer.cornerRadius = 9
            dayLabel.frame = CGRect(x: 0, y: 23, width: bounds.width, height: 34)
        }
    }

    private final class EventBlockView: UIControl {
        let timeLabel = UILabel()
        let titleLabel = UILabel()
        let borderLine = UIView()
        var laid: LaidOccurrence?
        var onTap: ((MobileOccurrence) -> Void)?
        private var occurrence: MobileOccurrence?
        private var theme: KnotQTheme?
        private var timeFormat = "twelve_hour"

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            addSubview(timeLabel)
            addSubview(titleLabel)
            addSubview(borderLine)
            timeLabel.textAlignment = .center
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            timeLabel.lineBreakMode = .byTruncatingTail
            titleLabel.textAlignment = .center
            titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
            titleLabel.lineBreakMode = .byTruncatingTail
            addTarget(self, action: #selector(tapped), for: .touchUpInside)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(laid: LaidOccurrence, theme: KnotQTheme, timeFormat: String) {
            self.laid = laid
            self.occurrence = laid.occurrence
            self.theme = theme
            self.timeFormat = timeFormat
            alpha = laid.occurrence.done ? 0.55 : 1
            let title = laid.occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.text = title.isEmpty ? laid.occurrence.kind.capitalized : title
            timeLabel.text = Self.timeLabel(for: laid.occurrence, timeFormat: timeFormat)
            titleLabel.textColor = Self.itemTextColor(index: laid.occurrence.colorIndex, done: laid.occurrence.done, dark: theme.isDark)
            timeLabel.textColor = Self.timeColor(for: laid.occurrence, theme: theme)
            let isPill = laid.occurrence.kind == "reminder" || laid.occurrence.kind == "assignment"
            backgroundColor = theme.isDark
                ? UIColor(hex: 0x333333).withAlphaComponent(0.62)
                : UIColor(hex: 0xe6e8ec).withAlphaComponent(0.62)
            layer.cornerRadius = isPill ? 0 : 3
            layer.borderWidth = isPill ? 0 : 1.5
            layer.borderColor = (theme.isDark ? UIColor.white.withAlphaComponent(0.84) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)).cgColor
            borderLine.backgroundColor = theme.isDark ? UIColor.white.withAlphaComponent(0.84) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)
            borderLine.isHidden = !isPill
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let occurrence else { return }
            let hideTime = Self.hideTime(for: occurrence)
            let isReminder = occurrence.kind == "reminder"
            let isAssignment = occurrence.kind == "assignment"
            let topPadding: CGFloat = isReminder ? 6 : (isAssignment ? 3 : (hideTime ? 1 : 3))
            borderLine.frame = isReminder
                ? CGRect(x: 0, y: 0, width: bounds.width, height: 2)
                : CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
            if hideTime || timeLabel.text?.isEmpty == true {
                timeLabel.isHidden = true
                titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
                titleLabel.frame = CGRect(x: 6, y: topPadding, width: max(0, bounds.width - 12), height: 14)
            } else {
                timeLabel.isHidden = false
                titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
                timeLabel.frame = CGRect(x: 6, y: topPadding, width: max(0, bounds.width - 12), height: 11)
                titleLabel.frame = CGRect(x: 6, y: topPadding + 11, width: max(0, bounds.width - 12), height: 15)
            }
        }

        @objc private func tapped() {
            guard let occurrence else { return }
            onTap?(occurrence)
        }

        private static func timeLabel(for occurrence: MobileOccurrence, timeFormat: String) -> String {
            if occurrence.kind == "reminder", let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat) {
                return "At \(start)"
            }
            if occurrence.kind == "assignment", let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat) {
                return "Due \(end)"
            }
            let start = formatEventTime(occurrence.start, timeFormat: timeFormat, includePeriod: false)
            let end = formatEventTime(occurrence.end, timeFormat: timeFormat, includePeriod: true)
            if let start, let end { return "\(start) to \(end)" }
            if let start { return start }
            if let end { return "Due \(end)" }
            return ""
        }

        private static func formatEventTime(_ raw: String?, timeFormat: String, includePeriod: Bool) -> String? {
            guard let date = MobileDate.parseDateTime(raw) else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : (includePeriod ? "h:mm a" : "h:mm")
            return formatter.string(from: date)
        }

        private static func hideTime(for occurrence: MobileOccurrence) -> Bool {
            guard occurrence.kind == "event",
                  let start = MobileDate.parseDateTime(occurrence.start),
                  let end = MobileDate.parseDateTime(occurrence.end) else {
                return false
            }
            return end.timeIntervalSince(start) <= 30 * 60
        }

        private static func timeColor(for occurrence: MobileOccurrence, theme: KnotQTheme) -> UIColor {
            guard !occurrence.done,
                  let start = MobileDate.parseDateTime(occurrence.start ?? occurrence.end) else {
                return theme.isDark
                    ? UIColor(hex: 0xe8edf2).withAlphaComponent(0.90)
                    : UIColor(hex: 0x2e291f).withAlphaComponent(0.90)
            }
            let now = Date()
            if let end = MobileDate.parseDateTime(occurrence.end), start <= now, end > now {
                return theme.isDark ? UIColor(hex: 0xbfbfff) : UIColor(hex: 0x2f67cf)
            }
            if start < now {
                return theme.isDark ? UIColor(hex: 0xff5a53) : UIColor(hex: 0xd20f39)
            }
            let startDay = Calendar.current.startOfDay(for: start)
            let today = Calendar.current.startOfDay(for: now)
            let dayDiff = Calendar.current.dateComponents([.day], from: today, to: startDay).day ?? 0
            if dayDiff <= 0 {
                return theme.isDark ? UIColor(hex: 0xbfbfff) : UIColor(hex: 0x2f67cf)
            }
            if dayDiff <= 1 {
                return theme.isDark ? UIColor(hex: 0xe5e5ff) : UIColor(hex: 0x4f5f8f)
            }
            return theme.isDark
                ? UIColor(hex: 0xe8edf2).withAlphaComponent(0.90)
                : UIColor(hex: 0x2e291f).withAlphaComponent(0.90)
        }

        private static func itemTextColor(index: Int32, done: Bool, dark: Bool) -> UIColor {
            let darkPalette: [(CGFloat, CGFloat, CGFloat)] = [
                (1.00, 0.270, 0.227), (1.00, 0.624, 0.039), (0.188, 0.820, 0.345),
                (0.039, 0.518, 1.000), (0.749, 0.353, 0.949), (1.000, 0.839, 0.039),
            ]
            let lightPalette: [(CGFloat, CGFloat, CGFloat)] = [
                (0.831, 0.153, 0.110), (0.769, 0.455, 0.000), (0.118, 0.620, 0.251),
                (0.000, 0.392, 0.824), (0.541, 0.239, 0.710), (0.878, 0.659, 0.000),
            ]
            let rgb = (dark ? darkPalette : lightPalette)[Int(index) % darkPalette.count]
            let amount: CGFloat = done ? (dark ? 0.35 : 0.45) : (dark ? 0.70 : 0.90)
            let luma = rgb.0 * 0.299 + rgb.1 * 0.587 + rgb.2 * 0.114
            return UIColor(
                red: luma + (rgb.0 - luma) * amount,
                green: luma + (rgb.1 - luma) * amount,
                blue: luma + (rgb.2 - luma) * amount,
                alpha: done ? 0.78 : 1
            )
        }
    }

    private let titleLabel = UILabel()
    private let weekStrip = UIView()
    private let separator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let dayClip = UIView()
    private let dayCanvas = UIView()
    private let timeGutter = UIView()
    private let draftView = UIView()
    private let draftTimeLabel = UILabel()
    private let draftTitleLabel = UILabel()

    private var calendarSnapshot: MobileCalendar?
    private var selectedDate = Date()
    private var theme: KnotQTheme?
    private var timeFormat = "twelve_hour"
    private var onSetDate: (Date) -> Void = { _ in }
    private var onShiftDay: (Int) -> Void = { _ in }
    private var onCreate: (Date) -> Void = { _ in }
    private var onOpenOccurrence: (MobileOccurrence) -> Void = { _ in }
    private var onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void = { _, _, _ in }

    private var swipeOffset: CGFloat = 0
    private var didInitialScroll = false
    private var renderedBoundsSize: CGSize = .zero
    private var activeCreateDraft: CreateDraft?
    private var activeDragView: EventBlockView?
    private var activeDragStartFrame: CGRect = .zero
    private var activeDragStartLocation: CGPoint = .zero
    private var activeDragTarget: MoveTarget?
    private var activeDragSnapKey: String?

    private static let titleHeight: CGFloat = 47
    private static let weekHeight: CGFloat = 63
    private static let separatorHeight: CGFloat = 1
    private static let hourHeight: CGFloat = 44
    private static let gutterWidth: CGFloat = 50
    private static let timeYOffset: CGFloat = 8
    private static let hoursInDay = 24
    private static let bottomPadding: CGFloat = 88
    private static let timelineHeight = timeYOffset + CGFloat(hoursInDay) * hourHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(titleLabel)
        addSubview(weekStrip)
        addSubview(separator)
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(dayClip)
        contentView.addSubview(timeGutter)
        dayClip.addSubview(dayCanvas)
        dayCanvas.addSubview(draftView)
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        separator.isUserInteractionEnabled = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        dayClip.clipsToBounds = true
        draftView.isHidden = true
        draftView.layer.cornerRadius = 3
        draftView.layer.borderWidth = 1.5
        draftView.addSubview(draftTimeLabel)
        draftView.addSubview(draftTitleLabel)
        draftTimeLabel.textAlignment = .center
        draftTimeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        draftTitleLabel.text = "New Event"
        draftTitleLabel.textAlignment = .center
        draftTitleLabel.font = .systemFont(ofSize: 11, weight: .bold)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDayPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(pan)

        let createPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCreateLongPress(_:)))
        createPress.delegate = self
        createPress.minimumPressDuration = 0.45
        createPress.allowableMovement = 600
        scrollView.addGestureRecognizer(createPress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        calendar: MobileCalendar?,
        selectedDate: Date,
        theme: KnotQTheme,
        timeFormat: String,
        onSetDate: @escaping (Date) -> Void,
        onShiftDay: @escaping (Int) -> Void,
        onCreate: @escaping (Date) -> Void,
        onOpenOccurrence: @escaping (MobileOccurrence) -> Void,
        onMoveOccurrence: @escaping (MobileOccurrence, Date?, Date?) -> Void
    ) {
        self.calendarSnapshot = calendar
        self.selectedDate = Calendar.current.startOfDay(for: selectedDate)
        self.theme = theme
        self.timeFormat = timeFormat
        self.onSetDate = onSetDate
        self.onShiftDay = onShiftDay
        self.onCreate = onCreate
        self.onOpenOccurrence = onOpenOccurrence
        self.onMoveOccurrence = onMoveOccurrence
        backgroundColor = UIColor(theme.bgApp)
        titleLabel.textColor = UIColor(theme.textPrimary)
        separator.backgroundColor = UIColor(theme.dividerSoft)
        setNeedsLayout()
        renderAllIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        weekStrip.frame = CGRect(x: 0, y: Self.titleHeight, width: bounds.width, height: Self.weekHeight)
        separator.frame = CGRect(x: 0, y: Self.titleHeight + Self.weekHeight, width: bounds.width, height: Self.separatorHeight)
        scrollView.frame = CGRect(
            x: 0,
            y: Self.titleHeight + Self.weekHeight + Self.separatorHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.titleHeight - Self.weekHeight - Self.separatorHeight)
        )
        renderAllIfReady(force: renderedBoundsSize != bounds.size)
        renderedBoundsSize = bounds.size
    }

    private func renderAllIfReady(force: Bool = true) {
        guard bounds.width > 10, bounds.height > 10, let theme else { return }
        renderHeader(theme: theme)
        renderTimeline(theme: theme, preserveScroll: didInitialScroll || force)
    }

    private func renderHeader(theme: KnotQTheme) {
        titleLabel.text = monthTitle(for: selectedDate)
        weekStrip.subviews.forEach { $0.removeFromSuperview() }
        let sunday = weekStart(for: selectedDate)
        let cellWidth = bounds.width / 7
        for index in 0..<7 {
            let date = Calendar.current.date(byAdding: .day, value: index, to: sunday) ?? sunday
            let cell = DayCell(frame: CGRect(x: CGFloat(index) * cellWidth, y: 0, width: cellWidth, height: weekStrip.bounds.height))
            cell.date = date
            cell.weekdayLabel.text = weekdayInitial(date)
            cell.dayLabel.text = dayNumber(date)
            cell.weekdayLabel.textColor = isToday(date) || visibleDayKeys().contains(AppModel.dateOnly(date))
                ? UIColor(theme.textPrimary)
                : UIColor(theme.textMuted)
            cell.dayLabel.textColor = isToday(date) ? UIColor(theme.accent) : UIColor(theme.textPrimary)
            cell.rangeBackground.backgroundColor = visibleDayKeys().contains(AppModel.dateOnly(date))
                ? (theme.isDark ? UIColor.white.withAlphaComponent(0.09) : UIColor(hex: 0x3f6fd5).withAlphaComponent(0.08))
                : .clear
            cell.addTarget(self, action: #selector(handleWeekdayTap(_:)), for: .touchUpInside)
            weekStrip.addSubview(cell)
        }
    }

    private func renderTimeline(theme: KnotQTheme, preserveScroll: Bool) {
        let previousOffset = scrollView.contentOffset
        let visibleCount = visibleDayCount()
        let width = max(1, bounds.width)
        let colWidth = max(1, (width - Self.gutterWidth) / CGFloat(visibleCount))
        let dayCanvasWidth = colWidth * CGFloat(visibleCount + 2)

        contentView.frame = CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight + Self.bottomPadding)
        scrollView.contentSize = contentView.bounds.size
        dayClip.frame = CGRect(x: Self.gutterWidth, y: 0, width: max(0, width - Self.gutterWidth), height: Self.timelineHeight)
        timeGutter.frame = CGRect(x: 0, y: 0, width: Self.gutterWidth, height: Self.timelineHeight)
        dayCanvas.frame = CGRect(x: -colWidth + swipeOffset, y: 0, width: dayCanvasWidth, height: Self.timelineHeight)

        timeGutter.subviews.forEach { $0.removeFromSuperview() }
        timeGutter.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        dayCanvas.subviews.filter { $0 !== draftView }.forEach { $0.removeFromSuperview() }
        dayCanvas.layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        drawTimeGutter(theme: theme)
        drawGrid(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        drawNowLine(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        drawEvents(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        updateDraftView(colWidth: colWidth)

        if !didInitialScroll {
            didInitialScroll = true
            let focusHour = hasToday() ? max(0, Calendar.current.component(.hour, from: Date()) - 1) : 7
            let y = min(max(0, Self.timeYOffset + CGFloat(focusHour) * Self.hourHeight), max(0, scrollView.contentSize.height - scrollView.bounds.height))
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        } else if preserveScroll {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, previousOffset.y), maxY)), animated: false)
        }
    }

    private func drawTimeGutter(theme: KnotQTheme) {
        timeGutter.backgroundColor = UIColor(theme.bgApp)
        for hour in 0..<Self.hoursInDay {
            let label = UILabel(frame: CGRect(x: 0, y: Self.timeYOffset + CGFloat(hour) * Self.hourHeight - 6, width: Self.gutterWidth - 8, height: 14))
            label.text = hourLabel(hour)
            label.textAlignment = .right
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = UIColor(theme.textMuted)
            timeGutter.addSubview(label)
        }
        let divider = CALayer()
        divider.backgroundColor = UIColor(theme.divider).cgColor
        divider.frame = CGRect(x: Self.gutterWidth - 0.75, y: 0, width: 0.75, height: Self.timelineHeight)
        timeGutter.layer.addSublayer(divider)
    }

    private func drawGrid(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        let path = UIBezierPath()
        let width = colWidth * CGFloat(visibleCount + 2)
        for hour in 0...Self.hoursInDay {
            let y = min(Self.timelineHeight - 1, Self.timeYOffset + CGFloat(hour) * Self.hourHeight)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        for index in 0...(visibleCount + 2) {
            let x = CGFloat(index) * colWidth
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: Self.timelineHeight))
        }
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.strokeColor = UIColor(theme.dividerSoft).cgColor
        layer.lineWidth = 0.5
        layer.fillColor = UIColor.clear.cgColor
        dayCanvas.layer.addSublayer(layer)
    }

    private func drawNowLine(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        guard let todayIndex = (-1...visibleCount).first(where: { isToday(dayDate($0)) }) else { return }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let y = Self.timeYOffset + CGFloat(minute) / 60 * Self.hourHeight
        let x = CGFloat(todayIndex + 1) * colWidth
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + colWidth, y: y))
        let line = CAShapeLayer()
        line.path = path.cgPath
        line.strokeColor = UIColor(theme.danger).cgColor
        line.lineWidth = 1.5
        dayCanvas.layer.addSublayer(line)
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)).cgPath
        dot.fillColor = UIColor(theme.danger).cgColor
        dayCanvas.layer.addSublayer(dot)
    }

    private func drawEvents(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        for dayIndex in -1...visibleCount {
            for laid in laidEvents(forDayIndex: dayIndex, colWidth: colWidth) {
                let view = EventBlockView(frame: laid.frame)
                view.configure(laid: laid, theme: theme, timeFormat: timeFormat)
                view.onTap = { [weak self] occurrence in self?.onOpenOccurrence(occurrence) }
                if !laid.occurrence.isReadOnly {
                    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleEventLongPress(_:)))
                    longPress.minimumPressDuration = 0.30
                    longPress.allowableMovement = 700
                    longPress.delegate = self
                    view.addGestureRecognizer(longPress)
                }
                dayCanvas.addSubview(view)
            }
        }
        dayCanvas.bringSubviewToFront(draftView)
    }

    private func laidEvents(forDayIndex dayIndex: Int, colWidth: CGFloat) -> [LaidOccurrence] {
        struct Slot {
            let occurrence: MobileOccurrence
            let startMinute: CGFloat
            let endMinute: CGFloat
        }
        var slots: [Slot] = []
        for occurrence in occurrences(forDayIndex: dayIndex) {
            guard let startMinute = minuteOfDay(occurrence.start) ?? minuteOfDay(occurrence.end) else { continue }
            let endMinute = max(startMinute + 30, minuteOfDay(occurrence.end) ?? startMinute + 30)
            slots.append(Slot(occurrence: occurrence, startMinute: startMinute, endMinute: endMinute))
        }
        slots.sort { $0.startMinute < $1.startMinute }

        var columnEnd: [CGFloat] = []
        var slotColumn = Array(repeating: 0, count: slots.count)
        for (index, slot) in slots.enumerated() {
            var placed = false
            for (column, end) in columnEnd.enumerated() where slot.startMinute >= end {
                columnEnd[column] = slot.endMinute
                slotColumn[index] = column
                placed = true
                break
            }
            if !placed {
                slotColumn[index] = columnEnd.count
                columnEnd.append(slot.endMinute)
            }
        }

        let subCount = max(1, columnEnd.count)
        let subWidth = colWidth / CGFloat(subCount)
        let columnX = CGFloat(dayIndex + 1) * colWidth
        return slots.enumerated().map { index, slot in
            let y = Self.timeYOffset + slot.startMinute / 60 * Self.hourHeight
            let height = max(16, (slot.endMinute - slot.startMinute) / 60 * Self.hourHeight - 2)
            let frame = CGRect(
                x: columnX + CGFloat(slotColumn[index]) * subWidth + 1,
                y: y,
                width: max(8, subWidth - 2),
                height: height
            )
            return LaidOccurrence(
                occurrence: slot.occurrence,
                dayIndex: dayIndex,
                frame: frame,
                startMinute: slot.startMinute,
                endMinute: slot.endMinute
            )
        }
    }

    private func updateDraftView(colWidth: CGFloat) {
        guard let draft = activeCreateDraft, let theme else {
            draftView.isHidden = true
            return
        }
        let y = Self.timeYOffset + draft.startMinute / 60 * Self.hourHeight
        let x = CGFloat(draft.dayIndex + 1) * colWidth + 1
        draftView.frame = CGRect(x: x, y: y, width: max(8, colWidth - 2), height: Self.hourHeight - 2)
        draftView.backgroundColor = UIColor(theme.accent).withAlphaComponent(theme.isDark ? 0.32 : 0.22)
        draftView.layer.borderColor = UIColor(theme.accent).cgColor
        draftTimeLabel.text = draftTime(draft)
        let textColor = theme.isDark ? UIColor.white : UIColor(hex: 0x24272d)
        draftTimeLabel.textColor = textColor
        draftTitleLabel.textColor = textColor
        draftTimeLabel.frame = CGRect(x: 4, y: 3, width: draftView.bounds.width - 8, height: 12)
        draftTitleLabel.frame = CGRect(x: 4, y: 15, width: draftView.bounds.width - 8, height: 15)
        draftView.isHidden = false
    }

    @objc private func handleWeekdayTap(_ sender: UIControl) {
        guard let sender = sender as? DayCell else { return }
        selectedDate = Calendar.current.startOfDay(for: sender.date)
        swipeOffset = 0
        renderAllIfReady()
        onSetDate(selectedDate)
    }

    @objc private func handleDayPan(_ recognizer: UIPanGestureRecognizer) {
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        switch recognizer.state {
        case .changed:
            let dx = recognizer.translation(in: scrollView).x
            swipeOffset = rubberBand(dx, limit: colWidth * 0.96)
            layoutDayCanvas(colWidth: colWidth)
        case .ended:
            let dx = recognizer.translation(in: scrollView).x
            let velocity = recognizer.velocity(in: scrollView).x
            let projected = abs(dx + velocity * 0.18) > abs(dx) ? dx + velocity * 0.18 : dx
            let shouldShift = abs(projected) > max(48, min(bounds.width * 0.15, colWidth * 0.68)) || abs(dx) > colWidth * 0.42
            if shouldShift {
                completeSwipe(dayDelta: projected < 0 ? 1 : -1, colWidth: colWidth)
            } else {
                resetSwipe(colWidth: colWidth)
            }
            recognizer.setTranslation(.zero, in: scrollView)
        case .cancelled, .failed:
            resetSwipe(colWidth: colWidth)
            recognizer.setTranslation(.zero, in: scrollView)
        default:
            break
        }
    }

    private func completeSwipe(dayDelta: Int, colWidth: CGFloat) {
        swipeOffset = dayDelta > 0 ? -colWidth : colWidth
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
        } completion: { _ in
            self.selectedDate = Calendar.current.date(byAdding: .day, value: dayDelta, to: self.selectedDate) ?? self.selectedDate
            self.swipeOffset = 0
            self.renderAllIfReady()
            self.onShiftDay(dayDelta)
        }
    }

    private func resetSwipe(colWidth: CGFloat) {
        swipeOffset = 0
        UIView.animate(withDuration: 0.20, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
        }
    }

    private func layoutDayCanvas(colWidth: CGFloat) {
        dayCanvas.frame.origin.x = -colWidth + swipeOffset
    }

    @objc private func handleCreateLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = contentPoint(from: recognizer.location(in: scrollView))
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        switch recognizer.state {
        case .began:
            guard point.x >= Self.gutterWidth, hitEvent(at: point) == nil else { return }
            scrollView.isScrollEnabled = false
            activeCreateDraft = createDraft(at: point, colWidth: colWidth, visibleCount: visibleCount)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateDraftView(colWidth: colWidth)
        case .changed:
            let next = createDraft(at: point, colWidth: colWidth, visibleCount: visibleCount)
            if next != activeCreateDraft {
                activeCreateDraft = next
                UISelectionFeedbackGenerator().selectionChanged()
                updateDraftView(colWidth: colWidth)
            }
        case .ended:
            let draft = activeCreateDraft
            activeCreateDraft = nil
            draftView.isHidden = true
            scrollView.isScrollEnabled = true
            if let draft, let date = createDate(for: draft) {
                onCreate(date)
            }
        case .cancelled, .failed:
            activeCreateDraft = nil
            draftView.isHidden = true
            scrollView.isScrollEnabled = true
        default:
            break
        }
    }

    @objc private func handleEventLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view as? EventBlockView,
              let laid = view.laid,
              !laid.occurrence.isReadOnly else { return }
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        let location = recognizer.location(in: dayClip)
        switch recognizer.state {
        case .began:
            activeDragView = view
            activeDragStartFrame = view.frame
            activeDragStartLocation = location
            activeDragTarget = nil
            activeDragSnapKey = nil
            scrollView.isScrollEnabled = false
            dayCanvas.bringSubviewToFront(view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let translation = CGPoint(x: location.x - activeDragStartLocation.x, y: location.y - activeDragStartLocation.y)
            let target = moveTarget(for: laid, translation: translation, colWidth: colWidth, visibleCount: visibleCount)
            activeDragTarget = target
            let reveal = eventDragReveal(translationX: translation.x, colWidth: colWidth)
            swipeOffset = reveal
            layoutDayCanvas(colWidth: colWidth)
            view.frame = frameForDragging(laid: laid, target: target, translation: translation, colWidth: colWidth)
            let snapKey = "\(target.dayIndex)-\(Int(target.startMinute))"
            if snapKey != activeDragSnapKey {
                activeDragSnapKey = snapKey
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .ended:
            let target = activeDragTarget
            cleanupEventDrag(view: view, colWidth: colWidth)
            if let target {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMoveOccurrence(laid.occurrence, target.start, target.end)
            }
        case .cancelled, .failed:
            cleanupEventDrag(view: view, colWidth: colWidth)
        default:
            break
        }
    }

    private func cleanupEventDrag(view: EventBlockView, colWidth: CGFloat) {
        scrollView.isScrollEnabled = true
        activeDragView = nil
        activeDragTarget = nil
        activeDragSnapKey = nil
        swipeOffset = 0
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
            view.frame = self.activeDragStartFrame
        } completion: { _ in
            self.renderAllIfReady()
        }
    }

    private func frameForDragging(laid: LaidOccurrence, target: MoveTarget, translation: CGPoint, colWidth: CGFloat) -> CGRect {
        let targetY = Self.timeYOffset + target.startMinute / 60 * Self.hourHeight
        let x = CGFloat(target.dayIndex + 1) * colWidth + max(1, activeDragStartFrame.minX - CGFloat(laid.dayIndex + 1) * colWidth)
        return CGRect(
            x: x,
            y: targetY,
            width: min(activeDragStartFrame.width, colWidth - 2),
            height: activeDragStartFrame.height
        )
    }

    private func moveTarget(for laid: LaidOccurrence, translation: CGPoint, colWidth: CGFloat, visibleCount: Int) -> MoveTarget {
        let startCenterInClip = CGPoint(
            x: activeDragStartFrame.midX + dayCanvas.frame.minX,
            y: activeDragStartFrame.midY
        )
        let proposedCenterX = startCenterInClip.x + translation.x
        let proposedCanvasX = proposedCenterX - dayCanvas.frame.minX
        let rawSlot = Int(floor(proposedCanvasX / colWidth))
        let dayIndex = min(visibleCount, max(-1, rawSlot - 1))
        let duration = max(15, laid.endMinute - laid.startMinute)
        let maxStart = laid.occurrence.kind == "event"
            ? CGFloat(Self.hoursInDay * 60) - duration
            : CGFloat(Self.hoursInDay * 60 - 15)
        let rawMinute = (activeDragStartFrame.minY + translation.y - Self.timeYOffset) / Self.hourHeight * 60
        let snapped = (rawMinute / 15).rounded() * 15
        let startMinute = max(0, min(maxStart, snapped))
        let base = Calendar.current.startOfDay(for: dayDate(dayIndex))
        let anchor = Calendar.current.date(byAdding: .minute, value: Int(startMinute), to: base)
        if laid.occurrence.kind == "assignment" {
            return MoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: nil, end: anchor)
        }
        if laid.occurrence.kind == "reminder" {
            return MoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: nil)
        }
        let end = anchor.flatMap { Calendar.current.date(byAdding: .minute, value: Int(duration), to: $0) }
        return MoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: end)
    }

    private func eventDragReveal(translationX: CGFloat, colWidth: CGFloat) -> CGFloat {
        let threshold = colWidth * 0.20
        if translationX > threshold {
            return min(colWidth * 0.78, (translationX - threshold) * 0.56)
        }
        if translationX < -threshold {
            return -min(colWidth * 0.78, (-translationX - threshold) * 0.56)
        }
        return 0
    }

    private func createDraft(at point: CGPoint, colWidth: CGFloat, visibleCount: Int) -> CreateDraft {
        let clipX = point.x - Self.gutterWidth
        let dayIndex = min(visibleCount - 1, max(0, Int(floor(clipX / colWidth))))
        let rawMinute = max(0, (point.y - Self.timeYOffset) / Self.hourHeight * 60)
        let snapped = (rawMinute / 5).rounded(.down) * 5
        let clamped = max(0, min(CGFloat(Self.hoursInDay * 60 - 60), snapped))
        return CreateDraft(dayIndex: dayIndex, startMinute: clamped)
    }

    private func createDate(for draft: CreateDraft) -> Date? {
        Calendar.current.date(byAdding: .minute, value: Int(draft.startMinute), to: dayDate(draft.dayIndex))
    }

    private func draftTime(_ draft: CreateDraft) -> String {
        guard let date = createDate(for: draft) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    private func contentPoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y + scrollView.contentOffset.y)
    }

    private func hitEvent(at contentPoint: CGPoint) -> EventBlockView? {
        let canvasPoint = CGPoint(
            x: contentPoint.x - Self.gutterWidth - dayCanvas.frame.minX,
            y: contentPoint.y
        )
        return dayCanvas.subviews.reversed().compactMap { $0 as? EventBlockView }.first { $0.frame.contains(canvasPoint) }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            let point = contentPoint(from: gestureRecognizer.location(in: scrollView))
            return point.x >= Self.gutterWidth
                && abs(velocity.x) > abs(velocity.y) * 1.15
                && hitEvent(at: point) == nil
        }
        if gestureRecognizer is UILongPressGestureRecognizer,
           gestureRecognizer.view === scrollView {
            let point = contentPoint(from: gestureRecognizer.location(in: scrollView))
            return point.x >= Self.gutterWidth && hitEvent(at: point) == nil
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    private func visibleDayCount() -> Int {
        bounds.width >= 620 ? 3 : 2
    }

    private func visibleDayKeys() -> Set<String> {
        Set((0..<visibleDayCount()).map { AppModel.dateOnly(dayDate($0)) })
    }

    private func dayDate(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index, to: selectedDate) ?? selectedDate
    }

    private func occurrences(forDayIndex index: Int) -> [MobileOccurrence] {
        let key = AppModel.dateOnly(dayDate(index))
        return calendarSnapshot?.days.first { $0.date == key }?.occurrences ?? []
    }

    private func minuteOfDay(_ raw: String?) -> CGFloat? {
        guard let date = MobileDate.parseDateTime(raw) else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        let sign: CGFloat = value < 0 ? -1 : 1
        if magnitude <= limit { return value }
        return sign * (limit + (magnitude - limit) * 0.18)
    }

    private func hasToday() -> Bool {
        (-1...visibleDayCount()).contains { isToday(dayDate($0)) }
    }

    private func isToday(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(Date())
    }

    private func weekStart(for date: Date) -> Date {
        let weekday = Calendar.current.component(.weekday, from: date)
        return Calendar.current.date(byAdding: .day, value: -(weekday - 1), to: Calendar.current.startOfDay(for: date)) ?? date
    }

    private func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func weekdayInitial(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date).uppercased()
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
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
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1
        )
    }
}

struct CalendarToolbar: View {
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

struct CalendarDayColumn: View {
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

struct CalendarDayList: View {
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

struct CalendarListSection: View {
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

struct CalendarEventBlock: View {
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

struct OccurrenceCompactRow: View {
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
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

struct ArchiveNavigatorSection: View {
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

struct ArchiveSchemeRow: View {
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

struct SettingsArchiveSection: View {
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
        }
        .listRowBackground(theme.bgModal)
    }
}

struct SettingsArchiveList: View {
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
            .listRowBackground(theme.bgModal)
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

struct SettingsArchiveRow: View {
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

struct DesktopSearchPane: View {
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
            .padding(.bottom, searchFocused ? 8 : 84)
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

struct SettingsThemeOption: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 18, alignment: .center)
            Text(title)
        }
    }
}

struct DesktopSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var showingSyncSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: themeBinding) {
                        SettingsThemeOption(title: "Dark", systemImage: "moon.fill").tag("dark")
                        SettingsThemeOption(title: "Light", systemImage: "sun.max.fill").tag("light")
                        SettingsThemeOption(title: "System", systemImage: "circle.lefthalf.filled").tag("system")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Appearance")
                }
                .listRowBackground(theme.bgModal)

                Section {
                    Picker("Clock", selection: timeBinding) {
                        Text("12-hour").tag("twelve_hour")
                        Text("24-hour").tag("twenty_four_hour")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Time")
                }
                .listRowBackground(theme.bgModal)

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
                .listRowBackground(theme.bgModal)

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

struct MobileDock: View {
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

struct ColorSwatchStrip: View {
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

func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String) -> String {
    return occurrenceTimeLabel(occurrence, timeFormat: timeFormat, showDay: false)
}

func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String, showDay: Bool) -> String {
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
        let toText = from == to ? endTime : (to.isEmpty ? endTime : "\(to) \(endTime)")
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

func upcomingTimeLabel(raw: String, timeFormat: String) -> String? {
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

func upcomingDatePrefix(date: Date) -> String {
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
