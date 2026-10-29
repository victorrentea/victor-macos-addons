import Foundation

/// 🔋 The phone's charge for the tablet's top bar, which shows it instead of the
/// tablet's own (Victor, 2026-10-29: "the tablet's battery is stupid").
///
/// Not from Soduto: `PhoneBatteryMonitor` only ever learns about a *low* phone.
/// The number comes from **Victor Net** (`GET /phone/battery`), which keeps it from
/// the phone's `/status` answers it already gets — every 5 s on the hotspot, every
/// 20 min over Bluetooth elsewhere — so it carries its age, and the tablet dims an
/// old one.
///
/// Read in the background every `pollInterval` and cached, because `/ping` asks
/// for its extras on the main thread. A cross-app call owes three things: a config
/// key (`VICTOR_NET_URL` / `VictorNet.baseURL`), a timeout, and a visible degraded
/// state — Victor Net down or the phone never heard from is `pct -1`, and the
/// tablet then shows no number at all rather than a stale one.
final class PhoneCharge {

    struct Reading: Equatable {
        let pct: Int
        let charging: Bool
        /// Victor Net's age of the reading, at `fetchedAt`.
        let ageS: Int
        let fetchedAt: Date
    }

    static let pollInterval: TimeInterval = 15
    private static let timeout: TimeInterval = 1

    static var baseURL: String {
        let env = ProcessInfo.processInfo.environment["VICTOR_NET_URL"] ?? ""
        if !env.isEmpty { return env }
        if let stored = UserDefaults.standard.string(forKey: "VictorNet.baseURL"), !stored.isEmpty {
            return stored
        }
        return "http://127.0.0.1:55126"
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
    private let lock = NSLock()
    private var _reading: Reading?
    private var timer: DispatchSourceTimer?

    var reading: Reading? {
        lock.lock(); defer { lock.unlock() }
        return _reading
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let url = URL(string: Self.baseURL + "/phone/battery") else { return }
        session.dataTask(with: url) { [weak self] data, _, error in
            let reading = (error == nil ? data : nil).flatMap { Self.parse($0, now: Date()) }
            guard let self else { return }
            self.lock.lock(); self._reading = reading; self.lock.unlock()
        }.resume()
    }

    /// `{"pct":63,"charging":false,"age_s":120}`; `{"pct":-1}` (phone not heard from) is nil.
    static func parse(_ data: Data, now: Date) -> Reading? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pct = (o["pct"] as? NSNumber)?.intValue, (0...100).contains(pct) else { return nil }
        return Reading(pct: pct, charging: (o["charging"] as? NSNumber)?.boolValue ?? false,
                       ageS: (o["age_s"] as? NSNumber)?.intValue ?? 0, fetchedAt: now)
    }

    /// The `/ping` fragment (leading comma, only ints and a bool): `phoneChargePct`
    /// −1 = show nothing; `phoneChargeAgeS` lets the tablet dim an old reading.
    static func pingFields(_ r: Reading?, now: Date) -> String {
        guard let r else { return ",\"phoneChargePct\":-1" }
        let age = r.ageS + max(0, Int(now.timeIntervalSince(r.fetchedAt)))
        return ",\"phoneChargePct\":\(r.pct),\"phoneCharging\":\(r.charging),\"phoneChargeAgeS\":\(age)"
    }
}
