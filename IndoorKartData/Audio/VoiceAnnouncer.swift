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

    func announceChaser(gapMs: Int) {
        let utterance = AVSpeechUtterance(string: Self.chaserPhrase(for: gapMs))
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        synth.speak(utterance)
    }

    func stopAll() {
        synth.stopSpeaking(at: .immediate)
    }

    static func phrase(for ms: Int) -> String {
        let totalMs = max(0, ms)
        // Обрезаем до десятых (не округляем): 42,150 → 42,1; 42,999 → 42,9.
        let seconds = totalMs / 1000
        let tenths = (totalMs % 1000) / 100
        return "\(seconds) и \(tenths)"
    }

    static func chaserPhrase(for gapMs: Int) -> String {
        let gap = max(0, gapMs)
        let seconds = gap / 1000
        let tenths = (gap % 1000) / 100
        // "плюс 0 и 8" → "плюс ноль и восемь" (TTS корректно читает).
        return "плюс \(seconds) и \(tenths)"
    }
}
