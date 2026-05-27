import SwiftUI
import UIKit

private enum MobilePane: String, CaseIterable, Identifiable {
    case calendar
    case lists
    case scheme
    case daily
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .lists: "Lists"
        case .scheme: "List"
        case .daily: "Daily"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .lists: "sidebar.left"
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

    @State private var pane: MobilePane = .calendar
    @State private var selectedSchemeID: String?
    @State private var schemePath: [String] = []
    @State private var addItemTarget: SheetID?
    @State private var showingCalendarAdd = false
    @State private var showingNewScheme = false
    @State private var showingNewFolder = false
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
                            selectedPane: pane,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme,
                            onSelectPane: { pane = $0 },
                            onSelectScheme: selectScheme,
                            onNewScheme: { showingNewScheme = true },
                            onNewFolder: { showingNewFolder = true }
                        )
                        .frame(width: 182)
                        .padding(.leading, 8)
                        .padding(.vertical, 8)

                        DesktopUpcomingRail(
                            calendar: model.snapshot?.calendar,
                            theme: theme,
                            onOpenScheme: selectScheme
                        )
                        .frame(width: 258)
                    }

                    Rectangle()
                        .fill(theme.dividerTiny)
                        .frame(width: wide ? 1 : 0)

                    mainPane(wide: wide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !wide && !keyboardVisible {
                    MobileDock(
                        selected: pane == .scheme ? .lists : pane,
                        theme: theme,
                        onSelect: { selected in
                            pane = selected
                            if selected == .lists {
                                schemePath.removeAll()
                                selectedSchemeID = nil
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bgApp.ignoresSafeArea())
            .foregroundStyle(theme.textPrimary)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .overlay(alignment: .bottom) {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, wide ? 16 : 72)
                }
            }
        }
        .sheet(item: $addItemTarget) { target in
            AddItemSheet(schemeID: target.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingCalendarAdd) {
            AddCalendarItemSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingNewScheme) {
            NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: WorkspaceNameValidation.schemeError) { name in
                if let id = model.createScheme(name: name) {
                    selectScheme(id)
                } else {
                    pane = .lists
                }
            }
            .presentationDetents([.height(180)])
        }
        .sheet(isPresented: $showingNewFolder) {
            NameSheet(title: "New Folder", placeholder: "Folder name", validator: WorkspaceNameValidation.folderError) { name in
                model.createFolder(name: name)
                pane = .lists
            }
            .presentationDetents([.height(180)])
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func mainPane(wide: Bool) -> some View {
        switch pane {
        case .calendar:
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
                onOpenScheme: selectScheme
            )
        case .lists:
            if wide {
                DesktopListsPane(
                    root: model.snapshot?.root,
                    selectedSchemeID: selectedSchemeID,
                    theme: theme,
                    onSelectScheme: selectScheme,
                    onNewScheme: { showingNewScheme = true },
                    onNewFolder: { showingNewFolder = true }
                )
            } else {
                MobileListsNavigationPane(
                    root: model.snapshot?.root,
                    selectedSchemeID: $selectedSchemeID,
                    path: $schemePath,
                    theme: theme,
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
                    selectedSchemeID: $selectedSchemeID,
                    path: $schemePath,
                    theme: theme,
                    onNewScheme: { showingNewScheme = true },
                    onNewFolder: { showingNewFolder = true }
                )
            } else {
                EmptyState(title: "Pick a list", detail: "Choose a scheme from the navigator.", theme: theme)
            }
        case .daily:
            DailyFeedPane(
                entries: model.snapshot?.daily ?? [],
                selectedDate: model.selectedDate,
                theme: theme,
                onPrevious: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
                onNext: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
                onDate: { date in model.ensureDailyQueue(date: date) },
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

    private func selectScheme(_ id: String) {
        selectedSchemeID = id
        schemePath = [id]
        pane = .scheme
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

    static let dark = KnotQTheme(
        isDark: true,
        bgApp: Color(hex: 0x242627),
        bgSidebar: Color(hex: 0x28292b),
        bgToolbar: Color(hex: 0x363738),
        bgModal: Color(hex: 0x303133),
        rowAlt: Color.white.opacity(0.03),
        rowHover: Color.white.opacity(0.06),
        rowSelected: Color.white.opacity(0.12),
        buttonBg: Color.white.opacity(0.07),
        divider: Color.white.opacity(0.10),
        dividerSoft: Color.white.opacity(0.07),
        dividerTiny: Color.white.opacity(0.03),
        borderOverlay: Color.white.opacity(0.13),
        textPrimary: Color(hex: 0xdde2e8),
        textDim: Color(hex: 0xb4bcc4).opacity(0.72),
        textMuted: Color(hex: 0xb4bcc4).opacity(0.42),
        textSoft: Color(hex: 0xd2dae2).opacity(0.62),
        textToday: Color(hex: 0xe66d5d),
        accent: Color(hex: 0x7aa0ff),
        danger: Color(hex: 0xff5a53)
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
                .frame(width: 18, height: 18)

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
        .frame(height: 38)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? theme.rowSelected : theme.buttonBg, in: RoundedRectangle(cornerRadius: 5))
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
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).stroke(theme.borderOverlay, lineWidth: 1)
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
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 25)
            .padding(.horizontal, 7)
            .foregroundStyle(theme.textPrimary)
            .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

private struct NavigatorNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let depth: Int
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectScheme: (String) -> Void

    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false

    var body: some View {
        if node.kind == "folder" {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children) { child in
                        NavigatorNodeRow(
                            node: child,
                            depth: depth + 1,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme,
                            onSelectScheme: onSelectScheme
                        )
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 13)
                    Text(node.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 9)
                .frame(height: 25)
                .foregroundStyle(theme.textPrimary)
            }
            .tint(theme.textDim)
            .contextMenu {
                Button("New Scheme") { newSchemeInFolder = true }
                Button("Rename") { renameNode = node }
                Button("Delete", role: .destructive) { model.deleteFolder(id: node.id) }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Folder", placeholder: "Folder name", initialText: target.name, validator: WorkspaceNameValidation.folderError) { name in
                    model.renameFolder(id: target.id, name: name)
                }
                .presentationDetents([.height(180)])
            }
            .sheet(isPresented: $newSchemeInFolder) {
                NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: WorkspaceNameValidation.schemeError) { name in
                    if let id = model.createScheme(name: name, folderID: node.id) {
                        onSelectScheme(id)
                    }
                }
                .presentationDetents([.height(180)])
            }
        } else {
            Button { onSelectScheme(node.id) } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                        .frame(width: 10, height: 10)
                    Text(node.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 9)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .foregroundStyle(theme.textPrimary)
                .background(selectedSchemeID == node.id ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename") { renameNode = node }
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Delete", role: .destructive) { model.deleteScheme(id: node.id) }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Scheme", placeholder: "Scheme name", initialText: target.name, validator: WorkspaceNameValidation.schemeError) { name in
                    model.renameScheme(id: target.id, name: name)
                }
                .presentationDetents([.height(180)])
            }
        }
    }
}

