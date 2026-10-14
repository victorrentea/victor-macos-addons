import CoreLocation
import CoreWLAN
import Foundation

/// The pure half of "is this Mac on roaming data right now?".
///
/// Asked for 14 Oct 2026, together with a switch that pauses every Claude Code
/// session while the answer is yes (`~/.claude/hooks/roaming-gate.sh`, the same
/// parking trick as `net-gate.sh` and `quota-gate.sh`).
///
/// "Roaming data" = the Mac is on the phone's hotspot **and** the phone is
/// roaming. The first half is certain (the SSID). The second is the phone's
/// to say, and the phone has gone silent before (`docs/roaming-warning.md`:
/// 60 polls, zero readings on 13 Oct), so the evidence is ranked:
///
///  1. a fresh phone reading — `roamingNow`, the network's own flag;
///  2. else the country of the Mac's last location fix, reverse-geocoded;
///  3. else the system timezone, which macOS moves with the location. It is
///     blind to Bulgaria and Greece (same zone as Bucharest), so it comes last.
enum RoamingDataPolicy {
    static let homeCountry = "RO"
    static let homeTimeZone = "Europe/Bucharest"
    static let phoneFreshFor: TimeInterval = 30 * 60
    static let countryFreshFor: TimeInterval = 6 * 3600

    enum Source: String { case notOnHotspot = "not-on-hotspot", phone, location, timezone }

    struct Verdict: Equatable {
        let roamingData: Bool
        let source: Source
    }

    static func decide(onHotspot: Bool,
                       phoneRoamingNow: Bool?, phoneReadAt: Date?,
                       country: String?, countryAt: Date?,
                       timeZone: String, now: Date) -> Verdict {
        guard onHotspot else { return Verdict(roamingData: false, source: .notOnHotspot) }
        if let roaming = phoneRoamingNow, let at = phoneReadAt, now.timeIntervalSince(at) < phoneFreshFor {
            return Verdict(roamingData: roaming, source: .phone)
        }
        if let c = country, let at = countryAt, now.timeIntervalSince(at) < countryFreshFor {
            return Verdict(roamingData: c.uppercased() != homeCountry, source: .location)
        }
        return Verdict(roamingData: timeZone != homeTimeZone, source: .timezone)
    }

    /// The line the hooks read. `updatedAt` is a heartbeat: a file the app
    /// stopped refreshing (app quit, crashed) must not park anything.
    static func json(_ v: Verdict, onHotspot: Bool, suspendClaude: Bool, country: String?, now: Date) -> String {
        var o: [String: Any] = [
            "roamingData": v.roamingData,
            "onHotspot": onHotspot,
            "source": v.source.rawValue,
            "suspendClaude": suspendClaude,
            "updatedAt": Int(now.timeIntervalSince1970),
        ]
        if let country { o["country"] = country }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The menu switch: ⏸ Claude on roaming data. Default on — the allowance this
/// guards was emptied once already.
enum RoamingDataSettings {
    static let suspendKey = "RoamingData.suspendClaude"
    static var suspendClaude: Bool {
        get { UserDefaults.standard.object(forKey: suspendKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: suspendKey) }
    }
}

/// Keeps `~/.victor-addons/roaming-data.json` true every few seconds, for
/// `roaming-gate.sh` (and anything else that wants to know).
final class RoamingDataWatch {
    static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".victor-addons/roaming-data.json")
    private static let every: TimeInterval = 5

    private let phone: PhoneRoamingMonitor
    private let location: () -> (CLLocation, Date)?
    private let geocoder = CLGeocoder()
    private var country: String?
    private var countryAt: Date?
    private var countryFor: CLLocation?
    private var last: RoamingDataPolicy.Verdict?
    private var timer: Timer?

    /// Fired on the main thread when the verdict flips.
    var onChange: ((RoamingDataPolicy.Verdict) -> Void)?
    private(set) var verdict = RoamingDataPolicy.Verdict(roamingData: false, source: .notOnHotspot)

    init(phone: PhoneRoamingMonitor, location: @escaping () -> (CLLocation, Date)?) {
        self.phone = phone
        self.location = location
    }

    func start() {
        try? FileManager.default.createDirectory(
            atPath: (Self.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    /// After the menu switch flips: write now, so a parked turn wakes within one poll.
    func refresh() { tick() }

    private func tick() {
        let now = Date()
        let onHotspot = CWWiFiClient.shared().interface(withName: "en0")?.ssid() == "victor"
        if onHotspot { geocodeIfNeeded(now: now) }
        let r = phone.reading
        let v = RoamingDataPolicy.decide(
            onHotspot: onHotspot, phoneRoamingNow: r?.roamingNow, phoneReadAt: r?.readAt,
            country: country, countryAt: countryAt, timeZone: TimeZone.current.identifier, now: now)
        verdict = v
        let line = RoamingDataPolicy.json(v, onHotspot: onHotspot,
                                          suspendClaude: RoamingDataSettings.suspendClaude,
                                          country: country, now: now)
        try? (line + "\n").write(toFile: Self.path, atomically: true, encoding: .utf8)
        if v != last {
            last = v
            overlayInfo("📵 roaming data: \(v.roamingData ? "YES" : "no") (\(v.source.rawValue)" +
                        "\(country.map { ", \($0)" } ?? ""))\(v.roamingData && RoamingDataSettings.suspendClaude ? " — Claude paused" : "")")
            onChange?(v)
        }
    }

    /// One reverse lookup per place: again only after moving 20 km, or hourly.
    private func geocodeIfNeeded(now: Date) {
        guard let (fix, _) = location(), !geocoder.isGeocoding else { return }
        if let prev = countryFor, let at = countryAt,
           fix.distance(from: prev) < 20_000, now.timeIntervalSince(at) < 3600 { return }
        geocoder.reverseGeocodeLocation(fix) { [weak self] marks, _ in
            guard let self, let code = marks?.first?.isoCountryCode else { return }
            DispatchQueue.main.async {
                self.country = code
                self.countryAt = Date()
                self.countryFor = fix
            }
        }
    }
}
