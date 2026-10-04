import SwiftUI

struct RecordScreen: View {
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var sessionsStore: SessionsStore

    var body: some View {
        VStack(spacing: 0) {
            if let error = recorder.lastError {
                errorBanner(error)
            }

            HStack(spacing: 12) {
                watchStatusBadge
                voiceToggleBadge
            }
            .padding(.top, 12)

            Spacer()

            recordButton
                .padding(.vertical, 24)

            Text(formatElapsed(recorder.elapsedSeconds))
                .font(.system(size: 72, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.top, 8)

            Text(shortSessionID)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            steeringWheel
                .padding(.top, 24)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
        .animation(.easeInOut(duration: 0.2), value: recorder.lastError)
        .animation(.easeInOut(duration: 0.2), value: recorder.watchConnected)
        .onAppear {
            // На экране Записи ждём момента нажать Старт — не даём системе
            // усыпить телефон. На других вкладках auto-lock работает штатно.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            if !recorder.isRecording {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private var steeringWheel: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 140, height: 140)
                Image(systemName: "steeringwheel")
                    .font(.system(size: 100, weight: .regular))
                    .foregroundStyle(.primary)
                    .rotationEffect(.radians(-recorder.steeringAngleRadians))
                    .animation(.linear(duration: 0.05), value: recorder.steeringAngleRadians)
                // Метка «12 часов» в вершине круга — глазу легче заметить поворот.
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .offset(y: -70)
            }
            Text("\(Int(recorder.steeringAngleRadians * 180 / .pi))°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Виртуальный руль")
    }

    private var voiceToggleBadge: some View {
        Button {
            recorder.voiceEnabled.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Text(recorder.voiceEnabled ? "Звук: вкл" : "Звук: выкл")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(recorder.voiceEnabled ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.voiceEnabled ? "Отключить голос" : "Включить голос")
    }

    private var watchStatusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "applewatch")
            Text(recorder.watchConnected ? "Часы: на связи" : "Часы: не на связи")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(recorder.watchConnected ? Color.green : Color.secondary)
        .accessibilityLabel(recorder.watchConnected ? "Apple Watch на связи" : "Apple Watch не на связи")
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
                sessionsStore.reload()
            } else {
                recorder.start()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.green)
                    .frame(width: 220, height: 220)
                    .shadow(radius: 8, y: 4)
                Text(recorder.isRecording ? "Стоп" : "Старт")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Остановить запись" : "Начать запись")
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                recorder.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Закрыть")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var shortSessionID: String {
        if let id = recorder.currentSessionID {
            return String(id.uuidString.prefix(8))
        }
        return "—"
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
