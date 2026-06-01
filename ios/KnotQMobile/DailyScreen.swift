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
            onPrevious: { model.selectDate(Calendar.current.date(byAdding: .day, value: -1, to: model.selectedDate) ?? model.selectedDate) },
            onNext: { model.selectDate(Calendar.current.date(byAdding: .day, value: 1, to: model.selectedDate) ?? model.selectedDate) },
            onDate: { date in
                if AppModel.dateOnly(date) != AppModel.dateOnly(model.selectedDate) {
                    model.selectDate(date)
                }
            },
            onBack: { dismiss() },
            onAdd: {
                model.addTodayDailyItem(text: "", marker: .checkbox)
            }
        )
        .navigationTitle("")
        .onAppear {
            model.ensureTodayDailyQueue()
        }
    }
}
