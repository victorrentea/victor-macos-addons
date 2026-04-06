import Foundation

/// Watches the daily transcription file every 10 seconds.
/// Fires onStaleChanged(true) when nothing has been written for > 10 minutes.
class TranscriptionWatcher {
    var onStaleChanged: ((Bool) -> Void)?

    private let transcriptionFolder: URL
    private let staleThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private var timer: Timer?
    private var transcriptionStartTime: Date?
    private var lastIsStale: Bool = false

    init(transcriptionFolder: URL,
         staleThreshold: TimeInterval = 600,
         checkInterval: TimeInterval = 10) {
        self.transcriptionFolder = transcriptionFolder
        self.staleThreshold = staleThreshold
        self.checkInterval = checkInterval
    }

    func startWatching() {
        transcriptionStartTime = Date()
        lastIsStale = false
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        transcriptionStartTime = nil
        if lastIsStale {
            lastIsStale = false
            onStaleChanged?(false)
        }
    }

    private func check() {
        let todayFile = transcriptionFolder.appendingPathComponent(todayFilename())
        let lastActivity = modificationDate(of: todayFile) ?? transcriptionStartTime ?? Date()
        let isStale = Date().timeIntervalSince(lastActivity) > staleThreshold

        if isStale != lastIsStale {
            lastIsStale = isStale
            DispatchQueue.main.async { self.onStaleChanged?(isStale) }
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func todayFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: Date()))-transcription.txt"
    }
}
