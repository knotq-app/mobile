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

                ForEach(calendar.days) { day in
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
        }
        .refreshable { model.refresh() }
    }
}

struct OccurrenceRow: View {
    @EnvironmentObject private var model: AppModel
    let occurrence: MobileOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(colorForIndex(occurrence.colorIndex))
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
        switch self {
        case .none: nil
        case .daily: "FREQ=DAILY;INTERVAL=1"
        case .weekly: "FREQ=WEEKLY;INTERVAL=1"
        case .monthly: "FREQ=MONTHLY;INTERVAL=1"
        case .yearly: "FREQ=YEARLY;INTERVAL=1"
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
    @State private var schemeID: String?
    @State private var showDeleteConfirm = false

    private let isEditing: Bool
    private let editingSchemeID: String?
    private let editingItemID: String?

    init(theme: KnotQTheme, target: EventEditorTarget) {
        self.theme = theme
        self.target = target
        switch target {
        case .create(let date):
            isEditing = false
            editingSchemeID = nil
            editingItemID = nil
            _title = State(initialValue: "")
            _hasStart = State(initialValue: true)
            _hasEnd = State(initialValue: true)
            _start = State(initialValue: date)
            _end = State(initialValue: date.addingTimeInterval(3600))
            _repeatChoice = State(initialValue: .none)
            _schemeID = State(initialValue: nil)
        case .edit(let occ):
            isEditing = true
            editingSchemeID = occ.schemeId
            editingItemID = occ.itemId
            _title = State(initialValue: occ.title)
            let startDate = MobileDate.parseDateTime(occ.start)
            let endDate = MobileDate.parseDateTime(occ.end)
            _hasStart = State(initialValue: startDate != nil)
            _hasEnd = State(initialValue: endDate != nil)
            _start = State(initialValue: startDate ?? endDate ?? Date())
            _end = State(initialValue: endDate ?? startDate?.addingTimeInterval(3600) ?? Date().addingTimeInterval(3600))
            _repeatChoice = State(initialValue: RepeatChoice.from(rrule: occ.repeatRule))
            _schemeID = State(initialValue: occ.schemeId)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                }

                Section {
                    Picker("Kind", selection: editorKindBinding) {
                        Text("Event").tag(CalendarKind.event)
                        Text("Reminder").tag(CalendarKind.reminder)
                        Text("Assignment").tag(CalendarKind.assignment)
                    }
                    .pickerStyle(.segmented)

                    if hasStart {
                        DatePicker(hasEnd ? "Start" : "At", selection: $start)
                            .onChange(of: start) { _, value in
                                if hasEnd, end < value { end = value.addingTimeInterval(3600) }
                            }
                    }
                    if hasEnd {
                        DatePicker(hasStart ? "End" : "Due", selection: $end, in: (hasStart ? start : Date.distantPast)...)
                    }
                } footer: {
                    Text(kindDescription)
                }

                Section {
                    Picker("Repeat", selection: $repeatChoice) {
                        ForEach(RepeatChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }

                if !isEditing {
                    Section {
                        Picker("Scheme", selection: $schemeID) {
                            Text("Daily").tag(String?.none)
                            ForEach(model.snapshot?.schemes.filter { !$0.isDailyQueue } ?? []) { scheme in
                                Text(scheme.displayName).tag(String?.some(scheme.id))
                            }
                        }
                    }
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Delete Event", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasStart && !hasEnd)
                }
            }
            .confirmationDialog("Delete this event?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = editingSchemeID, let i = editingItemID {
                        model.deleteItem(schemeID: s, itemID: i)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var kindDescription: String {
        switch (hasStart, hasEnd) {
        case (true, true): "Event — a time block on the calendar."
        case (true, false): "Reminder — alerts at the start time."
        case (false, true): "Assignment — due at the end time."
        default: "Set a start or end time to place it on the calendar."
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
                    break
                }
            }
        )
    }

    private var derivedKind: CalendarKind {
        switch (hasStart, hasEnd) {
        case (true, true): .event
        case (true, false): .reminder
        case (false, true): .assignment
        default: .event
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let startValue = hasStart ? start : nil
        let endValue = hasEnd ? end : nil

        if isEditing, let s = editingSchemeID, let i = editingItemID {
            model.updateItemText(schemeID: s, itemID: i, text: trimmed)
            model.setItemDate(schemeID: s, itemID: i, kind: "start", date: startValue)
            model.setItemDate(schemeID: s, itemID: i, kind: "end", date: endValue)
            model.setItemRecurrence(schemeID: s, itemID: i, rrule: repeatChoice.rrule)
        } else {
            let anchorDay = startValue ?? endValue ?? Date()
            let newID = model.createCalendarItemReturningID(
                kind: derivedKind,
                text: trimmed,
                date: anchorDay,
                start: startValue,
                end: endValue,
                schemeID: schemeID
            )
            if let newID, let choiceRule = repeatChoice.rrule {
                let resolvedScheme = schemeID ?? model.snapshot?.daily.first {
                    $0.date == AppModel.dateOnly(anchorDay)
                }?.scheme.id
                if let resolvedScheme {
                    model.setItemRecurrence(schemeID: resolvedScheme, itemID: newID, rrule: choiceRule)
                }
            }
        }
        dismiss()
    }
}

struct AddCalendarItemSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CalendarKind = .event
    @State private var text = ""
    @State private var date = Date()
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(60 * 60)
    @State private var selectedSchemeID = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $text)
                Picker("Kind", selection: $kind) {
                    ForEach(CalendarKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if kind == .event || kind == .reminder {
                    DatePicker(kind == .event ? "Start" : "At", selection: $start)
                }
                if kind == .event || kind == .assignment {
                    DatePicker(kind == .event ? "End" : "Due", selection: $end)
                }
                Picker("Scheme", selection: $selectedSchemeID) {
                    Text("Daily").tag("")
                    ForEach(model.snapshot?.schemes.filter { !$0.isDailyQueue } ?? []) { scheme in
                        Text(scheme.displayName).tag(scheme.id)
                    }
                }
            }
            .navigationTitle("New Calendar Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addCalendarItem(
                            kind: kind,
                            text: text,
                            date: date,
                            start: kind == .event || kind == .reminder ? start : nil,
                            end: kind == .event || kind == .assignment ? end : nil,
                            schemeID: selectedSchemeID.isEmpty ? nil : selectedSchemeID
                        )
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
