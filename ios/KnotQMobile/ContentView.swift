import SwiftUI
import UIKit

private enum MobilePane: String, CaseIterable, Identifiable {
    case home
    case calendar
    case lists
    case scheme
    case daily
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .calendar: "Calendar"
        case .lists: "Schemes"
        case .scheme: "Scheme"
        case .daily: "Daily"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .calendar: "calendar"
        case .lists: "square.stack"
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

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: MobilePane = .home
    @State private var selectedSchemeID: String?
    @State private var schemePath: [String] = []
    @State private var addItemTarget: SheetID?
    @State private var showingCalendarAdd = false
    @State private var showingNewScheme = false
    @State private var showingNewFolder = false
    @State private var eventEditor: EventEditorTarget?
    @State private var keyboardVisible = false

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
                        onNewScheme: { showingNewScheme = true },
                        onNewFolder: { showingNewFolder = true }
                    )
                }

                HStack(spacing: 0) {
                    if wide {
                        DesktopNavigator(
                            root: model.snapshot?.root,
                            archivedSchemes: model.snapshot?.archivedSchemes ?? [],
                            selectedPane: pane,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme,
                            onSelectPane: { pane = $0 },
                            onSelectScheme: selectScheme,
                            onNewScheme: { showingNewScheme = true },
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
                                onOpenScheme: selectScheme
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
                if !wide && !keyboardVisible {
                    // Floating liquid-glass nav. It hovers over the content
                    // rather than reserving a strip.
                    MobileDock(
                        selected: (pane == .scheme || pane == .daily) ? .lists : pane,
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
                            if selected == .lists {
                                schemePath.removeAll()
                                selectedSchemeID = nil
                            }
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
            }
            // Panes without a navigation bar (Home, Calendar, Daily, Search,
            // Settings) let content scroll right up to the status bar. A soft
            // top shadow keeps that boundary clean instead of letting content
            // collide with the clock/battery.
            .overlay(alignment: .top) {
                if !wide && pane != .lists && pane != .scheme && pane != .settings && !keyboardVisible {
                    LinearGradient(
                        colors: [Color.black.opacity(theme.isDark ? 0.30 : 0.12), .clear],
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
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $eventEditor) { target in
            EventEditorSheet(theme: theme, target: target)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingCalendarAdd) {
            AddCalendarItemSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingNewScheme) {
            NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: { name in
                WorkspaceNameValidation.schemeError(name, root: model.snapshot?.root)
            }) { name in
                if let id = model.createScheme(name: name) {
                    selectScheme(id)
                } else {
                    pane = .lists
                }
            }
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $showingNewFolder) {
            NameSheet(title: "New Folder", placeholder: "Folder name", validator: { name in
                WorkspaceNameValidation.folderError(name, root: model.snapshot?.root)
            }) { name in
                model.createFolder(name: name)
                pane = .lists
            }
            .presentationDetents([.height(220)])
        }
        .onAppear { model.ensureDailyQueue(date: model.selectedDate) }
    }

    @ViewBuilder
    private func mainPane(wide: Bool) -> some View {
        switch pane {
        case .home:
            HomeDashboardPane(
                snapshot: model.snapshot,
                selectedDate: model.selectedDate,
                theme: theme,
                onOpenCalendar: { pane = .calendar },
                onOpenDaily: openDaily,
                onOpenScheme: selectScheme,
                onNewEvent: { showingCalendarAdd = true },
                onSearch: { pane = .search }
            )
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
        case .lists:
            if wide {
                DesktopListsPane(
                    root: model.snapshot?.root,
                    archivedSchemes: model.snapshot?.archivedSchemes ?? [],
                    selectedSchemeID: selectedSchemeID,
                    theme: theme,
                    onSelectScheme: selectScheme,
                    onOpenDaily: openDaily,
                    onNewScheme: { showingNewScheme = true },
                    onNewFolder: { showingNewFolder = true }
                )
            } else {
                MobileListsNavigationPane(
                    root: model.snapshot?.root,
                    archivedSchemes: model.snapshot?.archivedSchemes ?? [],
                    selectedSchemeID: $selectedSchemeID,
                    path: $schemePath,
                    theme: theme,
                    onOpenDaily: openDaily,
                    onNewScheme: { showingNewScheme = true },
                    onNewFolder: { showingNewFolder = true }
                )
            }
        case .scheme:
            if wide, let selectedScheme {
                DesktopSchemePane(
                    scheme: selectedScheme,
                    theme: theme,
                    onBack: { pane = .lists },
                    onAdd: { addItemTarget = SheetID(id: selectedScheme.id) }
                )
            } else if !wide {
                MobileListsNavigationPane(
                    root: model.snapshot?.root,
                    archivedSchemes: model.snapshot?.archivedSchemes ?? [],
                    selectedSchemeID: $selectedSchemeID,
                    path: $schemePath,
                    theme: theme,
                    onOpenDaily: openDaily,
                    onNewScheme: { showingNewScheme = true },
                    onNewFolder: { showingNewFolder = true }
                )
            } else {
                EmptyState(title: "Pick a scheme", detail: "Choose a scheme from the navigator.", theme: theme)
            }
        case .daily:
            DailyFeedPane(
                entries: model.snapshot?.daily ?? [],
                selectedDate: model.selectedDate,
                theme: theme,
                onPrevious: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                onNext: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                onDate: selectDailyDate,
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
        model.ensureDailyQueue(date: model.selectedDate)
        selectedSchemeID = nil
        schemePath.removeAll()
        pane = .daily
    }

    private func selectScheme(_ id: String) {
        selectedSchemeID = id
        schemePath = [id]
        pane = .scheme
    }

    private func selectDailyDate(_ date: Date) {
        let newKey = AppModel.dateOnly(date)
        let currentKey = AppModel.dateOnly(model.selectedDate)
        if newKey != currentKey || currentDailyScheme == nil {
            model.ensureDailyQueue(date: date)
        }
    }

    private func moveOccurrence(_ occurrence: MobileOccurrence, start: Date?, end: Date?) {
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
        rowAlt: Color.black.opacity(0.035),
        rowHover: Color.black.opacity(0.06),
        rowSelected: Color(hex: 0xe66f1f).opacity(0.12),
        buttonBg: Color.black.opacity(0.06),
        divider: Color.black.opacity(0.13),
        dividerSoft: Color.black.opacity(0.08),
        dividerTiny: Color.black.opacity(0.05),
        borderOverlay: Color.black.opacity(0.18),
        textPrimary: Color(hex: 0x2c2420),
        textDim: Color(hex: 0x302520).opacity(0.78),
        textMuted: Color(hex: 0x5a4a3c).opacity(0.52),
        textSoft: Color(hex: 0x382c22).opacity(0.70),
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
                        .disabled(!(pane == .scheme || pane == .daily))
                    Button("Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                } label: {
                    Image(systemName: "plus")
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

private struct DesktopNavigator: View {
    let root: MobileNode?
    let archivedSchemes: [MobileScheme]
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

            ArchiveNavigatorSection(schemes: archivedSchemes, theme: theme, compact: true)
                .padding(.top, 4)

            HStack(spacing: 6) {
                Menu {
                    Button("Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
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
        .shadow(color: .black.opacity(theme.isDark ? 0.18 : 0.08), radius: 9, x: 0, y: 5)
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
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .padding(.horizontal, 6)
            .foregroundStyle(theme.textPrimary)
            .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
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

    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false
    @State private var archiveTarget: ArchiveTarget?

    var body: some View {
        if node.kind == "folder" {
            DisclosureGroup {
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
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 8)
                .frame(height: 22)
                .foregroundStyle(theme.textPrimary)
            }
            .tint(theme.textDim)
            .contextMenu {
                Button("New Scheme") { newSchemeInFolder = true }
                Button("Rename") { renameNode = node }
                Button("Archive", systemImage: "archivebox") {
                    archiveTarget = .folder(node)
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
            .archiveConfirmation(target: $archiveTarget) { target in
                if target.kind == .folder {
                    model.archiveFolder(id: target.id)
                }
            }
        } else {
            Button { onSelectScheme(node.id) } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                        .frame(width: 9, height: 9)
                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 8)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .foregroundStyle(theme.textPrimary)
                .background(selectedSchemeID == node.id ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename") { renameNode = node }
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Archive", systemImage: "archivebox") {
                    archiveTarget = .scheme(node)
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
            .archiveConfirmation(target: $archiveTarget) { target in
                if target.kind == .scheme {
                    model.archiveScheme(id: target.id)
                }
            }
        }
    }
}

private struct DesktopUpcomingRail: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpcomingSection(title: "Overdue", empty: "None", occurrences: calendar?.overdue ?? [], theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                UpcomingSection(title: "Today", empty: "None today", occurrences: todayOccurrences, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                UpcomingSection(title: "Upcoming", empty: "None", occurrences: calendar?.upcoming ?? [], theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
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
    let onOpenCalendar: () -> Void
    let onOpenDaily: () -> Void
    let onOpenScheme: (String) -> Void
    let onNewEvent: () -> Void
    let onSearch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // A single unified Upcoming list — overdue items lead (their
                // time stamps render in the overdue colour) followed by what's
                // next, instead of separate Overdue/Next sections.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upcoming")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 2)

                    if upcomingOccurrences.isEmpty {
                        Text("Nothing scheduled")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 2)
                    } else {
                        ForEach(Array(upcomingOccurrences.enumerated()), id: \.element.id) { idx, occurrence in
                            OccurrenceCompactRow(
                                occurrence: occurrence,
                                theme: theme,
                                timeFormat: timeFormat,
                                striped: idx % 2 == 1
                            ) {
                                onOpenScheme(occurrence.schemeId)
                            }
                        }
                    }
                }

                // Daily preview lives lower on the page, after Upcoming.
                HomeDailyPreview(
                    entry: dailyEntry,
                    selectedDate: selectedDate,
                    theme: theme,
                    onOpenDaily: onOpenDaily
                )

                HomeQuickActions(
                    theme: theme,
                    onNewEvent: onNewEvent,
                    onOpenDaily: onOpenDaily
                )
                .padding(.top, 12)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(14)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.never)
        .background(theme.bgApp)
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

private struct HomeQuickActions: View {
    let theme: KnotQTheme
    let onNewEvent: () -> Void
    let onOpenDaily: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            tile("New Event", "calendar.badge.plus", action: onNewEvent)
            tile("Daily", "checklist", action: onOpenDaily)
        }
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(theme.borderOverlay, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct HomeDailyPreview: View {
    let entry: MobileDailyEntry?
    let selectedDate: Date
    let theme: KnotQTheme
    let onOpenDaily: () -> Void

    var body: some View {
        Button(action: onOpenDaily) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad))
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily")
                            .font(.system(size: 17, weight: .semibold))
                        Text(AppModel.displayDate(entry?.date ?? AppModel.dateOnly(selectedDate)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSoft)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                }

                if previewItems.isEmpty {
                    Text("No open daily items")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(previewItems.prefix(4))) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: markerIcon(item))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(item.done ? theme.accent : theme.textDim)
                                    .frame(width: 16, height: 18)
                                Text(item.text.isEmpty ? item.kind.capitalized : item.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(item.done ? theme.textMuted : theme.textPrimary)
                                    .strikethrough(item.done)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(theme.borderOverlay, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var previewItems: [MobileItem] {
        guard let entry else { return [] }
        return entry.scheme.items.filter { item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !item.done
        }
    }

    private func markerIcon(_ item: MobileItem) -> String {
        switch item.marker {
        case "checkbox": item.done ? "checkmark.square.fill" : "square"
        case "bullet": "smallcircle.filled.circle"
        case "numbered": "list.number"
        default: "text.alignleft"
        }
    }
}


private struct UpcomingSection: View {
    let title: String
    let empty: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

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
                    OccurrenceCompactRow(occurrence: occurrence, theme: theme, timeFormat: timeFormat, striped: idx % 2 == 1) {
                        onOpenScheme(occurrence.schemeId)
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
    @State private var ignoredEventDragID: String?
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
            VStack(spacing: 0) {
                dateBanner()
                weekStrip(visibleCount: visibleCount)
                    .offset(x: swipePreviewX * 0.55)
                Divider().overlay(theme.dividerSoft)
                timeline(colWidth: colWidth, visibleCount: visibleCount)
                    .offset(x: swipePreviewX)
            }
            .background(theme.bgApp)
            .contentShape(Rectangle())
            // Horizontal swipe pages the day window; gated to predominantly
            // horizontal drags so it never fights the vertical timeline scroll.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .updating($swipePreviewX) { value, state, _ in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.35 else { return }
                        state = dx * 0.32
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let projected = abs(value.predictedEndTranslation.width) > abs(dx)
                            ? value.predictedEndTranslation.width
                            : dx
                        guard abs(dx) > abs(dy) * 1.35,
                              abs(projected) > max(52, proxy.size.width * 0.18) else { return }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            onShiftDay(projected < 0 ? visibleCount : -visibleCount)
                        }
                    }
            )
            .clipped()
        }
    }

    private func dateBanner() -> some View {
        Text(currentDateTitle)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)
    }

    private func weekStrip(visibleCount: Int) -> some View {
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
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: selectedDateKey)
    }

    // MARK: Timeline

    private func timeline(colWidth: CGFloat, visibleCount: Int) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        scrollOffsetReader()
                        hourGrid(colWidth: colWidth, visibleCount: visibleCount)
                            .allowsHitTesting(false)
                        eventsLayer(colWidth: colWidth, visibleCount: visibleCount)
                        createDraftLayer(colWidth: colWidth)
                        nowLine(colWidth: colWidth, visibleCount: visibleCount).allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .frame(height: Self.timeYOffset + CGFloat(Self.hoursInDay) * Self.hourHeight)
                    .padding(.bottom, 88)
                    .simultaneousGesture(createGesture(colWidth: colWidth, visibleCount: visibleCount))
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

    private func scrollToFocusHour(_ proxy: ScrollViewProxy) {
        let focus = hasToday
            ? max(0, Calendar.current.component(.hour, from: Date()) - 1)
            : 7
        proxy.scrollTo("hour-\(focus)", anchor: .top)
    }

    /// Transparent bottom layer that turns a long-press into "create at this
    /// time", Apple Calendar-style: hold ~0.5s and a draft block appears under
    /// the finger, which you then drag to position. Releasing opens the editor
    /// at the final slot. Events sit above this layer, so long-pressing an event
    /// won't trigger creation.
    private func createGesture(colWidth: CGFloat, visibleCount: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(_, drag?) = value else { return }
                if createDraft == nil {
                    createDraft = createTarget(point: drag.startLocation, colWidth: colWidth, visibleCount: visibleCount)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    let moved = createTarget(point: drag.location, colWidth: colWidth, visibleCount: visibleCount)
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
            .shadow(color: .black.opacity(theme.isDark ? 0.32 : 0.16), radius: 7, x: 0, y: 4)
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

    private func hourGrid(colWidth: CGFloat, visibleCount: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<Self.hoursInDay, id: \.self) { hour in
                let y = Self.timeYOffset + CGFloat(hour) * Self.hourHeight
                Rectangle()
                    .fill(theme.dividerSoft)
                    .frame(height: 0.5)
                    .padding(.leading, Self.gutterWidth)
                    .offset(y: y)
                    .id("hour-\(hour)")
                Text(hourLabel(hour))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: Self.gutterWidth - 8, alignment: .trailing)
                    .offset(y: y - 6)
            }
        }
    }

    private func eventsLayer(colWidth: CGFloat, visibleCount: Int) -> some View {
        ForEach(allLaidEvents(colWidth: colWidth, visibleCount: visibleCount)) { laid in
            let dragOffset = eventDragOffset(for: laid, colWidth: colWidth)
            TimelineEventBlock(
                occurrence: laid.occurrence,
                theme: theme,
                timeFormat: timeFormat,
                onTap: { onOpenOccurrence(laid.occurrence) }
            )
            .frame(width: laid.width, height: laid.height)
            .offset(x: laid.x + dragOffset.width, y: laid.y + dragOffset.height)
            .zIndex(draggingOccurrenceID == laid.id ? 10 : 0)
            .shadow(
                color: .black.opacity(draggingOccurrenceID == laid.id ? (theme.isDark ? 0.32 : 0.18) : 0),
                radius: draggingOccurrenceID == laid.id ? 7 : 0,
                x: 0,
                y: draggingOccurrenceID == laid.id ? 4 : 0
            )
            .highPriorityGesture(eventDragGesture(for: laid, colWidth: colWidth))
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
            .shadow(color: .black.opacity(theme.isDark ? 0.30 : 0.16), radius: 6, x: 0, y: sticky.edge == .top ? 3 : -2)
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
    private func eventDragGesture(for laid: LaidOccurrence, colWidth: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingOccurrenceID != laid.id {
                        draggingOccurrenceID = laid.id
                        draggingTranslation = .zero
                        lastDragSnap = nil
                        ignoredEventDragID = nil
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                case let .second(_, drag?):
                    let dx = abs(drag.translation.width)
                    let dy = abs(drag.translation.height)
                    if ignoredEventDragID == laid.id {
                        return
                    }
                    if dx > 16, dx > dy * 1.25 {
                        ignoredEventDragID = laid.id
                        draggingOccurrenceID = nil
                        draggingTranslation = .zero
                        lastDragSnap = nil
                        return
                    }
                    draggingTranslation = drag.translation
                    let snap = eventSnapIndex(for: laid, translation: drag.translation, colWidth: colWidth)
                    if let snap, snap != lastDragSnap {
                        lastDragSnap = snap
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                var moveTarget: OccurrenceMoveTarget?
                if ignoredEventDragID != laid.id,
                   case let .second(_, drag?) = value,
                   abs(drag.translation.width) > 2 || abs(drag.translation.height) > 2 {
                    moveTarget = occurrenceMoveTarget(for: laid, translation: drag.translation, colWidth: colWidth)
                }
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    draggingOccurrenceID = nil
                    draggingTranslation = .zero
                    lastDragSnap = nil
                    ignoredEventDragID = nil
                }
                if let moveTarget {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onMoveOccurrence(laid.occurrence, moveTarget.start, moveTarget.end)
                }
            }
    }

    private func eventDragOffset(for laid: LaidOccurrence, colWidth: CGFloat) -> CGSize {
        guard draggingOccurrenceID == laid.id,
              let target = occurrenceMoveTarget(for: laid, translation: draggingTranslation, colWidth: colWidth) else {
            return .zero
        }
        let y = Self.timeYOffset + target.startMinute / 60.0 * Self.hourHeight - laid.y
        let x = CGFloat(target.dayIndex - laid.dayIndex) * colWidth
        return CGSize(width: x, height: y)
    }

    private func eventSnapIndex(for laid: LaidOccurrence, translation: CGSize, colWidth: CGFloat) -> Int? {
        occurrenceMoveTarget(for: laid, translation: translation, colWidth: colWidth).map {
            $0.dayIndex * 96 + Int($0.startMinute / 15.0)
        }
    }

    private func occurrenceMoveTarget(for laid: LaidOccurrence, translation: CGSize, colWidth: CGFloat) -> OccurrenceMoveTarget? {
        let rawDay = ((laid.x + laid.width / 2 + translation.width) - Self.gutterWidth) / colWidth
        let dayIndex = Int(rawDay.rounded())
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
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: Date())
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
            (0.722, 0.580, 0.000),
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                        Text(occurrenceTimeLabel(occurrence, timeFormat: timeFormat))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.textSoft)
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
            .background(striped ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .opacity(occurrence.done ? 0.45 : 1)
    }
}

private struct DesktopListsPane: View {
    let root: MobileNode?
    let archivedSchemes: [MobileScheme]
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectScheme: (String) -> Void
    let onOpenDaily: () -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Schemes")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                        Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(TitleIconButton(theme: theme))
                }

                Button(action: onOpenDaily) {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad))
                            .frame(width: 12, height: 12)
                        Text("Daily")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textMuted)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .foregroundStyle(theme.textPrimary)
                    .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(theme.borderOverlay, lineWidth: 1) }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
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
                .padding(8)
                .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(theme.borderOverlay, lineWidth: 1) }

                ArchiveNavigatorSection(schemes: archivedSchemes, theme: theme, compact: false)
            }
            .padding(12)
        }
        .background(theme.bgApp)
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

private struct MobileListsNavigationPane: View {
    @EnvironmentObject private var model: AppModel
    let root: MobileNode?
    let archivedSchemes: [MobileScheme]
    @Binding var selectedSchemeID: String?
    @Binding var path: [String]
    let theme: KnotQTheme
    let onOpenDaily: () -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                MobileDailyNavigatorRow(theme: theme, action: onOpenDaily)

                if let root {
                    ForEach(root.children) { node in
                        MobileNavigatorNode(
                            node: node,
                            depth: 0,
                            parentFolderID: root.id,
                            root: root,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme
                        )
                    }
                    .onMove { source, destination in
                        moveNode(source: source, destination: destination, siblings: root.children, parentFolderID: root.id)
                    }
                }
                MobileArchiveListSection(schemes: archivedSchemes, theme: theme)

                Color.clear
                    .frame(height: 12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 24)
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Schemes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { schemeID in
                if let scheme = model.scheme(id: schemeID) {
                    IntegratedSchemeEditorPane(
                        scheme: scheme,
                        theme: theme,
                        onBack: nil,
                        onAdd: {},
                        usesNativeNavigation: true
                    )
                    .onAppear { selectedSchemeID = schemeID }
                } else {
                    EmptyState(title: "Scheme missing", detail: "It may have been archived or moved.", theme: theme)
                }
            }
            // No Edit button — List rows already reorder via long-press drag.
            // Add controls live at the bottom as two direct buttons (no menu),
            // sitting just above the floating dock.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    ListAddButton(title: "New Scheme", systemImage: "doc.badge.plus", theme: theme, action: onNewScheme)
                    ListAddButton(title: "New Folder", systemImage: "folder.badge.plus", theme: theme, action: onNewFolder)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 64)
                .background(
                    LinearGradient(
                        colors: [theme.bgApp.opacity(0), theme.bgApp.opacity(0.94), theme.bgApp],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                )
            }
        }
        .tint(theme.accent)
        .onChange(of: path) { _, newValue in
            selectedSchemeID = newValue.last
        }
        .onAppear {
            if let selectedSchemeID, path.last != selectedSchemeID {
                path = [selectedSchemeID]
            }
        }
    }

    private func moveNode(source: IndexSet, destination: Int, siblings: [MobileNode], parentFolderID: String) {
        guard let from = source.first, from < siblings.count else { return }
        let node = siblings[from]
        model.moveNode(kind: node.kind, id: node.id, folderID: parentFolderID, position: destination)
    }
}

