import AppKit

/// "Hands off the keyboard" — the amber frame an agent raises around every
/// screen while it is driving the mouse and keyboard, plus a small badge that
/// rides the cursor saying who is driving.
///
/// It exists because synthetic input cannot be delivered politely. An agent
/// that clicks a menu has to bring the app forward and physically move the
/// pointer, so whatever Victor was typing lands in the wrong window and
/// whatever he was dragging jumps. There is no way to make that invisible; the
/// next best thing is to make it *legible* — you can see, without asking, that
/// the machine is not yours for a moment, and you can see the instant it is
/// yours again.
///
/// The frame is drawn on **every** screen rather than the cursor's: automation
/// moves the pointer, and a warning that migrates between displays while you're
/// looking at the other one is a warning you miss precisely when it matters.
///
/// Release is announced twice, on purpose — the frame flashes green for half a
/// second and a short sound plays. Victor is usually not looking at the screen
/// while he waits (that is the whole reason he asked for this), so the ear has
/// to carry the "go" and the eye confirms it.
@MainActor
final class HandsOffOverlay {
    private(set) var session: HandsOffSession?

    private var framePanels: [NSPanel] = []
    private var badgePanel: NSPanel?
    private var badgeField: NSTextField?
    private var follow: Timer?
    private var watchdog: Timer?

    private let borderWidth: CGFloat = 6
    private let amber = NSColor.systemOrange
    private let free = NSColor.systemGreen
    /// 🔒 in all four corners, breathing slowly. The border says "something is
    /// happening"; the locks say *what you must not do* — hands off the mouse
    /// and the keyboard until they are gone. Four of them because Victor's eye
    /// is somewhere unpredictable on a 2-screen desk, and a corner is the one
    /// place no app puts content he was reading.
    private let lockGlyph = "🔒"
    private let lockSize: CGFloat = 64
    private let lockInset: CGFloat = 24
    /// Never fully opaque and never fully gone: at the bottom of the pulse the
    /// lock is still legible, so a glance that lands in the dark half of the
    /// cycle still answers the question.
    private let lockAlphaRange: (min: Float, max: Float) = (0.35, 0.95)
    /// One slow breath ≈ 2.4 s round trip. Fast blinking reads as an error the
    /// eye wants to dismiss; this reads as "still running".
    private let lockPulseDuration: CFTimeInterval = 1.2
    /// Below-right of the hotspot — the quadrant macOS cursor artwork leaves
    /// free, same choice as `BusyCursorSpinner`, so the badge never covers the
    /// thing being pointed at.
    private let badgeOffset = CGPoint(x: 16, y: -34)
    private let releaseChime = NSSound(named: NSSound.Name("Tink"))

    var isActive: Bool { session != nil }
    /// True when the frame went up by itself, because `SyntheticInputWatch` saw
    /// software posting mouse/keyboard events. Kept apart from an announced
    /// session so the announced label ("✋ claude — click pe Restart") is never
    /// overwritten by the anonymous one the tap can produce.
    private(set) var isAutoRaised = false

    // MARK: - Public API

    /// Claim the machine. Calling it again while active replaces the label and
    /// restarts the watchdog — an agent doing three things in a row should show
    /// the third, not keep announcing the first.
    func begin(agent: String?, what: String?, ttl: TimeInterval?) {
        let fresh = HandsOffSession(agent: agent, what: what, ttl: ttl, startedAt: Date())
        session = fresh
        isAutoRaised = false

        if framePanels.isEmpty {
            buildFrames()
        }
        setBorder(color: amber)
        showBadge(text: fresh.label)
        startWatchdog()
        overlayInfo("Hands off: \(fresh.label) (ttl \(Int(fresh.ttl))s)")
    }

    /// Raise the locks with nobody having asked — `SyntheticInputWatch` caught
    /// a process posting input. It says the process's name rather than a task,
    /// because that is all a tap can honestly know.
    ///
    /// An **announced** session always wins: an agent that took the trouble to
    /// say what it is doing must not have its label replaced by "Terminal".
    func beginAuto(agent: String, ttl: TimeInterval) {
        guard session == nil || isAutoRaised else { return }
        begin(agent: agent, what: "îți mișcă mouse-ul/tastatura", ttl: ttl)
        isAutoRaised = true
    }

    /// Keep an auto-raised frame alive while the synthetic input keeps coming.
    /// Deliberately not a second `begin`: that would rebuild the badge and write
    /// a log line every single second of a long automation run.
    func refreshAuto(agent: String, ttl: TimeInterval) {
        guard isAutoRaised, let current = session else { return }
        let refreshed = HandsOffSession(agent: agent, what: current.what, ttl: ttl, startedAt: Date())
        session = refreshed
        if badgeField?.stringValue != refreshed.label { showBadge(text: refreshed.label) }
    }

    /// Give it back. Safe to call when nothing is active — an agent that ends
    /// twice (retry, cleanup handler) must not be an error path.
    ///
    /// `silent` is for the auto-raised path: that one goes up and down in bursts
    /// as a script works, and a chime per burst would become the annoyance the
    /// whole feature exists to avoid. An announced release stays audible —
    /// Victor is usually not looking at the screen while he waits for it.
    func end(expired: Bool = false, silent: Bool = false) {
        guard session != nil else { return }
        let wasAuto = isAutoRaised
        session = nil
        isAutoRaised = false
        watchdog?.invalidate(); watchdog = nil
        hideBadge()
        flashFreeAndDismiss()
        if !silent { releaseChime?.play() }
        overlayInfo(expired ? "Hands off: released by watchdog"
                            : (wasAuto ? "Hands off: synthetic input stopped" : "Hands off: released"))
    }

