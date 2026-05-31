import SwiftUI

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        List {
            if let calendar = model.snapshot?.calendar {
                Section {
                    HStack {
                        Button { model.weekOffset -= 1; model.refresh() } label: {
                            Image(systemName: "chevron.left")
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text("\(MobileDate.formatDay(calendar.startDate)) - \(MobileDate.formatDay(calendar.endDate))")
                                .font(.headline)
                            Button("Today") {
                                model.weekOffset = 0
                                model.selectedDate = Date()
                                model.refresh()
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Button { model.weekOffset += 1; model.refresh() } label: {
                            Image(systemName: "chevron.right")
                        }
                    }
                }

                if !calendar.overdue.isEmpty {
                    Section("Overdue") {
                        ForEach(calendar.overdue) { occurrence in
                            OccurrenceRow(occurrence: occurrence)
                        }
                    }
                }

                ForEach(calendar.visibleDays) { day in
                    Section(MobileDate.formatFullDay(day.date)) {
                        if day.occurrences.isEmpty {
                            Text("No calendar items")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(day.occurrences) { occurrence in
                                OccurrenceRow(occurrence: occurrence)
                            }
                        }
                    }
                }

                if !calendar.upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(calendar.upcoming) { occurrence in
                            OccurrenceRow(occurrence: occurrence)
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCalendarItemSheet()
                .presentationDetents([.fraction(0.50)])
        }
        .refreshable { model.refresh() }
    }
}

struct OccurrenceRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    let occurrence: MobileOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.body)
                    .strikethrough(occurrence.done)
                HStack(spacing: 8) {
                    Text(timeLabel)
                    Text(occurrence.schemeName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    private var timeLabel: String {
        let timeFormat = model.snapshot?.settings.timeFormat ?? "twelve_hour"
        let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat)
        let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat)
        if occurrence.kind == "reminder", let start { return "At \(start)" }
        if occurrence.kind == "assignment", let end { return "Due \(end)" }
        if let start, let end { return "\(start) - \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return occurrence.kind.capitalized
    }
}

// MARK: - Event editor (long-press create / tap edit)

enum EventEditorTarget: Identifiable {
    case create(Date)
    case edit(MobileOccurrence)

    var id: String {
        switch self {
        case .create(let date): "create-\(Int(date.timeIntervalSince1970))"
        case .edit(let occ): "edit-\(occ.schemeId)-\(occ.itemId)"
        }
    }
}

enum RepeatChoice: String, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Never"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        case .monthly: "Every Month"
        case .yearly: "Every Year"
        }
    }

    /// Bare RRULE body, matching `CalendarRecurrence.rrules` elsewhere.
    var rrule: String? {
        rrule(weekdays: Set<RepeatWeekdayChoice>())
    }

    func rrule(weekdays: Set<RepeatWeekdayChoice>) -> String? {
        switch self {
        case .none:
            return nil
        case .daily:
            return "FREQ=DAILY;INTERVAL=1"
        case .weekly:
            let codes = RepeatWeekdayChoice.orderedCodes(weekdays)
            if codes.isEmpty { return "FREQ=WEEKLY;INTERVAL=1" }
            return "FREQ=WEEKLY;INTERVAL=1;BYDAY=\(codes.joined(separator: ","))"
        case .monthly:
            return "FREQ=MONTHLY;INTERVAL=1"
        case .yearly:
            return "FREQ=YEARLY;INTERVAL=1"
        }
    }

    static func from(rrule: String?) -> RepeatChoice {
        guard let rrule = rrule?.uppercased() else { return .none }
        if rrule.contains("FREQ=DAILY") { return .daily }
        if rrule.contains("FREQ=WEEKLY") { return .weekly }
        if rrule.contains("FREQ=MONTHLY") { return .monthly }
        if rrule.contains("FREQ=YEARLY") { return .yearly }
        return .none
    }
}

private enum EventScopePromptAction: String {
    case save
    case delete
}

private struct EventScopePrompt: Identifiable {
    let action: EventScopePromptAction
    let canThis: Bool
    let canFuture: Bool
    let canAll: Bool

    var id: String { action.rawValue }

    var message: String {
        switch action {
        case .save: "Which tasks should these changes apply to?"
        case .delete: "Which tasks should be deleted?"
        }
    }
}