private struct ListAddButton: View {
    let title: String
    let systemImage: String
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(theme.textPrimary)
                .background(theme.bgSidebar, in: Capsule())
                .overlay(Capsule().stroke(theme.borderOverlay, lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.22 : 0.08), radius: 7, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct MobileDailyNavigatorRow: View {
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad))
                    .frame(width: 9, height: 9)
                Text("Daily")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textMuted)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 5, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bgApp)
    }
}

private struct MobileNavigatorNode: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let depth: Int
    let parentFolderID: String
    let root: MobileNode
    let selectedSchemeID: String?
    let theme: KnotQTheme

    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false
    @State private var archiveTarget: ArchiveTarget?

    var body: some View {
        if node.kind == "folder" {
            DisclosureGroup {
                ForEach(node.children) { child in
                    MobileNavigatorNode(
                        node: child,
                        depth: depth + 1,
                        parentFolderID: node.id,
                        root: root,
                        selectedSchemeID: selectedSchemeID,
                        theme: theme
                    )
                }
                .onMove { source, destination in
                    moveNode(source: source, destination: destination, siblings: node.children, parentFolderID: node.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                        .frame(width: 14)
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 10)
                .frame(minHeight: 28)
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.bgApp)
            .contextMenu {
                Button("New Scheme", systemImage: "doc.badge.plus") { newSchemeInFolder = true }
                Button("Rename", systemImage: "pencil") { renameNode = node }
                Button("Archive", systemImage: "archivebox") {
                    archiveTarget = .folder(node)
                }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    archiveTarget = .folder(node)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
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
                    _ = model.createScheme(name: name, folderID: node.id)
                }
                .presentationDetents([.height(220)])
            }
            .archiveConfirmation(target: $archiveTarget) { target in
                if target.kind == .folder {
                    model.archiveFolder(id: target.id)
                }
            }
        } else {
            NavigationLink(value: node.id) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                        .frame(width: 9, height: 9)
                    Text(node.name)
                        .font(.system(size: 13, weight: selectedSchemeID == node.id ? .semibold : .regular))
                        .foregroundStyle(selectedSchemeID == node.id ? theme.textPrimary : theme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 10 + 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(selectedSchemeID == node.id ? theme.rowSelected : theme.bgApp)
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renameNode = node }
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Archive", systemImage: "archivebox") {
                    archiveTarget = .scheme(node)
                }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    archiveTarget = .scheme(node)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Scheme", placeholder: "Scheme name", initialText: target.name, validator: { name in
                    WorkspaceNameValidation.schemeError(name, root: root, folderID: parentFolderID, excludingID: target.id)
                }) { name in
                    model.renameScheme(id: target.id, name: name)
                }
                .presentationDetents([.height(220)])
            }
            .archiveConfirmation(target: $archiveTarget) { target in
                if target.kind == .scheme {
                    model.archiveScheme(id: target.id)
                }
            }
        }
    }

    private func moveNode(source: IndexSet, destination: Int, siblings: [MobileNode], parentFolderID: String) {
        guard let from = source.first, from < siblings.count else { return }
        let moved = siblings[from]
        model.moveNode(kind: moved.kind, id: moved.id, folderID: parentFolderID, position: destination)
    }
}

