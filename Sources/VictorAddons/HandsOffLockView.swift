import AppKit

/// One corner 🔒 of the hands-off overlay — and, since 2026-09-26, the stop
/// button: **real** clicks on it are Victor taking the machine back
/// (`HandsOffOverlay.takeover`). Since 2026-09-28 it takes two (the first only
/// arms, `HandsOffLockClicks`), and hovering it is how the "why" is read — the
/// bottom caption that used to say it is gone.
///
/// "Real" is the point. While the locks are up an agent is posting synthetic
/// clicks, and one that happened to land in a corner must not stop itself — so a
/// click counts only when its source pid is 0, the same test
/// `SyntheticInputWatch` uses to tell hardware from software.
final class HandsOffLockView: NSView {
    var onClick: (() -> Void)?
    /// Pointer in (true) / out (false): the overlay shows or hides the
    /// explanation beside this lock.
    var onHover: ((Bool) -> Void)?

    private let label: NSTextField
    private let plate = CALayer()

    init(frame: NSRect, glyph: String, glyphSize: CGFloat) {
        label = NSTextField(labelWithString: glyph)
        super.init(frame: frame)
        wantsLayer = true

        // The red disc behind the ✋ in the takeover state; invisible until then.
        let d = min(frame.width, frame.height) * 0.92
        plate.frame = CGRect(x: (frame.width - d) / 2, y: (frame.height - d) / 2, width: d, height: d)
        plate.cornerRadius = d / 2
        plate.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(plate)

        label.font = .systemFont(ofSize: glyphSize)
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        // Vertically centred: a label frame as tall as the box puts the glyph high.
        let h = label.sizeThatFits(NSSize(width: frame.width, height: 1000)).height
        label.frame = NSRect(x: 0, y: (frame.height - h) / 2, width: frame.width, height: h)
        // A drop shadow rather than a plate behind the glyph: the emoji has to
        // stay readable over a white document and over a dark IDE, and a badge
        // in the corner would hide whatever it lands on.
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 6
            s.shadowOffset = .zero
            return s
        }()
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The slow breath (see `HandsOffOverlay.lockPulseDuration`).
    func startPulse(min: Float, max: Float, duration: CFTimeInterval) {
        layer?.opacity = max
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = max
        pulse.toValue = min
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // All four breathe together — offsetting them would read as four
        // separate things blinking, which is decoration; in sync it reads as one
        // state the whole screen is in.
        pulse.beginTime = CACurrentMediaTime()
        layer?.add(pulse, forKey: "handsOffPulse")
    }

    /// 🔒 → ✋ on a red disc, fully opaque, no more breathing.
    func showTakeover(red: NSColor) {
        layer?.removeAnimation(forKey: "handsOffPulse")
        layer?.opacity = 1
        plate.backgroundColor = red.withAlphaComponent(0.95).cgColor
        plate.borderColor = NSColor.white.cgColor
        plate.borderWidth = 3
        label.stringValue = "✋"
    }

    // MARK: - Clicks

    /// The app is never active while this is clicked (the panel is
    /// non-activating), so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let sourcePid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        guard sourcePid == 0 else {
            overlayInfo("Hands off: ignored a synthetic click on a 🔒 (source pid \(sourcePid))")
            return
        }
        onClick?()
    }

    // Pointing hand on hover: the lock is a button now and should look like one.
    // The same enter/exit pair shows and hides the explanation beside it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // `set`, not push/pop: a lock torn down while hovered must not leave a
    // pushed cursor on the stack.
    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(false)
    }
}
