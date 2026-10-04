import SwiftUI

@main
struct IndoorKartDataApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.recorder)
                .environmentObject(appDelegate.sessionsStore)
        }
    }
}
