import SwiftUI

@main
struct KnotQMobileApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
        }
    }
}
