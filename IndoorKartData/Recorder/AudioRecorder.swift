import Foundation
import AVFoundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "com.indoorkartdata.audio.write", qos: .utility)

    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var running: Bool = false
    private var frameCount: AVAudioFramePosition = 0

    var isRunning: Bool { running }
    var sampleRateHz: Double { 44_100.0 }
    var currentFrameCount: Int { Int(frameCount) }

    enum AudioError: Error {
        case permissionDenied
        case formatUnavailable
        case fileCreationFailed
        case engineStartFailed
    }

    static func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted {
            return true
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(fileURL: URL) throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.formatUnavailable
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100.0,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioError.formatUnavailable
        }
        self.targetFormat = target

        // Settings для AVAudioFile — WAV с PCM Int16 44.1k mono.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let file = try? AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        ) else {
            throw AudioError.fileCreationFailed
        }
        self.audioFile = file

        self.converter = AVAudioConverter(from: inputFormat, to: target)
        self.frameCount = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.audioFile = nil
            throw AudioError.engineStartFailed
        }
        running = true
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let target = targetFormat else { return }

        // Оценка выходного capacity: пропорция sample rate c запасом.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil, outBuffer.frameLength > 0 else { return }

        let bufferToWrite = outBuffer
        writeQueue.async { [weak self] in
            guard let self, let file = self.audioFile else { return }
            do {
                try file.write(from: bufferToWrite)
                self.frameCount &+= AVAudioFramePosition(bufferToWrite.frameLength)
            } catch {
                // См. комментарий в IMU — не рушим поток из-за единичного сбоя.
            }
        }
    }

    func stop(completion: @escaping (Int) -> Void) {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
        writeQueue.async { [weak self] in
            guard let self else {
                completion(0)
                return
            }
            // Закрытие AVAudioFile происходит при освобождении; явно обнуляем, затем деактивируем сессию.
            self.audioFile = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            completion(Int(self.frameCount))
        }
    }
}
