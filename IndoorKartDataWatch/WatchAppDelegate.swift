import WatchKit

// WKApplicationDelegate.applicationDidFinishLaunching срабатывает на запуск
// от любого триггера (включая wake через WatchConnectivity), поэтому держим
// controller здесь — WatchConnection.delegate готов до того как SwiftUI соберёт сцену.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let controller = WatchRecordingController()

    func applicationDidFinishLaunching() {}
}
