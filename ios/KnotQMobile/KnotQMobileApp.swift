import SwiftUI

@main
struct KnotQMobileApp: App {
    @UIApplicationDelegateAdaptor(KnotQAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
                .onChange(of: scenePhase) { _, phase in
                    // Re-check the sync entitlement + subscription lifecycle whenever
                    // the app returns to the foreground, so a subscription bought (or
                    // changed) while it was backgrounded shows up without waiting for
                    // the access token to expire. Cold launch and sign-in are covered
                    // by startSyncPolling's own refresh.
                    guard phase == .active else { return }
                    Task { await model.refreshSubscriptionStatus() }
                }
        }
    }
}