struct EventEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme
    let target: EventEditorTarget

    @State private var title: String
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatChoice: RepeatChoice
    @State private var weeklyRepeatDays: Set<RepeatWeekdayChoice>
    @State private var notificationOffsetSecs: Int32?
    @State private var notificationDirty: Bool
    @State private var schemeID: String?
    @State private var completed: Bool
    @State private var showDeleteConfirm = false
    @State private var scopePrompt: EventScopePrompt?

    private let isEditing: Bool
    private let editingSchemeID: String?
    private let editingItemID: String?
    private let editingOccurrence: MobileOccurrence?
    private let readOnly: Bool

    init(theme: KnotQTheme, target: EventEditorTarget) {
        self.theme = theme
        self.target = target
        switch target {
        case .create(let date):
            isEditing = false
            editingSchemeID = nil
            editingItemID = nil
            editingOccurrence = nil
            readOnly = false
            _title = State(initialValue: "")
            _hasStart = State(initialValue: true)
            _hasEnd = State(initialValue: true)
            _start = State(initialValue: date)
            _end = State(initialValue: date.addingTimeInterval(3600))
            _repeatChoice = State(initialValue: .none)
            _weeklyRepeatDays = State(initialValue: [RepeatWeekdayChoice.defaultFor(date: date)])
            _notificationOffsetSecs = State(initialValue: nil)
            _notificationDirty = State(initialValue: false)
            _schemeID = State(initialValue: nil)
            _completed = State(initialValue: false)
        case .edit(let occ):
            isEditing = true
            editingSchemeID = occ.schemeId
            editingItemID = occ.itemId
            editingOccurrence = occ
            readOnly = occ.isReadOnly
            _title = State(initialValue: occ.title)
            let startDate = MobileDate.parseDateTime(occ.start)
            let endDate = MobileDate.parseDateTime(occ.end)
            _hasStart = State(initialValue: startDate != nil)
            _hasEnd = State(initialValue: endDate != nil)
            _start = State(initialValue: startDate ?? endDate ?? Date())
            _end = State(initialValue: endDate ?? startDate?.addingTimeInterval(3600) ?? Date().addingTimeInterval(3600))
            _repeatChoice = State(initialValue: RepeatChoice.from(rrule: occ.repeatRule))
            _weeklyRepeatDays = State(initialValue: RepeatWeekdayChoice.selected(from: occ.repeatRule, fallbackDate: startDate ?? endDate ?? Date()))
            _notificationOffsetSecs = State(initialValue: occ.notificationOffsetSecs)
            _notificationDirty = State(initialValue: false)
            _schemeID = State(initialValue: occ.schemeId)
            _completed = State(initialValue: occ.done)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .disabled(readOnly)
                    if isEditing && !readOnly {
                        Toggle("Completed", isOn: $completed)
                    }
                    // Scheme lives with the title — they're usually set together.
                    if !isEditing {
                        Picker("Scheme", selection: $schemeID) {
                            calendarSchemeRow(name: "Daily", color: dailyQueueColor(dark: theme.isDark))
                                .tag(String?.none)
                            ForEach(model.snapshot?.schemes.filter { !$0.isDailyQueue && !$0.isReadOnly } ?? []) { scheme in
                                calendarSchemeRow(name: scheme.displayName, color: schemeColor(scheme.colorIndex, dark: theme.isDark))
                                    .tag(String?.some(scheme.id))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                Section {
                    CalendarKindSelector(selection: editorKindBinding, disabled: readOnly)

                    if hasStart {
                        DatePicker(hasEnd ? "Start" : "At", selection: $start)
                            .disabled(readOnly)
                            .onChange(of: start) { _, value in
                                if hasEnd, end < value { end = value.addingTimeInterval(3600) }
                            }
                    }
                    if hasEnd {
                        DatePicker(hasStart ? "End" : "Due", selection: $end, in: (hasStart ? start : Date.distantPast)...)
                            .disabled(readOnly)
                    }
                    if hasStart || hasEnd {
                        Picker("Notification", selection: notificationOffsetBinding) {
                            ForEach(occurrenceNotificationOptionsIncluding(notificationOffsetBinding.wrappedValue)) { option in
                                Text(option.label).tag(option.offsetSecs)
                            }
                        }
                        .disabled(readOnly)
                    }
                }

                if hasStart || hasEnd {
                    Section {
                        Picker("Repeat", selection: $repeatChoice) {
                            ForEach(RepeatChoice.allCases) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        .onChange(of: repeatChoice) { _, choice in
                            if choice == .weekly, weeklyRepeatDays.isEmpty {
                                weeklyRepeatDays = [RepeatWeekdayChoice.defaultFor(date: repeatAnchorDate)]
                            }
                        }
                        if repeatChoice == .weekly {
                            WeeklyRepeatDaysPicker(selection: $weeklyRepeatDays, disabled: readOnly)
                        }
                    }
                    .disabled(readOnly)
                }

                if isEditing && !readOnly {
                    Section {
                        Button(role: .destructive) { requestDelete() } label: {
                            Label("Delete Task", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(readOnly ? "Task Details" : (isEditing ? "Edit" : "New"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(readOnly ? "Done" : "Save") {
                        if readOnly {
                            dismiss()
                        } else {
                            requestSave()
                        }
                    }
                }
            }
            .confirmationDialog("Delete this task?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    deleteEditing(scope: .allEvents)
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Recurring Task", isPresented: Binding(
                get: { scopePrompt != nil },
                set: { showing in
                    if !showing { scopePrompt = nil }
                }
            ), titleVisibility: .visible) {
                if let prompt = scopePrompt {
                    if prompt.canThis {
                        Button(EventOccurrenceScope.thisEvent.label) {
                            applyScopeChoice(.thisEvent)
                        }
                    }
                    if prompt.canFuture {
                        Button(EventOccurrenceScope.allFuture.label) {
                            applyScopeChoice(.allFuture)
                        }
                    }
                    if prompt.canAll {
                        Button(EventOccurrenceScope.allEvents.label) {
                            applyScopeChoice(.allEvents)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { scopePrompt = nil }
            } message: {
                Text(scopePrompt?.message ?? "")
            }
        }
    }

    private var editorKindBinding: Binding<CalendarKind> {
        Binding(
            get: { derivedKind },
            set: { kind in
                switch kind {
                case .event:
                    if !hasStart { start = hasEnd ? end.addingTimeInterval(-3600) : Date() }
                    if !hasEnd { end = start.addingTimeInterval(3600) }
                    hasStart = true
                    hasEnd = true
                    if end < start { end = start.addingTimeInterval(3600) }
                case .reminder:
                    if !hasStart { start = hasEnd ? end : Date() }
                    hasStart = true
                    hasEnd = false
                case .assignment:
                    if !hasEnd { end = hasStart ? start : Date() }
                    hasStart = false
                    hasEnd = true
                case .task:
                    hasStart = false
                    hasEnd = false
                    repeatChoice = .none
                }
            }
        )
    }

    private var derivedKind: CalendarKind {
        switch (hasStart, hasEnd) {
        case (true, true): .event
        case (true, false): .reminder
        case (false, true): .assignment
        default: .task
        }
    }

    private var repeatAnchorDate: Date {
        if hasStart { return start }
        if hasEnd { return end }
        return start
    }

    private var notificationOffsetBinding: Binding<Int32> {
        Binding(
            get: {
                notificationOffsetSecs
                    ?? defaultNotificationOffset(kind: derivedKind, settings: model.snapshot?.settings)
            },
            set: { offset in
                notificationOffsetSecs = offset
                notificationDirty = true
            }
        )
    }

    private func requestSave() {
        if let prompt = saveScopePrompt() {
            scopePrompt = prompt
        } else {
            save(scope: .allEvents)
        }
    }

    private func requestDelete() {
        if let occurrence = editingOccurrence, occurrence.isRecurring {
            scopePrompt = EventScopePrompt(
                action: .delete,
                canThis: true,
                canFuture: occurrence.canDeleteFuture,
                canAll: true
            )
        } else {
            showDeleteConfirm = true
        }
    }

    private func applyScopeChoice(_ scope: EventOccurrenceScope) {
        guard let action = scopePrompt?.action else { return }
        scopePrompt = nil
        switch action {
        case .save:
            save(scope: scope)
        case .delete:
            deleteEditing(scope: scope)
        }
    }

    private func saveScopePrompt() -> EventScopePrompt? {
        guard let occurrence = editingOccurrence, occurrence.isRecurring else { return nil }
        let startValue = hasStart ? start : nil
        let endValue = hasEnd ? end : nil
        let originalStart = MobileDate.parseDateTime(occurrence.start)
        let originalEnd = MobileDate.parseDateTime(occurrence.end)
        guard datesDiffer(originalStart, startValue) || datesDiffer(originalEnd, endValue) else {
            return nil
        }
        let presenceChanged = (originalStart == nil) != (startValue == nil)
            || (originalEnd == nil) != (endValue == nil)
        return EventScopePrompt(
            action: .save,
            canThis: !presenceChanged,
            canFuture: !presenceChanged,
            canAll: true
        )
    }

    private func datesDiffer(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return false
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) > 0.5
        default:
            return true
        }
    }

    private func deleteEditing(scope: EventOccurrenceScope) {
        if let occurrence = editingOccurrence {
            model.deleteEventOccurrence(occurrence, scope: scope)
        } else if let s = editingSchemeID, let i = editingItemID {
            model.deleteItem(schemeID: s, itemID: i)
        }
        dismiss()
    }

    private func save(scope: EventOccurrenceScope) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let startValue = hasStart ? start : nil
        let endValue = hasEnd ? end : nil
        let notificationChangedByUnscheduling = !(hasStart || hasEnd)
            && editingOccurrence?.notificationOffsetSecs != nil

        if isEditing, let occurrence = editingOccurrence {
            model.commitEventEdit(
                occurrence: occurrence,
                title: trimmed,
                start: startValue,
                end: endValue,
                rrule: (hasStart || hasEnd) ? repeatChoice.rrule(weekdays: weeklyRepeatDays) : nil,
                notificationOffsetSecs: hasStart || hasEnd ? notificationOffsetSecs : nil,
                notificationDirty: ((hasStart || hasEnd) && notificationDirty) || notificationChangedByUnscheduling,
                done: completed,
                scope: scope
            )
        } else {
            let anchorDay = startValue ?? endValue ?? start
            let newID = model.createCalendarItemReturningID(
                kind: derivedKind,
                text: trimmed,
                date: anchorDay,
                start: startValue,
                end: endValue,
                schemeID: schemeID
            )
            if let newID {
                let resolvedScheme = schemeID ?? model.snapshot?.daily.first {
                    $0.date == AppModel.dateOnly(anchorDay)
                }?.scheme.id
                if let resolvedScheme {
                    if (hasStart || hasEnd), let choiceRule = repeatChoice.rrule(weekdays: weeklyRepeatDays) {
                        model.setItemRecurrence(schemeID: resolvedScheme, itemID: newID, rrule: choiceRule)
                    }
                    if (hasStart || hasEnd), notificationDirty {
                        model.setOccurrenceNotificationOffset(
                            schemeID: resolvedScheme,
                            itemID: newID,
                            offsetSecs: notificationOffsetSecs
                        )
                    }
                }
            }
        }
        dismiss()
    }
}

struct AddCalendarItemSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @State private var kind: CalendarKind = .task
    @State private var text = ""
    @State private var date = Date()
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(60 * 60)
    @State private var notificationOffsetSecs: Int32?
    @State private var notificationDirty = false
    @State private var selectedSchemeID = ""

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $text)
                    Picker("Scheme", selection: $selectedSchemeID) {
                        calendarSchemeRow(name: "Daily", color: dailyQueueColor(dark: theme.isDark))
                            .tag("")
                        ForEach(model.snapshot?.schemes.filter { !$0.isDailyQueue && !$0.isReadOnly } ?? []) { scheme in
                            calendarSchemeRow(name: scheme.displayName, color: schemeColor(scheme.colorIndex, dark: theme.isDark))
                                .tag(scheme.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    CalendarKindSelector(selection: $kind)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    if kind == .event || kind == .reminder {
                        DatePicker(kind == .event ? "Start" : "At", selection: $start)
                    }
                    if kind == .event || kind == .assignment {
                        DatePicker(kind == .event ? "End" : "Due", selection: $end)
                    }
                    if kind != .task {
                        Picker("Notification", selection: notificationOffsetBinding) {
                            ForEach(occurrenceNotificationOptionsIncluding(notificationOffsetBinding.wrappedValue)) { option in
                                Text(option.label).tag(option.offsetSecs)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let schemeID = selectedSchemeID.isEmpty ? nil : selectedSchemeID
                        let itemID = model.createCalendarItemReturningID(
                            kind: kind,
                            text: text,
                            date: date,
                            start: kind == .event || kind == .reminder ? start : nil,
                            end: kind == .event || kind == .assignment ? end : nil,
                            schemeID: schemeID
                        )
                        if kind != .task, notificationDirty, let itemID {
                            let resolvedSchemeID = schemeID ?? model.snapshot?.daily.first {
                                $0.date == AppModel.dateOnly(date)
                            }?.scheme.id
                            if let resolvedSchemeID {
                                model.setOccurrenceNotificationOffset(
                                    schemeID: resolvedSchemeID,
                                    itemID: itemID,
                                    offsetSecs: notificationOffsetSecs
                                )
                            }
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var notificationOffsetBinding: Binding<Int32> {
        Binding(
            get: {
                notificationOffsetSecs
                    ?? defaultNotificationOffset(kind: kind, settings: model.snapshot?.settings)
            },
            set: { offset in
                notificationOffsetSecs = offset
                notificationDirty = true
            }
        )
    }
}

private func calendarSchemeRow(name: String, color: Color) -> some View {
    HStack(spacing: 8) {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
        Text(name)
    }
}
