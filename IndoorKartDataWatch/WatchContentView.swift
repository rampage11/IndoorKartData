import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var controller: WatchRecordingController

    var body: some View {
        NavigationStack {
            Group {
                if controller.isRecording {
                    RecordingScreen()
                } else {
                    IdleScreen()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
        }
    }
}

// MARK: - Idle

private struct IdleScreen: View {
    @EnvironmentObject private var controller: WatchRecordingController

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                phoneStatusBadge

                kartNumberBlock

                NavigationLink {
                    KartNumberPickerScreen()
                } label: {
                    Text(controller.kartNumber >= 1 ? "Изменить" : "Задать")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)

                Button {
                    controller.start()
                } label: {
                    Text("Старт")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(controller.kartNumber < 1)

                if let best = controller.bestLapMs {
                    HStack(spacing: 4) {
                        Text("Лучший")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(formatLap(ms: best))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }

                if let error = controller.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var kartNumberBlock: some View {
        VStack(spacing: 0) {
            Text("Номер карта")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if controller.kartNumber >= 1 {
                Text("\(controller.kartNumber)")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text("Задай номер карта")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var phoneStatusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone.gen3")
            Text("iPhone:")
            Text(controller.phoneConnected ? "вкл" : "выкл")
                .foregroundStyle(controller.phoneConnected ? .green : .secondary)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Recording

private struct RecordingScreen: View {
    @EnvironmentObject private var controller: WatchRecordingController

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                phoneStatusBadge
                Spacer()
                recordingBadge
            }

            // Последний круг — главный элемент. Моноширный, крупно, scales down
            // если на мелком корпусе не влезает.
            VStack(spacing: 0) {
                Text("Последний круг")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lastLapText)
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(controller.currentLastLapMs == nil ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    Image(systemName: "stopwatch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formattedElapsed(controller.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                }
                if let bpm = controller.currentBPM {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                        Text("\(Int(bpm.rounded()))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
            }

            Button {
                controller.stop()
            } label: {
                Text("Стоп")
                    .font(.footnote.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 4)
    }

    private var lastLapText: String {
        if let ms = controller.currentLastLapMs {
            return formatLap(ms: ms)
        }
        return "--:--.---"
    }

    private var phoneStatusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "iphone.gen3")
            Text(controller.phoneConnected ? "вкл" : "выкл")
        }
        .font(.caption2)
        .foregroundStyle(controller.phoneConnected ? .green : .secondary)
    }

    private var recordingBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("Запись")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.red)
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Shared helpers

fileprivate func formatLap(ms: Int) -> String {
    let safe = max(0, ms)
    let totalSeconds = safe / 1000
    let m = totalSeconds / 60
    let s = totalSeconds % 60
    let mm = safe % 1000
    return String(format: "%02d:%02d.%03d", m, s, mm)
}

#Preview("Idle") {
    WatchContentView()
        .environmentObject(WatchRecordingController())
}