private struct DesktopUpcomingRail: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let onOpenScheme: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpcomingSection(title: "Overdue", empty: "None", occurrences: calendar?.overdue ?? [], theme: theme, onOpenScheme: onOpenScheme)
                UpcomingSection(title: "Today", empty: "None today", occurrences: todayOccurrences, theme: theme, onOpenScheme: onOpenScheme)
                UpcomingSection(title: "Upcoming", empty: "None", occurrences: calendar?.upcoming ?? [], theme: theme, onOpenScheme: onOpenScheme)
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

private struct UpcomingSection: View {
    let title: String
    let empty: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
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
                    OccurrenceCompactRow(occurrence: occurrence, theme: theme, striped: idx % 2 == 1) {
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
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(calendar: calendar, theme: theme, onPrevious: onPrevious, onNext: onNext, onToday: onToday, onAdd: onAdd)
            ScrollView([.vertical, wide ? .horizontal : []]) {
                VStack(alignment: .leading, spacing: 12) {
                    if let overdue = calendar?.overdue, !overdue.isEmpty {
                        CalendarListSection(title: "Overdue", occurrences: overdue, theme: theme, onOpenScheme: onOpenScheme)
                    }

                    if wide {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(calendar?.days ?? []) { day in
                                CalendarDayColumn(day: day, theme: theme, onOpenScheme: onOpenScheme)
                                    .frame(width: 132)
                            }
                        }
                        .padding(.horizontal, 12)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(calendar?.days ?? []) { day in
                                CalendarDayList(day: day, theme: theme, onOpenScheme: onOpenScheme)
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
            VStack(alignment: .leading, spacing: 1) {
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
        .frame(height: 48)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }

    private var rangeText: String {
        guard let calendar else { return "Calendar" }
        return "\(MobileDate.formatDay(calendar.startDate)) - \(MobileDate.formatDay(calendar.endDate))"
    }
}

private struct CalendarDayColumn: View {
    let day: MobileCalendarDay
    let theme: KnotQTheme
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
                    CalendarEventBlock(occurrence: occurrence, theme: theme) {
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
                    OccurrenceCompactRow(occurrence: occurrence, theme: theme, striped: false) {
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
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.danger)
            ForEach(occurrences) { occurrence in
                OccurrenceCompactRow(occurrence: occurrence, theme: theme, striped: false) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(3)
                    .strikethrough(occurrence.done)
                Text(occurrenceTimeLabel(occurrence))
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
                        Text(occurrenceTimeLabel(occurrence))
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
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Workspace")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                        Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(TitleIconButton(theme: theme))
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let root {
                        ForEach(root.children) { node in
                            NavigatorNodeRow(
                                node: node,
                                depth: 0,
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
            }
            .padding(14)
        }
        .background(theme.bgApp)
    }
}

private struct MobileListsNavigationPane: View {
    @EnvironmentObject private var model: AppModel
    let root: MobileNode?
    @Binding var selectedSchemeID: String?
    @Binding var path: [String]
    let theme: KnotQTheme
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let root {
                    ForEach(root.children) { node in
                        MobileNavigatorNode(
                            node: node,
                            depth: 0,
                            selectedSchemeID: selectedSchemeID,
                            theme: theme
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Lists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                        Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
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
                    EmptyState(title: "List missing", detail: "It may have been deleted.", theme: theme)
                }
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
}

private struct MobileNavigatorNode: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let depth: Int
    let selectedSchemeID: String?
    let theme: KnotQTheme

    @State private var renameNode: MobileNode?
    @State private var newSchemeInFolder = false

    var body: some View {
        if node.kind == "folder" {
            DisclosureGroup {
                ForEach(node.children) { child in
                    MobileNavigatorNode(
                        node: child,
                        depth: depth + 1,
                        selectedSchemeID: selectedSchemeID,
                        theme: theme
                    )
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.leading, CGFloat(depth) * 8)
            }
            .listRowBackground(theme.bgApp)
            .contextMenu {
                Button("New Scheme", systemImage: "doc.badge.plus") { newSchemeInFolder = true }
                Button("Rename", systemImage: "pencil") { renameNode = node }
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteFolder(id: node.id) }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { model.deleteFolder(id: node.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Folder", placeholder: "Folder name", initialText: target.name, validator: WorkspaceNameValidation.folderError) { name in
                    model.renameFolder(id: target.id, name: name)
                }
                .presentationDetents([.height(180)])
            }
            .sheet(isPresented: $newSchemeInFolder) {
                NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: WorkspaceNameValidation.schemeError) { name in
                    _ = model.createScheme(name: name, folderID: node.id)
                }
                .presentationDetents([.height(180)])
            }
        } else {
            NavigationLink(value: node.id) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark))
                        .frame(width: 10, height: 10)
                    Text(node.name)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 8)
                .contentShape(Rectangle())
            }
            .listRowBackground(selectedSchemeID == node.id ? theme.rowSelected : theme.bgApp)
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renameNode = node }
                ColorMenu(nodeID: node.id, colorIndex: node.colorIndex ?? 0, theme: theme)
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteScheme(id: node.id) }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { model.deleteScheme(id: node.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .sheet(item: $renameNode) { target in
                NameSheet(title: "Rename Scheme", placeholder: "Scheme name", initialText: target.name, validator: WorkspaceNameValidation.schemeError) { name in
                    model.renameScheme(id: target.id, name: name)
                }
                .presentationDetents([.height(180)])
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onPrevious) { Image(systemName: "chevron.left") }
                    .buttonStyle(TitleIconButton(theme: theme))
                DatePicker(
                    "",
                    selection: Binding(
                        get: { selectedDate },
                        set: { newValue in onDate(newValue) }
                    ),
                    displayedComponents: .date
                )
                    .labelsHidden()
                    .tint(theme.accent)
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(TitleIconButton(theme: theme))
                    .disabled(selectedEntry == nil)
                Button(action: onNext) { Image(systemName: "chevron.right") }
                    .buttonStyle(TitleIconButton(theme: theme))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }

            if sortedEntries.isEmpty {
                EmptyState(title: "Daily not ready", detail: "Could not create the daily queue.", theme: theme)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(sortedEntries) { entry in
                                DailyDayEditorSection(
                                    entry: entry,
                                    selected: entry.date == selectedDateKey,
                                    theme: theme,
                                    onSelect: { onDate(AppModel.date(from: entry.date) ?? selectedDate) }
                                )
                                .id(entry.date)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .onAppear { proxy.scrollTo(selectedDateKey, anchor: .center) }
                    .onChange(of: selectedDateKey) { _, value in
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(value, anchor: .center)
                        }
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
}

private struct DailyDayEditorSection: View {
    let entry: MobileDailyEntry
    let selected: Bool
    let theme: KnotQTheme
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IntegratedSchemeEditorPane(
                scheme: entry.scheme,
                theme: theme,
                onBack: nil,
                onAdd: {},
                usesNativeNavigation: false,
                showsEditorNavigation: false,
                editorScrollEnabled: false,
                editorInsets: UIEdgeInsets(top: 8, left: 35, bottom: 12, right: 18)
            )
            .frame(minHeight: editorHeight)
            .background(selected ? theme.rowSelected.opacity(0.42) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(selected ? dailyAccent : theme.divider)
                    .frame(width: 7, height: 7)
                    .padding(.top, 20)
                    .padding(.leading, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
    }

    private var dailyAccent: Color {
        theme.isDark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad)
    }

    private var editorHeight: CGFloat {
        let visualLineCount = entry.scheme.items.reduce(0) { total, item in
            total + max(1, Int(ceil(Double(max(item.text.count, 1)) / 34.0)))
        }
        let annotationCount = entry.scheme.items.filter { $0.start != nil || $0.end != nil }.count
        return max(126, CGFloat(max(1, visualLineCount)) * 25 + CGFloat(annotationCount) * 14 + 64)
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
                model.deleteItem(schemeID: schemeID, itemID: item.id)
            }
        }
        .sheet(isPresented: $showingDate) {
            ItemDateSheet(schemeID: schemeID, item: item)
                .presentationDetents([.medium])
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textMuted)
                TextField("Search KnotQ", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { model.search(query) }
                    .onChange(of: query) { _, value in model.search(value) }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(theme.bgModal, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(theme.borderOverlay, lineWidth: 1) }
            .padding(12)

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
                .padding(.bottom, 16)
            }
        }
        .background(theme.bgApp)
        .onAppear { model.search(query) }
    }
}

private struct DesktopSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
                    Text("KnotQ Mobile")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSoft)
                }

                SettingsSection(title: "Appearance", theme: theme) {
                    SettingsChoiceRow(title: "System", selected: currentTheme == "system", theme: theme) { model.setThemeMode("system") }
                    SettingsChoiceRow(title: "Dark", selected: currentTheme == "dark", theme: theme) { model.setThemeMode("dark") }
                    SettingsChoiceRow(title: "Light", selected: currentTheme == "light", theme: theme) { model.setThemeMode("light") }
                }

                SettingsSection(title: "Time", theme: theme) {
                    SettingsChoiceRow(title: "12-hour", selected: currentTime == "twelve_hour", theme: theme) { model.setTimeFormat("twelve_hour") }
                    SettingsChoiceRow(title: "24-hour", selected: currentTime == "twenty_four_hour", theme: theme) { model.setTimeFormat("twenty_four_hour") }
                }

                SettingsSection(title: "Storage", theme: theme) {
                    Text(model.snapshot?.workspacePath ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSoft)
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                    Button("Reset Workspace", role: .destructive) {
                        confirmReset = true
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.danger)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(16)
        }
        .background(theme.bgApp)
        .confirmationDialog("Reset Workspace", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetWorkspace() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var currentTheme: String { model.snapshot?.settings.themeMode ?? "dark" }
    private var currentTime: String { model.snapshot?.settings.timeFormat ?? "twelve_hour" }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let theme: KnotQTheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSoft)
            VStack(spacing: 0) {
                content
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.dividerSoft).frame(height: 1)
        }
    }
}

private struct SettingsChoiceRow: View {
    let title: String
    let selected: Bool
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                Spacer()
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: 11, height: 11)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .foregroundStyle(theme.textPrimary)
            .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

private struct MobileDock: View {
    let selected: MobilePane
    let theme: KnotQTheme
    let onSelect: (MobilePane) -> Void

    private let panes: [MobilePane] = [.calendar, .lists, .daily, .search, .settings]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(panes) { pane in
                Button { onSelect(pane) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(pane.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selected == pane ? theme.textPrimary : theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 58)
        .background(theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
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

private func occurrenceTimeLabel(_ occurrence: MobileOccurrence) -> String {
    let start = MobileDate.formatTime(occurrence.start)
    let end = MobileDate.formatTime(occurrence.end)
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
