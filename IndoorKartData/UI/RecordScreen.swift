import SwiftUI

struct RecordScreen: View {
    @EnvironmentObject var recorder: RecordingController
    @EnvironmentObject var sessionsStore: SessionsStore
    @ObservedObject private var timing = TimingClient.shared
    @ObservedObject private var katahub = KatahubClient.shared
    @State private var stopHoldProgress: Double = 0
    @State private var stopHoldTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            if let error = recorder.lastError {
                errorBanner(error)
            }

            HStack(spacing: 12) {
                watchStatusBadge
                voiceToggleBadge
                katahubBadge
            }
            .padding(.top, 12)

            timingDebugOverlay
                .padding(.top, 6)

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
                    .rotationEffect(.radians(recorder.steeringAngleRadians))
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

    private var timingDebugOverlay: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(timing.isConnected ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text("Timing: \(timing.connectionState)")
            }
            HStack(spacing: 10) {
                Text("карт: \(recorder.kartNumber > 0 ? "\(recorder.kartNumber)" : "—")")
                Text("круг: \(timing.lapCount.map { "\($0)" } ?? "—")")
                Text("флаг: \(timing.currentFlag ?? "—")")
            }
            HStack(spacing: 10) {
                Text("hb: \(timing.heartbeatCount)")
                Text("comp: \(timing.compCount)")
                Text("мой: \(timing.compMineCount)")
            }
            if let seen = timing.lastCompKartSeen {
                Text("виден: \(seen)")
            }
            if let race = timing.currentRaceID {
                Text("race: \(race.prefix(8))")
            }
            if let last = timing.lastLapMs {
                let m = (last / 1000) / 60
                let s = (last / 1000) % 60
                let mm = last % 1000
                Text(String(format: "last lap: %02d:%02d.%03d", m, s, mm))
                    .foregroundStyle(.primary)
            }
            if let gap = timing.chaserGapMs {
                let s = gap / 1000
                let mm = gap % 1000
                Text(String(format: "сзади: +%d.%03d", s, mm))
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
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

    private var katahubBadge: some View {
        let icon: String
        let text: String
        let color: Color
        if katahub.isUploading {
            icon = "icloud.and.arrow.up"
            text = "katahub…"
            color = .blue
        } else if let r = katahub.lastResult, r.contains("загружено") {
            icon = "checkmark.icloud"
            text = "katahub"
            color = .green
        } else if let r = katahub.lastResult, !r.isEmpty {
            // Прошлая загрузка упала — оранжевый несмотря на reachable.
            icon = "exclamationmark.icloud"
            text = "katahub"
            color = .orange
        } else if katahub.isReachable {
            // Сервер отвечает на /healthz, но ещё не было загрузок.
            icon = "checkmark.icloud"
            text = "katahub"
            color = .green
        } else {
            icon = "icloud.slash"
            text = "katahub"
            color = .secondary
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(color)
        .accessibilityLabel(katahub.lastResult ?? "katahub")
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
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.green)
                    .frame(width: 220, height: 220)
                    .shadow(radius: 8, y: 4)
                if recorder.isRecording && stopHoldProgress > 0 {
                    Circle()
                        .trim(from: 0, to: stopHoldProgress)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 220, height: 220)
                }
                Text(recorder.isRecording ? "Стоп" : "Старт")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
            .onTapGesture {
                if !recorder.isRecording {
                    recorder.start()
                }
            }
            .gesture(
                recorder.isRecording ?
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in startStopHold() }
                        .onEnded { _ in cancelStopHold() }
                    : nil
            )
            .accessibilityLabel(recorder.isRecording ? "Удерживайте, чтобы остановить запись" : "Начать запись")

            if recorder.isRecording {
                Text("Удерживайте 1 сек для остановки")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func startStopHold() {
        guard stopHoldTimer == nil else { return }
        let step = 0.05
        let total = 1.0
        stopHoldTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { timer in
            Task { @MainActor in
                stopHoldProgress = min(1.0, stopHoldProgress + step / total)
                if stopHoldProgress >= 1.0 {
                    timer.invalidate()
                    stopHoldTimer = nil
                    stopHoldProgress = 0
                    recorder.stop()
                    sessionsStore.reload()
                }
            }
        }
    }

    private func cancelStopHold() {
        stopHoldTimer?.invalidate()
        stopHoldTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            stopHoldProgress = 0
        }
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
