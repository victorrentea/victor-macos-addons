import Cocoa
import CoreGraphics

/// The set of external displays Victor considers "mine / not presenting".
///
/// Two kinds of match, OR'd:
///  - **Name rules** — a case-insensitive substring of the display's
///    `localizedName`. Seeded with "ASUS" so the ASUS MB166C travel monitor is
///    always trusted (across any ASUS unit), even before it's ever registered.
///  - **Hardware identities** — a `vendor:model:serial` key, added by
///    "Trust current external displays" when Victor is at home with his own
///    monitors / TV connected. Survives across sessions (UserDefaults).
///
/// A connected external display that matches neither is an **unknown external**
/// — a venue projector / room TV — which is exactly the "I'm presenting / sharing
/// my desktop" signal. The built-in Retina is never considered here.
final class KnownDisplays {
    private static let kIdentities = "KnownDisplays.identities"
    private static let kNameRules = "KnownDisplays.nameRules"
    private static let kNames = "KnownDisplays.names" // identity → last-seen name (UI only)

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seedIfNeeded()
    }

    private func seedIfNeeded() {
        if defaults.object(forKey: Self.kNameRules) == nil {
            defaults.set(["ASUS"], forKey: Self.kNameRules)
        }
    }

    // MARK: - Queries

    var nameRules: [String] { defaults.stringArray(forKey: Self.kNameRules) ?? [] }
    var identities: [String] { defaults.stringArray(forKey: Self.kIdentities) ?? [] }
    var names: [String: String] { (defaults.dictionary(forKey: Self.kNames) as? [String: String]) ?? [:] }

    /// True if this external display is one of Victor's own (name-rule or
    /// identity match). Callers only ask this about non-builtin displays.
    func isKnown(_ id: CGDirectDisplayID) -> Bool {
        if let name = Self.name(for: id) {
            let upper = name.uppercased()
            if nameRules.contains(where: { upper.contains($0.uppercased()) }) { return true }
        }
        return identities.contains(Self.identityKey(id))
    }

    // MARK: - Mutation

    /// Add every currently-connected external (non-builtin) display to the known
    /// set by hardware identity. Returns the human names added/refreshed.
    @discardableResult
    func trustCurrentExternals() -> [String] {
        var ids = Set(identities)
        var nameMap = names
        var added: [String] = []
        for id in Self.onlineDisplayIDs() where CGDisplayIsBuiltin(id) == 0 {
            let key = Self.identityKey(id)
            let name = Self.name(for: id) ?? "display \(id)"
            ids.insert(key)
            nameMap[key] = name
            added.append(name)
        }
        defaults.set(Array(ids), forKey: Self.kIdentities)
        defaults.set(nameMap, forKey: Self.kNames)
        overlayInfo("KnownDisplays: trusted current externals → \(added)")
        return added
    }

    /// Wipe every trusted hardware identity (keeps the seeded name rules, so the
    /// ASUS stays trusted). For a "start over" from the test hook.
    func clearIdentities() {
        defaults.removeObject(forKey: Self.kIdentities)
        defaults.removeObject(forKey: Self.kNames)
        overlayInfo("KnownDisplays: cleared trusted identities")
    }

    // MARK: - Static CG helpers

    static func identityKey(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }

    static func name(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
