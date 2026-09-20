import AppKit

/// "Hands off the keyboard" — the amber frame an agent raises around every
/// screen while it is driving the mouse and keyboard, plus a caption pinned to
/// the bottom centre of every screen saying who is driving and what it does.
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
    /// One caption per frame panel, so the label appears, updates and goes
    /// away with the frame — no second lifecycle to leak.
    private var captionFields: [NSTextField] = []
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
    /// The caption used to ride the cursor like a tooltip. That failed its one
    /// job: an agent whips the pointer across the screen, so the text was never
    /// where Victor's eye was, and at 13 pt it was a smudge. Now it sits still,
    /// centred at the bottom of every screen — a fixed place the eye learns —
    /// and twice as large, so it is read from across the desk.
    private let captionFontSize: CGFloat = 26
    private let captionBottomInset: CGFloat = 28
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
        setCaption(fresh.label)
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
        if captionFields.first?.stringValue != refreshed.label { setCaption(refreshed.label) }
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
            addCaption(to: view)
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
        captionFields = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                for panel in panels { panel.animator().alphaValue = 0 }
            } completionHandler: {
                for panel in panels { panel.orderOut(nil) }
            }
        }
    }

    // MARK: - Caption

    /// The amber plate with the label, bottom centre of the screen. Built once
    /// per frame; `setCaption` only swaps the text and re-centres it.
    private func addCaption(to view: NSView) {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: captionFontSize, weight: .semibold)
        field.textColor = .white
        field.alignment = .center
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = 3

        let plate = NSView(frame: .zero)
        plate.wantsLayer = true
        plate.layer?.backgroundColor = amber.withAlphaComponent(0.92).cgColor
        plate.layer?.cornerRadius = 12
        plate.addSubview(field)
        view.addSubview(plate)
        captionFields.append(field)
    }

    private func setCaption(_ text: String) {
        for field in captionFields {
            field.stringValue = text
            layoutCaption(field)
        }
    }

    private func layoutCaption(_ field: NSTextField) {
        guard let plate = field.superview, let screenView = plate.superview else { return }
        let pad = NSSize(width: 40, height: 20)
        // Never wider than the gap between the two bottom locks: a long `what`
        // wraps rather than running under them or off both edges.
        let maxTextWidth = screenView.frame.width - 2 * (lockInset + lockSize * 1.4 + 16) - pad.width
        field.preferredMaxLayoutWidth = maxTextWidth
        var textSize = field.sizeThatFits(NSSize(width: maxTextWidth, height: 1000))
        textSize.width = min(textSize.width, maxTextWidth)
        field.frame = NSRect(x: pad.width / 2, y: pad.height / 2, width: textSize.width, height: textSize.height)
        let size = NSSize(width: textSize.width + pad.width, height: textSize.height + pad.height)
        plate.frame = NSRect(x: (screenView.frame.width - size.width) / 2, y: captionBottomInset,
                             width: size.width, height: size.height)
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
