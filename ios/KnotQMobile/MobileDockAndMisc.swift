import SwiftUI

struct SettingsThemeOption: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .frame(width: 18, alignment: .center)
            Text("  \(title)")
        }
    }
}

struct NotificationDefaultsSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme

    var body: some View {
        Section {
            Picker("Events", selection: eventOffsetBinding) {
                ForEach(eventDefaultNotificationOptions) { option in
                    Text(option.label).tag(option.offsetSecs)
                }
            }
            .pickerStyle(.menu)

            Picker("Assignments", selection: assignmentOffsetBinding) {
                ForEach(assignmentDefaultNotificationOptions) { option in
                    Text(option.label).tag(option.offsetSecs)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Notifications")
        }
        .listRowBackground(theme.bgModal)
    }

    private var eventOffsetBinding: Binding<Int32> {
        Binding(
            get: { model.snapshot?.settings.eventNotificationOffsetSecs ?? 10 * 60 },
            set: { offset in
                model.setNotificationDefaults(
                    eventOffsetSecs: offset,
                    assignmentOffsetSecs: model.snapshot?.settings.assignmentNotificationOffsetSecs ?? 2 * 60 * 60
                )
            }
        )
    }

    private var assignmentOffsetBinding: Binding<Int32> {
        Binding(
            get: { model.snapshot?.settings.assignmentNotificationOffsetSecs ?? 2 * 60 * 60 },
            set: { offset in
                model.setNotificationDefaults(
                    eventOffsetSecs: model.snapshot?.settings.eventNotificationOffsetSecs ?? 10 * 60,
                    assignmentOffsetSecs: offset
                )
            }
        )
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

                NotificationDefaultsSettingsSection(theme: theme)

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
            .safeAreaInset(edge: .bottom) {
                Color.clear
                    .frame(height: 118)
                    .background(theme.bgApp)
            }
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

    private let panes: [MobilePane] = [.home, .calendar, .settings]

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
        .background(AnyShapeStyle(theme.bgToolbar), in: Capsule())
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


struct MonthGridView: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    let initialDate: Date
    let onSelect: (Date) -> Void

    @State private var displayMonth = Date()
    @State private var dayOccurrences: [String: [MobileOccurrence]] = [:]

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                weekdayRow
                grid
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.bgModal)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(theme.borderOverlay, lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .background(theme.bgApp.ignoresSafeArea())
        .onAppear {
            displayMonth = startOfMonth(initialDate)
            loadMonth()
        }
    }

    private var header: some View {
        HStack {
            chevronButton(systemName: "chevron.left") { shiftMonth(-1) }
            Spacer()
            Text(monthTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            chevronButton(systemName: "chevron.right") { shiftMonth(1) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.buttonBg))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(calendar.veryShortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textMuted.opacity(theme.isDark ? 0.72 : 0.78))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var grid: some View {
        let cells = monthCells
        return VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(cells[row * 7 + col])
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: displayMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: initialDate)
        let occurrences = dayOccurrences[AppModel.dateOnly(date)] ?? []
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(calendar.startOfDay(for: date))
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 15, weight: (isToday || (isSelected && !isToday)) ? .semibold : .regular))
                    .foregroundStyle(dayTextColor(inMonth: inMonth, isToday: isToday, isSelected: isSelected))
                    .frame(width: 34, height: 34)
                    .background(dayBackground(isToday: isToday, isSelected: isSelected))
                dots(for: occurrences)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dots(for occurrences: [MobileOccurrence]) -> some View {
        let dots = orderedDistinctDots(occurrences, limit: 4)
        return HStack(spacing: 3) {
            ForEach(dots, id: \.key) { dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 6)
    }

    private func orderedDistinctDots(_ occurrences: [MobileOccurrence], limit: Int) -> [(key: String, color: Color)] {
        var seen = Set<String>()
        var result: [(key: String, color: Color)] = []
        for occurrence in occurrences {
            let key = isDailyQueueOccurrence(occurrence) ? "daily" : "scheme-\(occurrence.colorIndex)"
            guard seen.insert(key).inserted else { continue }
            result.append((key, occurrenceSchemeColor(occurrence, dark: theme.isDark)))
            if result.count >= limit { break }
        }
        return result
    }

    @ViewBuilder
    private func dayBackground(isToday: Bool, isSelected: Bool) -> some View {
        let dayHighlight = calendarDayHighlightColor(dark: theme.isDark)
        if isToday || isSelected {
            Circle().fill(dayHighlight)
        }
    }

    private func dayTextColor(inMonth: Bool, isToday: Bool, isSelected: Bool) -> Color {
        if isToday || isSelected { return .white }
        return inMonth ? theme.textPrimary : theme.textMuted.opacity(0.35)
    }

    private var monthCells: [Date] {
        let first = startOfMonth(displayMonth)
        let weekday = calendar.component(.weekday, from: first)
        let gridStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: first) ?? first
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayMonth)
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayMonth) {
            displayMonth = startOfMonth(next)
            loadMonth()
        }
    }

    private func loadMonth() {
        let components = calendar.dateComponents([.year, .month], from: displayMonth)
        guard let year = components.year, let month = components.month else { return }
        var map: [String: [MobileOccurrence]] = [:]
        for day in model.monthDays(year: year, month: month) {
            map[day.date] = day.occurrences
        }
        dayOccurrences = map
    }
}
