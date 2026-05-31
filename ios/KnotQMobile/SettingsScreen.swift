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
                .pickerStyle(.menu)
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

            GoogleCalendarSettingsSection(theme: theme)

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

struct GoogleCalendarSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme

    private var accountCount: Int32 {
        model.snapshot?.settings.googleAccountCount ?? 0
    }

    var body: some View {
        Section("Google Calendar") {
            if accountCount > 0 {
                LabeledContent("Accounts", value: "\(accountCount)")
                if let status = model.googleCalendarStatus, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(theme.textMuted)
                }
                Button {
                    Task { await model.syncGoogleCalendars() }
                } label: {
                    if model.googleSyncInProgress {
                        Label("Syncing Google Calendars", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Sync Google Calendars", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.googleSyncInProgress || model.googleAuthInProgress)
                Button {
                    Task { await model.connectGoogleCalendar() }
                } label: {
                    Label("Connect Another Google Calendar", systemImage: "calendar.badge.plus")
                }
                .disabled(model.googleAuthInProgress || model.googleSyncInProgress)
            } else {
                LabeledContent("Status") {
                    Text("Not connected")
                        .foregroundStyle(theme.textMuted)
                }
                Button {
                    Task { await model.connectGoogleCalendar() }
                } label: {
                    if model.googleAuthInProgress {
                        Label("Connecting Google Calendar", systemImage: "calendar.badge.plus")
                    } else {
                        Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                    }
                }
                .disabled(model.googleAuthInProgress || model.googleSyncInProgress)
            }
        }
    }
}
