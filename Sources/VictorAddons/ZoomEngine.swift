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

    /// Hand ⌥+scroll to this engine: the macOS magnifier's "Use scroll gesture with
    /// modifier keys to zoom" is on for `system` and **off for `share`**. Swallowing
    /// the event in our HID tap was not enough: a physical ⌥+scroll never reached
    /// either of our taps on 2026-10-27 (traced) — the magnifier takes it below
    /// every event tap, and only posted test events ever got through. Turning its
    /// scroll gesture off is the one way to leave the wheel to us.
    /// `UAScrollZoomSetEnabled` (private, `UniversalAccessCore`) is what System
    /// Settings calls. Main thread.
    func applyToScrollGesture() {
        guard let set = Self.scrollZoomSetEnabled, let get = Self.scrollZoomIsEnabled else {
            overlayError("🔍/🔎 UAScrollZoomSetEnabled not found — the magnifier keeps ⌥+scroll")
            return
        }
        let want = self == .system
        if get() != want { set(want) }
        overlayInfo("🔍/🔎 macOS scroll-gesture zoom \(want ? "on" : "off") for \(rawValue) → reads \(get() ? "on" : "off")")
    }

    private static let universalAccessCore = dlopen(
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/Frameworks/UniversalAccessCore.framework/UniversalAccessCore",
        RTLD_NOW)
    private static let scrollZoomSetEnabled = dlsym(universalAccessCore, "UAScrollZoomSetEnabled")
        .map { unsafeBitCast($0, to: (@convention(c) (Bool) -> Void).self) }
    private static let scrollZoomIsEnabled = dlsym(universalAccessCore, "UAScrollZoomIsEnabled")
        .map { unsafeBitCast($0, to: (@convention(c) () -> Bool).self) }

    /// The pill shown beside the cursor when the engine flips.
    var announcement: String {
        switch self {
        case .system: return "🔍 ⌥↕ = macOS zoom"
        case .share: return "🔎 ⌥↕ = Share Zoom"
        }
    }
}
