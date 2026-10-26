import Foundation

/// 🔍/🔎 Which zoom ⌥+scroll drives — one or the other, never both (Victor,
/// 2026-10-26: *"n-are sens vreodată să fac zoom și de un fel, și de altul"*).
///
/// - `system`: the macOS magnifier, applied at scanout — Victor sees it, a share
///   never does. ⌥+scroll is left alone and reaches `AXVisualSupportAgent`.
/// - `share`: our `ShareZoom`, drawn in a window, which every share carries. The
///   ⌥+scroll HID tap swallows the event before the magnifier's tap sees it.
///
/// ⌥ + wheel click flips it (a quick ⌥⇧ tap did first and fired by itself while
/// typing; ⌃⌥F1 and ⌥F1 followed, the same evening); the choice survives restarts. ⌥⇧+scroll, the gesture `ShareZoom`
/// had until then, does nothing any more.
enum ZoomEngine: String {
    case system, share

    static let defaultsKey = "ZoomEngine"

    static var current: ZoomEngine {
        get { ZoomEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var toggled: ZoomEngine { self == .system ? .share : .system }

    /// The pill shown beside the cursor when the engine flips.
    var announcement: String {
        switch self {
        case .system: return "🔍 ⌥↕ = macOS zoom"
        case .share: return "🔎 ⌥↕ = Share Zoom"
        }
    }
}
