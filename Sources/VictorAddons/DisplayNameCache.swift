import Cocoa
import CoreGraphics

/// Remembers each physical display's `localizedName` so a display can still be
/// identified while it is a **mirror slave** — mirrored displays collapse into a
/// single `NSScreen`, so the slave has no name at all (see `DisplayRolePolicy`).
///
/// Keyed by the EDID triple Quartz exposes for *any online* display, mirrored or
/// not. Two identical monitors collide on that key, which is harmless: they also
/// share the name, and roles are matched by name substring anyway.
///
/// Persisted in `UserDefaults`, so the very first evaluation after an app
/// restart — the exact moment the app has no `NSScreen` history to lean on —
/// already knows which anonymous display is the ASUS.
enum DisplayNameCache {
    private static let defaultsKey = "DisplayNameCache.v1"

    /// `nil` when the EDID triple carries no usable identity — better no cache
    /// entry at all than two different monitors colliding on "unknown-unknown"
    /// and lending each other a name.
    static func key(for id: CGDirectDisplayID) -> String? {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        func unusable(_ v: UInt32) -> Bool { v == 0 || v == 0xFFFF_FFFF }
        if unusable(vendor) && unusable(model) { return nil }
        return "\(vendor)-\(model)-\(serial)"
    }

    /// Record every display that currently *does* have an `NSScreen`.
    static func learn() {
        var map = stored()
        var changed = false
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(n.uint32Value)
            guard CGDisplayIsBuiltin(id) == 0 else { continue }
            guard let k = key(for: id) else { continue }
            if map[k] != screen.localizedName {
                map[k] = screen.localizedName
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(map, forKey: defaultsKey) }
    }

    /// The remembered name for a display that has no `NSScreen` right now.
    static func name(for id: CGDirectDisplayID) -> String? {
        guard let k = key(for: id) else { return nil }
        return stored()[k]
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
