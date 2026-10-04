import UIKit

// UIApplicationDelegate.didFinishLaunching срабатывает на любой запуск, включая
// background-launch по входящему WCSession-сообщению, поэтому держим recorder
// здесь — WatchConnection.delegate готов до того как система поднимет Scene.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let recorder = RecordingController()
    let sessionsStore = SessionsStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }
}
