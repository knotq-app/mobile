import SwiftUI

@main
struct KnotQMobileApp: App {
    @UIApplicationDelegateAdaptor(KnotQAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
        }
    }
}