private struct MobileArchiveListSection: View {
    @EnvironmentObject private var model: AppModel
    let schemes: [MobileScheme]
    let theme: KnotQTheme
    @State private var expanded = false
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                if schemes.isEmpty {
                    Text("No archived schemes")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMuted)
                        .listRowInsets(EdgeInsets(top: 4, leading: 34, bottom: 4, trailing: 12))
                        .listRowBackground(theme.bgApp)
                } else {
                    ForEach(schemes) { scheme in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(schemeColor(scheme.colorIndex, dark: theme.isDark).opacity(0.7))
                                .frame(width: 9, height: 9)
                            Text(scheme.displayName)
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textMuted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 34, bottom: 4, trailing: 12))
                        .listRowBackground(theme.bgApp)
                        .contextMenu {
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                model.restoreScheme(id: scheme.id)
                            }
                            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
                            }
                        }
                    }
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 12))
            .listRowBackground(theme.bgApp)
            .contextMenu {
                Button("Empty Archive", systemImage: "trash", role: .destructive) {
                    confirmEmptyArchive = .emptyArchive(count: schemes.count)
                }
                .disabled(schemes.isEmpty)
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { target in
            if let scheme = schemes.first(where: { "permanent-\($0.id)" == target.id }) {
                model.permanentlyDeleteScheme(id: scheme.id)
            }
        }
        .destructiveConfirmation(target: $confirmEmptyArchive) { _ in
            model.emptyArchive()
        }
    }
}

