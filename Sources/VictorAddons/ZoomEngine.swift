import Foundation

/// 🔍/🔎 Which zoom ⌥+scroll drives — one or the other, never both (Victor,
/// 2026-10-26: *"n-are sens vreodată să fac zoom și de un fel, și de altul"*).
///
/// - `system`: the macOS magnifier, applied at scanout — Victor sees it, a share
///   never does. ⌥+scroll is left alone and reaches `AXVisualSupportAgent`.
/// - `share`: our `ShareZoom`, drawn in a window, which every share carries. The
///   ⌥+scroll HID tap swallows the event before the magnifier's tap sees it.
///
/// A short tap of ⌥⇧ (`OptionShiftTap`) flips it; the choice survives restarts.
/// ⌥⇧+scroll, the gesture `ShareZoom` had until then, does nothing any more.
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

/// ⌥⇧ pressed and let go — both keys, nothing else, quickly — the `ZoomEngine` flip.
///
/// Order-free (⌥ then ⇧ or ⇧ then ⌥, either side). The whole gesture, from the
/// first of the two going down to the last coming up, has to fit in `maxDuration`:
/// longer is a hold, and holding ⌥⇧ is the emoji cheat-sheet's gesture
/// (`KeymapOverlay`, 0.3 s). ⌘ or ⌃ joining in, a key typed, a scroll or a mouse
/// button in between — any of those spoils it, so ⌥⇧-typing a character never flips.
struct OptionShiftTap {
    static let maxDuration: TimeInterval = 0.45

    private var startedAt: TimeInterval?
    private var bothDown = false
    private var spoiled = false

    /// Feed every flagsChanged event; true when it completes a tap.
    mutating func flagsChanged(option: Bool, shift: Bool, command: Bool, control: Bool,
                               at time: TimeInterval) -> Bool {
        if !option && !shift {
            defer { reset() }
            guard let start = startedAt, bothDown, !spoiled, !command, !control else { return false }
            return time - start <= Self.maxDuration
        }
        if startedAt == nil {
            startedAt = time
            bothDown = false
            spoiled = false
        }
        if command || control { spoiled = true }
        if option && shift { bothDown = true }
        return false
    }

    /// A key, a scroll or a mouse button while ⌥/⇧ were down: not a tap.
    mutating func interrupt() {
        if startedAt != nil { spoiled = true }
    }

    private mutating func reset() {
        startedAt = nil
        bothDown = false
        spoiled = false
    }
}
