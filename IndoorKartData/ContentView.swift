import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = RecordingController()
    @StateObject private var sessionsStore = SessionsStore()

    var body: some View {
        TabView {
            RecordScreen()
                .tabItem {
                    Label("Запись", systemImage: "record.circle")
                }

            SessionsListScreen()
                .tabItem {
                    Label("Сессии", systemImage: "list.bullet.rectangle")
                }
        }
        .environmentObject(recorder)
        .environmentObject(sessionsStore)
    }
}

#Preview {
    ContentView()
}
