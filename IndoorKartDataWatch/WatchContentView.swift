import SwiftUI

struct WatchContentView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "flag.checkered")
                .font(.title3)
            Text("IndoorKart")
                .font(.caption.weight(.semibold))
            Text("Ready")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    WatchContentView()
}
