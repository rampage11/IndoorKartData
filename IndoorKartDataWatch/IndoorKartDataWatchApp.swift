import SwiftUI

@main
struct IndoorKartDataWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(appDelegate.controller)
        }
    }
}
