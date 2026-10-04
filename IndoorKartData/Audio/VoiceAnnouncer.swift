import Foundation
import AVFoundation

// Проговаривает времена кругов через встроенный TTS. Используется параллельно
// с AVAudioEngine записью микрофона — AVAudioSession у нас в .playAndRecord
// с .mixWithOthers, конфликта быть не должно.
final class VoiceAnnouncer {
    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init() {
        self.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            ?? AVSpeechSynthesisVoice(language: "ru")
    }

    func announceLap(ms: Int) {
        let utterance = AVSpeechUtterance(string: Self.phrase(for: ms))
        utterance.voice = voice
        // Чуть медленнее дефолта — чтобы разборчиво в шлеме с наушниками.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        synth.speak(utterance)
    }

    func stopAll() {
        synth.stopSpeaking(at: .immediate)
    }

    static func phrase(for ms: Int) -> String {
        let totalMs = max(0, ms)
        // Округляем до десятых: 42,150 → 42,2; 42,999 → 43,0.
        let tenthsTotal = Int((Double(totalMs) / 100.0).rounded())
        let seconds = tenthsTotal / 10
        let tenths = tenthsTotal % 10
        // "33 и 1" — TTS прочитает как "тридцать три и один" (короче и в шлеме разборчивее).
        return "\(seconds) и \(tenths)"
    }
}
