import SwiftUI

// MARK: - Sheets

struct AddItemSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var schemeID: String?
    var todayDaily = false
    @State private var text = ""
    @State private var marker: Marker = .checkbox

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item", text: $text, axis: .vertical)
                Picker("Marker", selection: $marker) {
                    ForEach(Marker.allCases) { marker in
                        Label(marker.label, systemImage: marker.icon).tag(marker)
                    }
                }
            }
            .navigationTitle("New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if todayDaily {
                            model.addTodayDailyItem(text: text, marker: marker)
                        } else if let schemeID {
                            model.addItem(schemeID: schemeID, text: text, marker: marker)
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// The line "Schedule" sheet. Mirrors the calendar's EventEditorSheet — a kind
/// segmented control, conditional start/end pickers with footer guidance, and a
/// repeat picker — but operates on an existing scheme line.
struct ItemDateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let schemeID: String
    let item: MobileItem

    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatChoice: RepeatChoice
    @State private var weeklyRepeatDays: Set<RepeatWeekdayChoice>
    @State private var notificationOffsetSecs: Int32?
    private let initialNotificationOffsetSecs: Int32?

    init(schemeID: String, item: MobileItem) {
        self.schemeID = schemeID
        self.item = item
        let startDate = MobileDate.parseDateTime(item.start)
        let endDate = MobileDate.parseDateTime(item.end)
        _hasStart = State(initialValue: startDate != nil)
        _hasEnd = State(initialValue: endDate != nil)
        _start = State(initialValue: startDate ?? endDate ?? Date())
        _end = State(initialValue: endDate ?? startDate?.addingTimeInterval(3600) ?? Date().addingTimeInterval(3600))
        _repeatChoice = State(initialValue: RepeatChoice.from(rrule: item.repeatRule))
        _weeklyRepeatDays = State(initialValue: RepeatWeekdayChoice.selected(from: item.repeatRule, fallbackDate: startDate ?? endDate ?? Date()))
        _notificationOffsetSecs = State(initialValue: item.notificationOffsetSecs)
        initialNotificationOffsetSecs = item.notificationOffsetSecs
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CalendarKindSelector(selection: kindBinding)

                    if hasStart {
                        DatePicker(hasEnd ? "Start" : "At", selection: $start)
                            .onChange(of: start) { _, value in
                                if hasEnd, end < value { end = value.addingTimeInterval(3600) }
                            }
                    }
                    if hasEnd {
                        DatePicker(hasStart ? "End" : "Due", selection: $end, in: (hasStart ? start : Date.distantPast)...)
                    }
                    if hasStart || hasEnd {
                        Picker("Notification", selection: notificationOffsetBinding) {
                            ForEach(occurrenceNotificationOptionsIncluding(notificationOffsetBinding.wrappedValue)) { option in
                                Text(option.label).tag(option.offsetSecs)
                            }
                        }
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
                            WeeklyRepeatDaysPicker(selection: $weeklyRepeatDays)
                        }
                    }
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private var kindBinding: Binding<CalendarKind> {
        Binding(
            get: {
                switch (hasStart, hasEnd) {
                case (true, true): .event
                case (true, false): .reminder
                case (false, true): .assignment
                default: .task
                }
            },
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

    private var repeatAnchorDate: Date {
        if hasStart { return start }
        if hasEnd { return end }
        return start
    }

    private var notificationOffsetBinding: Binding<Int32> {
        Binding(
            get: {
                notificationOffsetSecs
                    ?? defaultNotificationOffset(kind: kindBinding.wrappedValue, settings: model.snapshot?.settings)
            },
            set: { offset in
                notificationOffsetSecs = offset
            }
        )
    }

    private func save() {
        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "start", date: hasStart ? start : nil)
        model.setItemDate(schemeID: schemeID, itemID: item.id, kind: "end", date: hasEnd ? end : nil)
        model.setItemRecurrence(schemeID: schemeID, itemID: item.id, rrule: (hasStart || hasEnd) ? repeatChoice.rrule(weekdays: weeklyRepeatDays) : nil)
        if hasStart || hasEnd {
            if notificationOffsetSecs != initialNotificationOffsetSecs {
                model.setOccurrenceNotificationOffset(
                    schemeID: schemeID,
                    itemID: item.id,
                    offsetSecs: notificationOffsetSecs
                )
            }
        } else if initialNotificationOffsetSecs != nil {
            model.setOccurrenceNotificationOffset(
                schemeID: schemeID,
                itemID: item.id,
                offsetSecs: nil
            )
        }
        dismiss()
    }
}
