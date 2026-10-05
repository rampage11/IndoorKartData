import Foundation
import Combine

// Собирает события от TimingClient во время записи сессии и пишет
// их в timing.json внутри директории сессии. Эти события — ground truth
// для post-session анализа: по wallTime можно привязать timestamps IMU
// к реальным кругам RaceMann.
@MainActor
final class TimingRecorder {
    struct FlagChange: Codable {
        let wallTime: Date
        let raceTimeMs: Int
        let flag: String
    }

    struct LapRecord: Codable {
        let wallTime: Date
        let raceTimeMs: Int
        let lapNumber: Int
        let lapMs: Int
        let bestLapMs: Int
        let position: Int
        let gapToLeaderMs: Int?
        // Дельта до карта позади нас на отсечке. nil если никого нет (мы последние)
        // или если преследователь ещё не пересёк финиш к моменту этого круга.
        let chaserGapMs: Int?
    }

    struct Artifact: Codable {
        let raceID: String?
        let kartNumber: String?
        let laps: [LapRecord]
        let flags: [FlagChange]
    }

    private var laps: [LapRecord] = []
    private var flags: [FlagChange] = []
    private var lastFlag: String?
    private var lastSeenLapCount: Int = 0

    private var lapObserver: AnyCancellable?
    private var flagObserver: AnyCancellable?
    private var chaserObserver: AnyCancellable?

    private var sessionURL: URL?

    func start(sessionURL: URL) {
        self.sessionURL = sessionURL
        laps.removeAll()
        flags.removeAll()
        lastFlag = nil
        lastSeenLapCount = 0

        let timing = TimingClient.shared

        // Полный поток lap-ивентов от клиента (он дедуплицирует внутри).
        lapObserver = timing.$lapHistory
            .sink { [weak self] history in
                guard let self else { return }
                guard history.count > self.laps.count else { return }
                let fresh = history.suffix(from: self.laps.count)
                for ev in fresh {
                    self.laps.append(LapRecord(
                        wallTime: ev.wallTime,
                        raceTimeMs: ev.raceTimeMs,
                        lapNumber: ev.lapNumber,
                        lapMs: ev.lapMs,
                        bestLapMs: ev.bestLapMs,
                        position: ev.position,
                        gapToLeaderMs: timing.gapToLeaderMs,
                        chaserGapMs: nil   // проставим позже, когда преследователь пересечёт отсечку
                    ))
                }
            }

        // Дельта до преследователя прилетает через несколько секунд ПОСЛЕ
        // нашего круга — находим последнюю lap-запись и дописываем её.
        chaserObserver = timing.$chaserGapMs
            .compactMap { $0 }
            .sink { [weak self] gap in
                guard let self, var last = self.laps.last else { return }
                if last.chaserGapMs == nil {
                    last = LapRecord(
                        wallTime: last.wallTime,
                        raceTimeMs: last.raceTimeMs,
                        lapNumber: last.lapNumber,
                        lapMs: last.lapMs,
                        bestLapMs: last.bestLapMs,
                        position: last.position,
                        gapToLeaderMs: last.gapToLeaderMs,
                        chaserGapMs: gap
                    )
                    self.laps[self.laps.count - 1] = last
                }
            }

        // Флаг — наблюдаем смены "Green"/"Yellow"/"Red" и т.д.
        flagObserver = timing.$currentFlag
            .sink { [weak self] newFlag in
                guard let self, let newFlag else { return }
                if newFlag != self.lastFlag {
                    self.lastFlag = newFlag
                    self.flags.append(FlagChange(
                        wallTime: Date(),
                        raceTimeMs: timing.timeToGoMs ?? 0,
                        flag: newFlag
                    ))
                }
            }
    }

    /// Пишет артефакт в session dir, возвращает true если файл создан.
    @discardableResult
    func finalize() -> Bool {
        lapObserver?.cancel()
        flagObserver?.cancel()
        chaserObserver?.cancel()
        lapObserver = nil
        flagObserver = nil
        chaserObserver = nil

        guard let sessionURL else { return false }
        // Ничего не писали, не плодим пустые файлы.
        if laps.isEmpty, flags.isEmpty { return false }

        let timing = TimingClient.shared
        let artifact = Artifact(
            raceID: timing.currentRaceID,
            kartNumber: timing.kartNumber,
            laps: laps,
            flags: flags
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(artifact)
            let url = sessionURL.appendingPathComponent("timing.json")
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    var hasData: Bool {
        !(laps.isEmpty && flags.isEmpty)
    }
}
