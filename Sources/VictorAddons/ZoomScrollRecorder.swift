import CoreGraphics
import Foundation

/// 🔍 Records a **physical** ⌥+scroll into the macOS magnifier, so `ShareZoom`'s dial
/// can be fitted to the native one (2026-10-30, *"al nostru vrea să fie cât mai aproape
/// de comportamentul ăluia"*). The magnifier ignores synthetic scrolls, so only a hand
/// can produce the curve; this writes down what that hand sent and where the magnifier
/// went.
///
/// While recording, every ⌥+scroll the HID tap sees is logged with its raw fields, and
/// `closeViewZoomFactor` is sampled at 60 Hz. `stop` writes both to
/// `~/.victor-addons/zoom-record-<time>.json` and answers the path.
/// Driven through `/test/zoom-input?do=record-start|record-stop`.
final class ZoomScrollRecorder {
    static let shared = ZoomScrollRecorder()

    private let lock = NSLock()
    private var recording = false
    private var startedAt: CFAbsoluteTime = 0
    private var events: [[String: Any]] = []
    private var factors: [[String: Double]] = []
    private var timer: DispatchSourceTimer?

    /// Tap thread. Cheap when not recording: one lock, one bool.
    func record(_ event: CGEvent) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        events.append([
            "t": CFAbsoluteTimeGetCurrent() - startedAt,
            "cont": event.getIntegerValueField(.scrollWheelEventIsContinuous),
            "d1": event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            "pd1": event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            "fd1": event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            "phase": event.getIntegerValueField(.scrollWheelEventScrollPhase),
            "momentum": event.getIntegerValueField(.scrollWheelEventMomentumPhase),
        ])
    }

    func start() -> String {
        lock.lock()
        recording = true
        startedAt = CFAbsoluteTimeGetCurrent()
        events = []
        factors = []
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in self?.sampleFactor() }
        t.resume()
        timer = t
        return "{\"recording\":true}"
    }

    func stop() -> String {
        timer?.cancel()
        timer = nil
        lock.lock()
        recording = false
        let dump: [String: Any] = ["events": events, "factors": factors]
        let counts = (events.count, factors.count)
        lock.unlock()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".victor-addons")
        let url = dir.appendingPathComponent("zoom-record-\(Int(Date().timeIntervalSince1970)).json")
        if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
        return "{\"path\":\"\(url.path)\",\"events\":\(counts.0),\"factorSamples\":\(counts.1)}"
    }

    /// Only the changes are kept: 60 Hz of a factor that sits still is noise.
    private func sampleFactor() {
        let domain = "com.apple.universalaccess" as CFString
        CFPreferencesAppSynchronize(domain)
        let f = (CFPreferencesCopyAppValue("closeViewZoomFactor" as CFString, domain) as? Double) ?? 1
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        if factors.last?["f"] != f {
            factors.append(["t": CFAbsoluteTimeGetCurrent() - startedAt, "f": f])
        }
    }
}
