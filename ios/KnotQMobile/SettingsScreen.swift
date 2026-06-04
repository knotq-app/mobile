import StoreKit
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingSyncSignIn = false
    @State private var showingCancelConfirm = false
    @State private var showingDeleteConfirm = false

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        Form {
            Section("Sync") {
                if let session = model.syncSession {
                    LabeledContent("Account", value: session.email)
                    LabeledContent("Backend", value: session.apiBase)
                    Button("Manage Sync Account", systemImage: "person.crop.circle") {
                        showingSyncSignIn = true
                    }
                    if session.supportsSync {
                        Button("Cancel Subscription", systemImage: "xmark.circle", role: .destructive) {
                            showingCancelConfirm = true
                        }
                        .disabled(model.syncAccountActionInProgress)
                    } else {
                        LabeledContent("Subscription") {
                            Text("Sync turned off")
                                .foregroundStyle(.secondary)
                        }
                        if model.syncProducts.isEmpty {
                            Text("Subscribe to sync your workspace across devices.")
                                .font(.footnote)
                                .foregroundStyle(theme.textMuted)
                        }
                        ForEach(model.syncProducts, id: \.id) { product in
                            Button {
                                Task { await model.purchaseSync(product) }
                            } label: {
                                HStack {
                                    Label(product.displayName, systemImage: "icloud.and.arrow.up")
                                    Spacer()
                                    Text(product.displayPrice)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.purchaseInProgress)
                        }
                        Button("Restore Purchases", systemImage: "arrow.clockwise") {
                            Task { await model.restorePurchases() }
                        }
                        .disabled(model.purchaseInProgress)
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.signOutSync()
                    }
                    Button("Delete Account", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                    .disabled(model.syncAccountActionInProgress)
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
            .listRowBackground(theme.bgModal)

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.snapshot?.settings.themeMode ?? "dark" },
                    set: { model.setThemeMode($0) }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(theme.bgModal)

            Section("Time") {
                Picker("Clock", selection: Binding(
                    get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
                    set: { model.setTimeFormat($0) }
                )) {
                    Text("12-hour").tag("twelve_hour")
                    Text("24-hour").tag("twenty_four_hour")
                }
            }
            .listRowBackground(theme.bgModal)

            NotificationDefaultsSettingsSection(theme: theme)

            GoogleCalendarSettingsSection(theme: theme)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .navigationTitle("Settings")
        .task {
            // Load products when an account has no entitlement, so the paywall can
            // show real prices.
            if let session = model.syncSession, !session.supportsSync {
                await model.loadSyncProducts()
            }
        }
        .sheet(isPresented: $showingSyncSignIn) {
            SyncSignInSheet(theme: theme)
                .environmentObject(model)
                .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Cancel sync subscription?",
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Turn Off Sync", role: .destructive) {
                Task { await model.cancelSyncSubscription() }
            }
            Button("Keep Sync", role: .cancel) {}
        } message: {
            Text("Sync stops on all your devices. Your local workspace stays on this device, and you can sign in again later to re-enable sync.")
        }
        .confirmationDialog(
            "Delete account?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await model.deleteSyncAccount() }
            }
            Button("Keep Account", role: .cancel) {}
        } message: {
            Text("Your account and synced data are scheduled for deletion. You have 14 days to undo this by signing back in before everything is permanently erased.")
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
        .listRowBackground(theme.bgModal)
    }
}
