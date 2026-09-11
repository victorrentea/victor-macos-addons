import AppKit

/// A transparent, click-through, always-on-top panel covering the built-in
/// retina screen — the canvas addons still needs after the effects moved out.
///
/// This is the old `OverlayPanel` (which went to Victor Effects with the
/// animator) under a new name, kept here for exactly one drawing: the red **−1**
/// that flies from an exploded ☕ to the break watch (`MinuteToken`). It is not
/// a general effects surface and nothing else should grow on it — anything with
/// pixels belongs in the effects app.
class AddonsOverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        ignoresMouseEvents = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view
    }

    /// Re-pin to the built-in retina display, which may have moved in the global
    /// coordinate space since the panel was created (a monitor plugged in, the
    /// projector arrangement applied).
    func refreshScreenFrame() {
        let target = AppDelegate.findRetinaScreen().frame
        if frame != target {
            setFrame(target, display: false)
        }
    }
}
