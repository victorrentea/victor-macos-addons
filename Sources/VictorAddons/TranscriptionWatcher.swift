import Foundation

/// Watches the daily transcription file every 10 seconds.
/// Fires onStaleChanged(true) when nothing has been written for > `staleThreshold`
/// (default 180 s = 3 min). Staleness is measured from `max(fileMtime, watchStart)`,
/// so every Whisper (re)start gets a fresh warm-up window: a pre-existing daily
/// file from earlier today (mid-day restart) does not read as instantly stale
/// before Whisper has loaded its model and written its first line.
class TranscriptionWatcher {
    var onStaleChanged: ((Bool) -> Void)?

    private let transcriptionFolder: URL
    private let staleThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private var timer: Timer?
    private var transcriptionStartTime: Date?
    private var lastIsStale: Bool = false

    init(transcriptionFolder: URL,
         staleThreshold: TimeInterval = 180,
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

    /// Pure staleness decision. `mtime` = the transcript file's modification date
    /// (nil if it doesn't exist yet); `start` = when this watch began, i.e. when
    /// Whisper (re)started. We only trust `mtime` once it's newer than `start` —
    /// meaning a line was written *since* this Whisper start. A pre-existing daily
    /// file from earlier today has an OLD mtime and would otherwise read as
    /// instantly stale on a mid-day restart, before Whisper finished warming up.
    /// Until a fresh line lands, staleness is measured from `start`, giving each
    /// (re)start a full `threshold` warm-up window.
    static func isStale(mtime: Date?, start: Date, now: Date, threshold: TimeInterval) -> Bool {
        let lastActivity = max(mtime ?? .distantPast, start)
        return now.timeIntervalSince(lastActivity) > threshold
    }

    private func check() {
        let todayFile = transcriptionFolder.appendingPathComponent(todayFilename())
        let start = transcriptionStartTime ?? Date()
        let isStale = Self.isStale(mtime: modificationDate(of: todayFile),
                                   start: start, now: Date(), threshold: staleThreshold)

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
