import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingSyncSignIn = false

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.snapshot?.settings.themeMode ?? "dark" },
                    set: { model.setThemeMode($0) }
                )) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
            }

            Section("Time") {
                Picker("Clock", selection: Binding(
                    get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
                    set: { model.setTimeFormat($0) }
                )) {
                    Text("12-hour").tag("twelve_hour")
                    Text("24-hour").tag("twenty_four_hour")
                }
            }

            Section("Sync") {
                if let session = model.syncSession {
                    LabeledContent("Account", value: session.email)
                    LabeledContent("Backend", value: session.apiBase)
                    Button("Manage Sync Account", systemImage: "person.crop.circle") {
                        showingSyncSignIn = true
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.signOutSync()
                    }
                } else {
                    LabeledContent("Status") {
                        Text("Not signed in")
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign in to Sync", systemImage: "person.crop.circle") {
                        showingSyncSignIn = true
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingSyncSignIn) {
            SyncSignInSheet(theme: theme)
                .environmentObject(model)
                .presentationDetents([.medium])
        }
    }
}
