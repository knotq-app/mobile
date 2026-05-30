import SwiftUI

struct DailyScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        DailyFeedPane(
            entries: model.snapshot?.daily ?? [],
            selectedDate: model.selectedDate,
            theme: theme,
            onPrevious: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
            onNext: { model.ensureDailyQueue(date: Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
            onDate: { date in
                if AppModel.dateOnly(date) != AppModel.dateOnly(model.selectedDate) {
                    model.ensureDailyQueue(date: date)
                }
            },
            onBack: { dismiss() },
            onAdd: {
                if let scheme = model.snapshot?.daily.first(where: { $0.date == AppModel.dateOnly(model.selectedDate) })?.scheme {
                    model.addItem(schemeID: scheme.id, text: "", marker: .checkbox)
                }
            }
        )
        .navigationTitle("")
        .onAppear {
            model.ensureDailyQueue(date: model.selectedDate)
        }
    }
}
