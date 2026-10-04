import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("IndoorKart Data")
                .font(.title2.weight(.semibold))
            Text("Scaffolding ready")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
