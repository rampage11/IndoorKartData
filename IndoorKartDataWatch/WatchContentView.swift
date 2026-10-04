import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var controller: WatchRecordingController

    var body: some View {
        VStack(spacing: 8) {
            phoneStatusBadge

            Text(formattedElapsed(controller.elapsedSeconds))
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(controller.isRecording ? .red : .primary)

            if controller.isRecording, let bpm = controller.currentBPM {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                    Text("\(Int(bpm.rounded())) BPM")
                        .font(.caption.weight(.semibold))
                }
            } else if controller.isRecording {
                Text("Ждём пульс...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: toggle) {
                Text(controller.isRecording ? "Стоп" : "Старт")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRecording ? .red : .green)

            if let error = controller.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.2), value: controller.phoneConnected)
    }

    private var phoneStatusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone.gen3")
            Text(controller.phoneConnected ? "на связи" : "нет связи")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(controller.phoneConnected ? Color.green : Color.secondary)
    }

    private func toggle() {
        if controller.isRecording {
            controller.stop()
        } else {
            controller.start()
        }
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchRecordingController())
}
