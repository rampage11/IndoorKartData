import Foundation
import Combine

/// Публичный интерфейс управления записью сессии с iPhone.
/// Stub-реализация — заменяется Agent A при добавлении CoreMotion + аудио.
/// Контракт: @Published-поля ниже стабильны, UI на них опирается.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var currentSessionID: UUID?
    @Published var lastError: String?

    private var timer: Timer?
    private var startedAt: Date?

    func start() {
        guard !isRecording else { return }
        let id = UUID()
        currentSessionID = id
        startedAt = Date()
        isRecording = true
        elapsedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        startedAt = nil
    }
}
