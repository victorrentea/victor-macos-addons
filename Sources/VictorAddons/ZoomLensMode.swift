import Foundation

/// 🔍 macOS's screen magnifier has three styles, and **which one is active decides
/// whether anyone on the other end of a Zoom share can see the magnification at all.**
/// That is the whole reason this exists.
///
/// Measured on 2026-09-22, on this Mac, against `screencapture`:
///
/// | style | where macOS applies it | in the captured frame? |
/// |---|---|---|
/// | Full screen | at **scanout**, after the composited frame every capture client reads | **no** |
/// | Picture-in-picture | an ordinary **composited window** | **yes** — unless the lens is sized to the whole screen, at which point it degenerates back into the full-screen path |
/// | Split screen | untested | unknown |
///
/// So the room, which watches the physical panel, sees every style; the remote
/// participants see only the picture-in-picture lens. Victor had been magnifying with
/// the full-screen style for years and nobody on Zoom ever saw it.
///
/// **⌥⌘F toggles Full screen ↔ PiP** (`AX_ZOOM_TOGGLE_FS_AND_PIP` in
/// `com.apple.universalaccess`'s hotkey table). The two styles are visually
/// *indistinguishable* when the lens covers the whole screen — same pixels, same
/// magnification, only a different place in the graphics pipeline — which is exactly
/// why pressing the key needs to say something out loud. Without a pill, the toggle is
/// a switch with no feedback that silently decides whether half the audience can read
/// the screen.
enum ZoomLensMode: Int {
    case fullScreen = 0
    case pictureInPicture = 1
    case splitScreen = 2

    /// The pill text. Short and mild on purpose: the retina is what's projected to the
    /// room, so this lands in front of an audience. It names the style rather than the
    /// consequence ("remote can't see this") for the same reason `SilentTranscription`'s
    /// warning is `😶😶😶` — a sentence about a broken share would alarm a room that
    /// has no idea anything is wrong.
    var pill: String {
        switch self {
        case .fullScreen:       return "🔍 Full screen"
        case .pictureInPicture: return "🔍 PiP"
        case .splitScreen:      return "🔍 Split"
        }
    }
}

/// When a mode change is worth a pill. Pure, so the rule is testable without a display,
/// a daemon or a keystroke.
enum ZoomLensModePolicy {

    /// `nil` = say nothing.
    ///
    /// Two silences matter. **The first reading is never announced**: the watcher's
    /// first tick happens at launch, and a pill then would fire on every restart,
    /// announcing something Victor did not just do. And a repeat of the same mode is
    /// not a change — the preference is re-read every second and must not chatter.
    static func announcement(previous: ZoomLensMode?, current: ZoomLensMode) -> String? {
        guard let previous else { return nil }
        guard previous != current else { return nil }
        return current.pill
    }

    /// What ⌘⌃U switches to. The board has three styles but the key is a
    /// **two-position switch**, because only two of them answer the question it is
    /// asked: "can the people on the call see this or not". Split screen is neither
    /// a yes nor a no, so it leaves by the same door as full screen — towards the
    /// one style that is known to be carried by a share.
    static func toggled(from current: ZoomLensMode) -> ZoomLensMode {
        current == .pictureInPicture ? .fullScreen : .pictureInPicture
    }
}

/// Watches the magnifier style and reports changes.
///
/// **Why it polls rather than intercepting ⌥⌘F.** The obvious design — a branch in
/// `EventTapManager` — cannot work: macOS's zoom consumes its own gestures *upstream of
/// every event tap*. Measured the same day: a `.cgSessionEventTap` saw the ⌥ modifier on
/// 1 of ~333 scroll events while the zoom factor climbed from 1.0 to 3.3, and a
/// `.cghidEventTap` saw it on 0 of 28. The keystroke is no different. Polling the
/// setting also catches the mode being changed from System Settings, which a key hook
/// never would.
///
/// The cost is one preference read per second. `UAZoomCurrentMode()` — the private call
/// the system itself uses — disassembles to exactly `UAPreferencesGetInteger` of this
/// same key, so reading the preference is not a workaround: it *is* the mechanism, minus
/// the private symbol.
final class ZoomLensWatch {

    private static let domain = "com.apple.universalaccess" as CFString
    private static let key = "closeViewZoomMode" as CFString

    /// Called on the main queue with the pill text, only when there is something to say.
    var onChange: ((String) -> Void)?

    private var timer: DispatchSourceTimer?
    private var previous: ZoomLensMode?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-lens-watch",
                                      qos: .utility)

    /// The live style. `nil` when the key has never been written — a Mac where the
    /// magnifier was never configured, which reads as "no opinion" rather than
    /// "full screen", so nothing is announced.
    static func current() -> ZoomLensMode? {
        CFPreferencesAppSynchronize(domain)
        guard let v = CFPreferencesCopyAppValue(key, domain) as? Int else { return nil }
        return ZoomLensMode(rawValue: v)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Flip the style and say so at once.
    ///
    /// The pill is emitted here rather than left to the next tick for the reason a
    /// shortcut exists at all: a key you press and then wait a second to see the
    /// result of is a key you press twice. `previous` is advanced in the same breath,
    /// so the watcher does not announce the same change a second time when it catches
    /// up.
    ///
    /// Writing the preference **is** the mechanism, not a nudge towards it: this is how
    /// the style was switched to picture-in-picture in the first place, and the small
    /// lens appeared on screen within the second. Apple's own ⌥⌘F
    /// (`AX_ZOOM_TOGGLE_FS_AND_PIP`) does the same thing, but only while a
    /// magnification is already on screen — which is exactly when you have least
    /// patience for a key that silently does nothing.
    @discardableResult
    func toggle() -> ZoomLensMode {
        let current = Self.current() ?? .fullScreen
        let next = ZoomLensModePolicy.toggled(from: current)
        CFPreferencesSetAppValue(Self.key, next.rawValue as CFNumber, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        queue.async { [weak self] in self?.previous = next }
        DispatchQueue.main.async { [weak self] in self?.onChange?(next.pill) }
        return next
    }

    private func tick() {
        guard let now = Self.current() else { return }
        let text = ZoomLensModePolicy.announcement(previous: previous, current: now)
        previous = now
        guard let text else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(text) }
    }

    deinit { timer?.cancel() }
}
