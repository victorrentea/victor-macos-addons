import Cocoa
import CoreGraphics

/// The external displays Victor considers "mine / not presenting" — his own
/// monitors and TVs, as opposed to a venue projector / room TV.
///
/// **Hardcoded, explicit list** (matched by a case-insensitive *substring* of the
/// display's `localizedName`). To add or remove a trusted monitor, edit
/// `trustedNameSubstrings` below. There is no dynamic "remember this display"
/// mechanism — Victor names his monitors explicitly.
///
/// A connected external display whose name matches none of these is an **unknown
/// external** — a venue projector / room TV — which is the "I'm presenting /
/// sharing my desktop" signal (and the trigger for the projector mirror setup).
/// The built-in Retina is never considered here.
final class KnownDisplays {
    /// Victor's own displays, by name substring (case-insensitive `contains`).
    /// Keep substrings specific enough not to collide with a venue's gear.
    static let trustedNameSubstrings: [String] = [
        "ASUS",   // ASUS MB166C — travel monitor
        // Home monitors / TV go here once Victor names them, e.g.:
        // "DELL U2419H", "LG", "SAMSUNG",
    ]

    /// Names Victor trusts (for the snapshot / logging).
    var trustedNames: [String] { Self.trustedNameSubstrings }

    /// True if this external display is one of Victor's own (name-substring
    /// match). Callers only ask this about non-builtin displays.
    func isKnown(_ id: CGDirectDisplayID) -> Bool {
        guard let name = Self.name(for: id) else { return false }
        let upper = name.uppercased()
        return Self.trustedNameSubstrings.contains { upper.contains($0.uppercased()) }
    }

    // MARK: - Static CG helpers

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
