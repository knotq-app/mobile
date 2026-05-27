import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(
                    get: { model.snapshot?.settings.themeMode ?? "dark" },
                    set: { model.setThemeMode($0) }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }

                Picker("Time", selection: Binding(
                    get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
                    set: { model.setTimeFormat($0) }
                )) {
                    Text("12-hour").tag("twelve_hour")
                    Text("24-hour").tag("twenty_four_hour")
                }
            }

            Section("Storage") {
                Text(model.snapshot?.workspacePath ?? "")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Section {
                Button("Reset Workspace", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset Workspace", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                model.resetWorkspace()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

