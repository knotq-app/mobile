import SwiftUI

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel

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
        return MobileDate.occurrenceLabel(occurrence, timeFormat: timeFormat)
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
                    // Scheme lives with the title — they're usually set together.
                    if !isEditing {
                        CalendarSchemePicker(selection: $schemeID, theme: theme)
                    }

                    ScheduledDateFields(
                        kind: editorKindBinding,
                        hasStart: $hasStart,
                        hasEnd: $hasEnd,
                        start: $start,
                        end: $end,
                        disabled: readOnly
                    )
                    if isEditing && !readOnly {
                        Toggle("Completed", isOn: $completed)
                    }
                    if hasStart || hasEnd {
                        NotificationLeadTimePicker(selection: notificationOffsetBinding, disabled: readOnly)
                        RepeatRulePicker(
                            selection: $repeatChoice,
                            weekdays: $weeklyRepeatDays,
                            anchorDate: repeatAnchorDate,
                            disabled: readOnly
                        )
                    }
                }

                // When editing, the scheme lives lower — below the schedule
                // fields — so seeing or changing where a task lives is a
                // deliberate, separate action from editing its details. Shown
                // (disabled) for read-only events too, so the scheme is at least
                // visible there.
                if isEditing, let currentSchemeID = editingSchemeID {
                    Section {
                        EventSchemeTransferPicker(
                            selection: $schemeID,
                            currentSchemeID: currentSchemeID,
                            currentSchemeName: editingOccurrence?.schemeName ?? "Scheme",
                            theme: theme
                        )
                        .disabled(readOnly)
                    } footer: {
                        if !readOnly {
                            Text("Move this task to a different scheme.")
                        }
                    }
                }

                if isEditing && !readOnly {
                    Section {
                        Button(role: .destructive) { requestDelete() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .contentMargins(.top, 6, for: .scrollContent)
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
            // Apply the scheme transfer after the edits land, so the moved item
            // carries them. No-op when the scheme was left unchanged.
            if !readOnly, let target = schemeID, target != occurrence.schemeId {
                model.moveItemToScheme(
                    sourceSchemeID: occurrence.schemeId,
                    targetSchemeID: target,
                    itemID: occurrence.itemId
                )
            }
        } else {
            let anchorDay = startValue ?? endValue ?? start
            let schemeID = schemeID
            let kind = derivedKind
            let hasSchedule = hasStart || hasEnd
            let choiceRule = repeatChoice.rrule(weekdays: weeklyRepeatDays)
            let notificationDirty = notificationDirty
            let notificationOffsetSecs = notificationOffsetSecs
            let model = model
            // The create resolves on the bridge queue; the follow-ups run after
            // it returns, so the sheet can dismiss immediately.
            Task {
                let newID = await model.createCalendarItemReturningID(
                    kind: kind,
                    text: trimmed,
                    date: anchorDay,
                    start: startValue,
                    end: endValue,
                    schemeID: schemeID
                )
                guard let newID,
                      let resolvedScheme = schemeID ?? model.todayDailySchemeID() else { return }
                if hasSchedule, let choiceRule {
                    model.setItemRecurrence(schemeID: resolvedScheme, itemID: newID, rrule: choiceRule)
                }
                if hasSchedule, notificationDirty {
                    model.setOccurrenceNotificationOffset(
                        schemeID: resolvedScheme,
                        itemID: newID,
                        offsetSecs: notificationOffsetSecs
                    )
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
    @State private var selectedSchemeID: String?

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $text)
                    CalendarSchemePicker(selection: $selectedSchemeID, theme: theme)
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
                        NotificationLeadTimePicker(selection: notificationOffsetBinding)
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
                        let kind = kind
                        let text = text
                        let date = date
                        let start = kind == .event || kind == .reminder ? start : nil
                        let end = kind == .event || kind == .assignment ? end : nil
                        let selectedSchemeID = selectedSchemeID
                        let notificationDirty = notificationDirty
                        let notificationOffsetSecs = notificationOffsetSecs
                        let model = model
                        Task {
                            let itemID = await model.createCalendarItemReturningID(
                                kind: kind,
                                text: text,
                                date: date,
                                start: start,
                                end: end,
                                schemeID: selectedSchemeID
                            )
                            guard kind != .task, notificationDirty, let itemID,
                                  let resolvedSchemeID = selectedSchemeID ?? model.todayDailySchemeID() else {
                                return
                            }
                            model.setOccurrenceNotificationOffset(
                                schemeID: resolvedSchemeID,
                                itemID: itemID,
                                offsetSecs: notificationOffsetSecs
                            )
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
