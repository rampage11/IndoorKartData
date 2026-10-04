import SwiftUI

struct ContentView: View {
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
    }
}

#Preview {
    ContentView()
        .environmentObject(RecordingController())
        .environmentObject(SessionsStore())
}
