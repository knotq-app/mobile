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
        let start = MobileDate.formatTime(occurrence.start)
        let end = MobileDate.formatTime(occurrence.end)
        if let start, let end { return "\(start) - \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return occurrence.kind.capitalized
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

