import AppKit
import CoreGraphics

/// Where an unattended Terminal window is allowed to appear.
///
/// The built-in Retina is what a venue projector mirrors, so a window that pops
/// up there lands on the wall in front of the room. Anything this app opens on
/// its own — the Flux email agent — therefore goes to an **external** screen,
/// and only falls back to macOS's default placement when the Retina is the only
/// screen there is.
///
/// The maths is pure so it can be unit-tested, and it has to be, because the two
/// coordinate systems disagree: AppleScript window `bounds` are
/// `{left, top, right, bottom}` in *Carbon* global coordinates — origin at the
/// **top**-left of the primary screen, y growing **downwards** — while
/// `NSScreen` frames are Cocoa coordinates with the origin at the **bottom**-left
/// of the primary screen. Hence the flip around the primary's `frame.maxY`.
enum TerminalWindowPlacement {

    /// One screen, reduced to what the placement maths needs.
    struct ScreenBox {
        /// Full frame in Cocoa coordinates — the primary's `maxY` is the flip axis.
        let frame: CGRect
        /// Frame minus menu bar / Dock: where a window may actually sit.
        let visibleFrame: CGRect
        let isBuiltin: Bool

        init(frame: CGRect, visibleFrame: CGRect, isBuiltin: Bool) {
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.isBuiltin = isBuiltin
        }
    }

    /// AppleScript's `bounds` 4-tuple.
    struct Bounds: Equatable {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int

        var appleScriptList: String { "{\(left), \(top), \(right), \(bottom)}" }
    }

    /// A window rect on the largest non-built-in screen, centred and covering
    /// `areaFraction` of its **area** (0.10 = a tenth of the monitor's surface,
    /// hence `sqrt` for the per-axis scale — 0.10 of the area is 0.32 of each
    /// side, not 0.10).
    ///
    /// Returns `nil` when there is no external screen to move to — the caller
    /// then leaves macOS's default placement alone. It never returns a rect on
    /// the built-in display: that is the whole point.
    static func bounds(screens: [ScreenBox], areaFraction: CGFloat = 0.10) -> Bounds? {
        guard !screens.isEmpty else { return nil }
        // The primary is the screen at the Cocoa origin (`NSScreen.screens[0]`
        // normally, but we do not depend on ordering — a filtered-out mirror
        // could have shifted it).
        let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens[0]
        guard let target = screens
            .filter({ !$0.isBuiltin })
            .max(by: { $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height })
        else { return nil }

        let vf = target.visibleFrame
        let linear = max(0.01, min(1.0, areaFraction)).squareRoot()
        // Never below a Terminal you can actually read, never past the screen.
        let w = min(vf.width, max((vf.width * linear).rounded(), 320))
        let h = min(vf.height, max((vf.height * linear).rounded(), 200))
        let x = (vf.minX + (vf.width - w) / 2).rounded()
        let y = (vf.minY + (vf.height - h) / 2).rounded()
        let flipTop = primary.frame.maxY

        // `Int(nonFinite)` traps and would take the whole app down (the same
        // trap that crashed the transcription heartbeat), and a degenerate
        // screen rect is not worth a window anyway.
        guard [w, h, x, y, flipTop].allSatisfy({ $0.isFinite }), w >= 120, h >= 80 else { return nil }

        return Bounds(left: Int(x),
                      top: Int(flipTop - (y + h)),
                      right: Int(x + w),
                      bottom: Int(flipTop - y))
    }

    /// Snapshot the live screens.
    ///
    /// Displays that **mirror** another one are dropped: a venue projector
    /// mirroring the Retina is not a second desk to put a window on, it is the
    /// Retina again.
    static func currentScreens() -> [ScreenBox] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                // No display id: treat it as external rather than lose the screen.
                return ScreenBox(frame: screen.frame, visibleFrame: screen.visibleFrame, isBuiltin: false)
            }
            let id = CGDirectDisplayID(n.uint32Value)
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { return nil }
            return ScreenBox(frame: screen.frame,
                             visibleFrame: screen.visibleFrame,
                             isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// `currentScreens()` from any thread — AppKit wants the main one, and the
    /// callers here run on background queues (the inbox poller, the HTTP server).
    static func currentScreensSafely() -> [ScreenBox] {
        if Thread.isMainThread { return currentScreens() }
        return DispatchQueue.main.sync { currentScreens() }
    }

    /// The AppleScript lines that move a just-created Terminal tab's window off
    /// the Retina, or a comment when there is nowhere else to put it.
    ///
    /// `tabVar` is the AppleScript variable holding the tab returned by
    /// `do script`, and the snippet must sit inside a `tell application "Terminal"`
    /// block.
    static func appleScriptSnippet(tabVar: String = "t",
                                   screens: [ScreenBox]? = nil) -> String {
        guard let b = bounds(screens: screens ?? currentScreensSafely()) else {
            return "    -- built-in display only: leave macOS's default placement"
        }
        return """
            try
                set bounds of (first window whose tabs contains \(tabVar)) to \(b.appleScriptList)
            end try
        """
    }
}
