import CoreLocation
import Foundation

/// Answers one question: is this Mac at home right now?
///
/// It exists so the hotspot fallback stands down in the one place where a better
/// network is always available and the phone's data plan should not be spent.
/// At home the rule is manual: `tzutze` is preferred and nothing should reach for
/// the phone on its own.
///
/// **A Mac has no GPS** — no model ever has. CoreLocation positions it by the
/// Wi-Fi networks it can see, matched against Apple's database, so accuracy is
/// tens of metres in a city and the fix is unavailable in a place with no known
/// networks around. That is fine for this question, whose answer only has to be
/// right to within a building, but it is why the radius is generous and why an
/// unavailable fix is treated as "not home": failing to suppress the fallback
/// costs a needless hotspot, while wrongly suppressing it strands the Mac
/// offline, and only one of those is recoverable by waiting.
///
/// Home is read from `~/.training-assistants-secrets.env` (`HOME_LAT`,
/// `HOME_LON`, optional `HOME_RADIUS_M`) rather than hardcoded, because this
/// repository is public and where somebody lives is not a build constant.
final class HomeGeofence: NSObject, CLLocationManagerDelegate {

    private static let defaultRadius: CLLocationDistance = 150

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var _last: CLLocation?
    private var _lastAt: Date?

    /// A fix older than this is not trusted to answer "am I home *now*".
    private static let freshness: TimeInterval = 15 * 60

    private let home: CLLocation?
    private let radius: CLLocationDistance

    override init() {
        let secrets = SecretsLoader.load()
        if let lat = Double(secrets["HOME_LAT"] ?? ""), let lon = Double(secrets["HOME_LON"] ?? "") {
            home = CLLocation(latitude: lat, longitude: lon)
        } else {
            home = nil
        }
        radius = Double(secrets["HOME_RADIUS_M"] ?? "") ?? Self.defaultRadius
        super.init()
        manager.delegate = self
        // Hundred-metre accuracy is both enough and cheaper: asking for best
        // accuracy turns on more radios for an answer that would not change.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        // Significant-change monitoring rather than continuous updates: this is
        // asked a handful of times a day, at wake and on network changes, and a
        // laptop that has not moved does not need a stream of fixes.
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
        if home == nil {
            overlayInfo("🏠 No HOME_LAT/HOME_LON in secrets — the geofence is off, the fallback runs everywhere")
        } else {
            overlayInfo("🏠 Home geofence armed (radius \(Int(radius))m)")
        }
    }

    /// True only when we have a recent fix *and* it is inside the radius.
    /// Everything else — no permission, no fix, a stale fix, no home configured
    /// — answers false, so an unanswerable question never strands the Mac
    /// offline.
    func isAtHome() -> Bool {
        guard let home else { return false }
        lock.lock(); let fix = _last; let at = _lastAt; lock.unlock()
        guard let fix, let at, Date().timeIntervalSince(at) < Self.freshness else {
            manager.requestLocation()   // ask now, for the next time we are asked
            return false
        }
        let d = fix.distance(from: home)
        return d <= radius
    }

    /// Logged so the coordinates can be read once and written into the secrets
    /// file; there is no UI for setting home, and inventing one for a value that
    /// changes when you move house would be the wrong trade.
    private func note(_ l: CLLocation) {
        let dist = home.map { String(format: "%.0fm from home", l.distance(from: $0)) } ?? "home not set"
        overlayInfo(String(format: "🏠 Location fix: HOME_LAT=%.6f HOME_LON=%.6f (±%.0fm, %@)",
                           l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy, dist))
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        lock.lock(); _last = l; _lastAt = Date(); lock.unlock()
        note(l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        overlayInfo("🏠 Location unavailable (\(error.localizedDescription)) — treating as not-home")
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .denied, .restricted:
            overlayInfo("🏠 Location denied — the geofence cannot suppress the fallback at home")
        case .notDetermined:
            break
        default:
            m.requestLocation()
        }
    }
}