    /// Read-only snapshot for `/hands-off/state`, so the behaviour can be
    /// asserted from a script instead of from a screenshot.
    func stateJSON() -> String {
        guard let session else { return "{\"active\":false}" }
        let remaining = Int(session.remaining(at: Date()).rounded())
        let escaped = session.label.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"active\":true,\"agent\":\"\(session.agent)\",\"label\":\"\(escaped)\",\"remainingSec\":\(remaining)}"
    }

    // MARK: - Frame

    private func buildFrames() {
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            // Click-through: the frame must never eat the click Victor makes
            // the moment he decides to take the machine back anyway.
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            // The border is drawn on the panel's own layer rather than as a
            // filled shape so the middle stays genuinely transparent — a
            // translucent wash over the whole screen would make the app
            // underneath harder to read for exactly as long as you most want to
            // watch what the agent is doing to it.
            view.layer?.borderWidth = borderWidth
            view.layer?.cornerRadius = 12
            view.layer?.borderColor = amber.cgColor
            addCornerLocks(to: view)
            panel.contentView = view
            panel.orderFrontRegardless()
            framePanels.append(panel)
        }
    }

    /// Four semi-transparent padlocks, one per corner, each pulsing on its own
    /// layer. They ride inside the frame panel, so they appear, fade and go
    /// away with it — there is no second lifecycle to leak.
    private func addCornerLocks(to view: NSView) {
        let size = view.frame.size
        let box = lockSize * 1.4
        let corners = [
            CGPoint(x: lockInset, y: lockInset),                                  // bottom-left
            CGPoint(x: size.width - box - lockInset, y: lockInset),               // bottom-right
            CGPoint(x: lockInset, y: size.height - box - lockInset),              // top-left
            CGPoint(x: size.width - box - lockInset, y: size.height - box - lockInset)
        ]
        for origin in corners {
            let label = NSTextField(labelWithString: lockGlyph)
            label.font = .systemFont(ofSize: lockSize)
            label.alignment = .center
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.frame = NSRect(origin: origin, size: NSSize(width: box, height: box))
            label.wantsLayer = true
            label.layer?.opacity = lockAlphaRange.max
            // A drop shadow rather than a plate behind the glyph: the emoji has
            // to stay readable over a white document and over a dark IDE, and a
            // badge in the corner would hide whatever it lands on.
            label.shadow = {
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.55)
                s.shadowBlurRadius = 6
                s.shadowOffset = .zero
                return s
            }()

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = lockAlphaRange.max
            pulse.toValue = lockAlphaRange.min
            pulse.duration = lockPulseDuration
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // All four breathe together — offsetting them would read as four
            // separate things blinking, which is decoration; in sync it reads
            // as one state the whole screen is in.
            pulse.beginTime = CACurrentMediaTime()
            label.layer?.add(pulse, forKey: "handsOffPulse")

            view.addSubview(label)
        }
    }

    private func setBorder(color: NSColor) {
        for panel in framePanels {
            panel.contentView?.layer?.borderColor = color.cgColor
        }
    }

    /// Green for half a second, then gone. The colour change and the fade are
    /// separate beats deliberately: green arriving *while the frame is still
    /// there* is what reads as "released", where fading amber straight out
    /// reads as "something closed" and could just as well be a crash.
    private func flashFreeAndDismiss() {
        guard !framePanels.isEmpty else { return }
        setBorder(color: free)
        let panels = framePanels
        framePanels = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                for panel in panels { panel.animator().alphaValue = 0 }
            } completionHandler: {
                for panel in panels { panel.orderOut(nil) }
            }
        }
    }

    // MARK: - Badge

    private func showBadge(text: String) {
        if let field = badgeField {
            field.stringValue = text
            sizeBadge(to: field)
            return
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let backdrop = NSView(frame: .zero)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = amber.withAlphaComponent(0.92).cgColor
        backdrop.layer?.cornerRadius = 7
        backdrop.addSubview(field)
        panel.contentView = backdrop

        badgePanel = panel
        badgeField = field
        sizeBadge(to: field)
        moveBadge()
        panel.orderFrontRegardless()

        // Same 30 ms as BusyCursorSpinner: enough to stay glued to a pointer
        // the agent is whipping across the screen, cheap because the panel is a
        // few dozen points of nothing.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveBadge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        follow = timer
    }

    private func sizeBadge(to field: NSTextField) {
        field.sizeToFit()
        let pad = NSSize(width: 20, height: 10)
        let size = NSSize(width: field.frame.width + pad.width, height: field.frame.height + pad.height)
        field.setFrameOrigin(NSPoint(x: pad.width / 2, y: pad.height / 2))
        badgePanel?.setContentSize(size)
        badgePanel?.contentView?.setFrameSize(size)
    }

    private func moveBadge() {
        guard let panel = badgePanel else { return }
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + badgeOffset.x, y: mouse.y + badgeOffset.y - panel.frame.height)
        // Keep it on the screen the cursor is on: pushed off the right or
        // bottom edge the badge is clipped, and a half-visible warning is the
        // one that gets misread.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(origin.x, f.maxX - panel.frame.width - 4)
            origin.x = max(origin.x, f.minX + 4)
            origin.y = max(origin.y, f.minY + 4)
            origin.y = min(origin.y, f.maxY - panel.frame.height - 4)
        }
        panel.setFrameOrigin(origin)
    }

    private func hideBadge() {
        follow?.invalidate(); follow = nil
        badgePanel?.orderOut(nil)
        badgePanel = nil
        badgeField = nil
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if session.isExpired(at: Date()) { self.end(expired: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