private struct DesktopSchemePane: View {
    let scheme: MobileScheme
    let theme: KnotQTheme
    let onBack: () -> Void
    let onAdd: () -> Void

    var body: some View {
        IntegratedSchemeEditorPane(scheme: scheme, theme: theme, onBack: onBack, onAdd: onAdd)
    }
}

struct DailyFeedPane: View {
    let entries: [MobileDailyEntry]
    let selectedDate: Date
    let theme: KnotQTheme
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDate: @MainActor (Date) -> Void
    let onAdd: () -> Void

    var body: some View {
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
                        proxy.scrollTo(selectedDateKey, anchor: .center)
                        DispatchQueue.main.async {
                            proxy.scrollTo(selectedDateKey, anchor: .center)
                        }
                    }
                    .onChange(of: selectedDateKey) { _, value in
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
            }
        }
        .background(theme.bgApp)
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
                .presentationDetents([.medium, .large])
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
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(theme.bgModal, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(theme.borderOverlay, lineWidth: 1) }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, searchFocused ? 8 : 64)
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
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: themeBinding) {
                        Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                        Label("Dark", systemImage: "moon.fill").tag("dark")
                        Label("Light", systemImage: "sun.max.fill").tag("light")
                    }
                    .pickerStyle(.inline)
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

                Section {
                    LabeledContent("Location") {
                        Text(model.snapshot?.workspacePath ?? "—")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("All data is stored locally on this device — no account or cloud.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset Workspace", systemImage: "trash")
                    }
                } footer: {
                    Text("KnotQ \(appVersion)")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Settings")
        }
        .tint(theme.accent)
        .confirmationDialog("Reset Workspace", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetWorkspace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all local schemes and settings. This can't be undone.")
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

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct MobileDock: View {
    let selected: MobilePane
    let theme: KnotQTheme
    let onSelect: (MobilePane) -> Void

    private let panes: [MobilePane] = [.home, .calendar, .lists, .search, .settings]

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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.borderOverlay, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 4)
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
        Menu("Color") {
            ForEach(0..<6, id: \.self) { index in
                Button {
                    model.setSchemeColor(id: nodeID, colorIndex: Int32(index))
                } label: {
                    Label("Color \(index + 1)", systemImage: colorIndex == Int32(index) ? "checkmark" : "circle.fill")
                }
            }
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
    let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat)
    let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat)
    if occurrence.kind == "reminder", let start { return "At \(start)" }
    if occurrence.kind == "assignment", let end { return "Due \(end)" }
    if let start, let end { return "\(start) - \(end)" }
    if let start { return start }
    if let end { return "Due \(end)" }
    return occurrence.kind.capitalized
}

func schemeColor(_ index: Int32, dark: Bool) -> Color {
    let darkPalette: [UInt32] = [0xff453a, 0xff9f0a, 0x30d158, 0x0a84ff, 0xbf5af2, 0xffd60a]
    let lightPalette: [UInt32] = [0xd4271c, 0xc47400, 0x1e9e40, 0x0064d2, 0x8a3db5, 0xb89400]
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
