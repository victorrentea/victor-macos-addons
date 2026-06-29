import Cocoa

/// Unified bottom-left "pill" used by every banner in the addon
/// (status, silent-mic warning, transcription countdown, prompt-capture).
///
/// Renders a floating NSPanel on every connected screen, flush to the
/// bottom-left corner. The background is an NSVisualEffectView (glass)
/// with a configurable color tint on top — defaults to translucent gray;
/// callers can pass any NSColor (e.g. red for an urgent countdown).
///
/// Hover support is opt-in at construction time (`hoverable: true`). When
/// enabled, the panel accepts mouse events and an NSTrackingArea fires
/// `onHover` the first time the cursor enters on any screen.
///
/// The state-machine logic (presence-gating, countdown ticks, snooze,
/// auto-dismiss) lives in the caller. This class is rendering only.
final class BottomLeftBanner {
    enum Style {
        static let fontSize: CGFloat = 36
        static let leftPadding: CGFloat = 20
        static let rightPadding: CGFloat = 12
        static let textRenderHeight: CGFloat = 50
        /// Lower bound so a single glyph (e.g. a lone emoji) never collapses to
        /// a sliver. The box hugs the text above this and caps at `maxWidthFraction`.
        static let minBoxWidth: CGFloat = 80
        /// Hard cap as a fraction of the screen width — past this the text
        /// truncates with an ellipsis instead of the box growing further.
        static let maxWidthFraction: CGFloat = 0.5
        /// Minimum box width (as a fraction of the screen width) for banners
        /// that show a hover-countdown bar, so there's always room for the
        /// fixed hint chip on the left plus the bar filling to the right edge.
        /// Only applied when a countdown is present; well under `maxWidthFraction`.
        static let countdownMinWidthFraction: CGFloat = 0.30
        static let boxHeight: CGFloat = 80
        /// No extra tint by default — the NSVisualEffectView glass handles
        /// the gray-translucent look on its own. Callers that need a
        /// specific color (e.g. countdown red) pass their own NSColor.
        static let defaultBackground: NSColor = .clear
        static let textColor: NSColor = .white
        static func defaultFont() -> NSFont {
            NSFont.boldSystemFont(ofSize: fontSize)
        }

        // MARK: Hover hint (small label to the right of the pill, sitting at the
        // bottom edge, explaining what hovering does). Its text is tinted to
        // match the hover-countdown bar (progressBarColor). Only shown when the
        // banner is hoverable AND has an active onHover action.
        static let hintFontSize: CGFloat = 15
        static let hintHeight: CGFloat = 26
        static let hintTextHeight: CGFloat = 18
        /// Horizontal gap between the right edge of the pill and the hint.
        static let hintGap: CGFloat = 8
        static let hintHPadding: CGFloat = 10
        static let hintBackground: NSColor = NSColor.black.withAlphaComponent(0.6)
        static func hintFont() -> NSFont { NSFont.systemFont(ofSize: hintFontSize) }

        // MARK: Hover-countdown bar (a thin orange strip along the bottom edge
        // that grows left→right over the window during which the banner can
        // still be hovered to act). Only shown when the banner is hoverable
        // AND has an active onHover.
        static let progressBarHeight: CGFloat = 5
        static let progressBarColor: NSColor = .systemOrange
    }

    private let screensProvider: () -> [NSScreen]
    private let hoverable: Bool

    private struct PanelEntry {
        let panel: NSPanel
        let tint: NSView
        /// White overlay above the tint that ramps up during the hover
        /// dwell. Alpha 0 at rest, alpha 1 the instant `onHover` fires.
        let whitenTint: NSView
        /// Thin orange strip along the bottom edge whose width animates from 0
        /// to the full box width over the hover window. Hidden at rest.
        let progressBar: NSView
        let label: NSTextField
        /// Kept so `updateText` can re-measure and resize the box to hug the
        /// new text (still capped at `maxWidthFraction` of this screen).
        let font: NSFont
        let screen: NSScreen
    }
    private var panels: [PanelEntry] = []
    /// Small "Hover to …" hint panels above the pill, one per screen. Managed
    /// independently of `panels` since the hint is optional. Empty unless the
    /// banner is hoverable with an active `onHover` and a non-nil hint.
    private var hintPanels: [NSPanel] = []
    /// Short-lived fullscreen overlays that host the glass-shatter shards during
    /// a `dismissShatter()`. Held only for the animation's lifetime, then torn
    /// down — they outlive the pill panels they replace.
    private var shatterPanels: [NSPanel] = []

    /// Fires once per `show()` after the cursor has *dwelled* inside the
    /// banner for at least `hoverDwellRequiredSamples × hoverDwellInterval`
    /// (0.5s by default). Cursor merely happening to be in the corner when
    /// the banner appears never fires this — NSTrackingArea only kicks in
    /// on a fresh entry, and even then the user must hold the cursor in
    /// place. Only meaningful when `hoverable: true`.
    var onHover: (() -> Void)?
    private var hoverFired = false

    private static let hoverDwellInterval: TimeInterval = 0.1
    private static let hoverDwellRequiredSamples = 10
    private var hoverDwellTimer: Timer?
    private var hoverDwellCount = 0

    /// Fires once the hover-countdown bar fills completely *without* the user
    /// hovering to act — i.e. the window closed on its own. Callers use it to
    /// dismiss the banner. Because the countdown pauses whenever the cursor is
    /// inside the pill, this fires after `duration` seconds of *un-hovered*
    /// time, not wall-clock. Only meaningful while a countdown is running.
    var onHoverCountdownExpired: (() -> Void)?

    private static let countdownTick: TimeInterval = 0.05
    private var countdownTimer: Timer?
    private var countdownDuration: TimeInterval = 0
    private var countdownElapsed: TimeInterval = 0

    /// True while the active presentation includes a hover countdown — widens
    /// the pill to at least `countdownMinWidthFraction` of the screen so the
    /// fixed hint chip and the progress bar to its right both fit. Set in
    /// `show()` from whether `hoverCountdown` was non-nil; read by `panelWidth`.
    private var hasCountdown = false

    /// When true, the hint chip is pinned to the pill's bottom-left corner
    /// (and the progress bar fills the region to its right) instead of sitting
    /// fixed to the right of the pill. Set per `show()` — true whenever a hover
    /// countdown accompanies the hint, which every current caller does.
    private var hintFixedLeft = false

    /// Final window opacity when visible. Below 1.0 to add an extra layer
    /// of see-through on top of the NSVisualEffectView glass.
    private static let visibleAlpha: CGFloat = 0.75

    init(screensProvider: @escaping () -> [NSScreen], hoverable: Bool = false) {
        self.screensProvider = screensProvider
        self.hoverable = hoverable
    }

    var isVisible: Bool { !panels.isEmpty }

    /// True while the cursor is within any of this banner's panels. Lets
    /// callers (e.g. `StatusBanner`) keep a transient banner alive on hover
    /// without making the panel intercept mouse events.
    var isMouseInside: Bool { isMouseInsideAnyPanel() }

    /// Show the banner with `text` and `backgroundColor`. Replaces any
    /// existing visible content (text + color updated in place; no fade-out
    /// flicker). Fades in over 0.3s when first appearing.
    ///
    /// `hoverCountdown`, when non-nil, draws a thin orange bar along the bottom
    /// edge that grows from left to right over that many seconds, visualizing
    /// how long the banner can still be hovered to act. It only appears when the
    /// banner is hoverable with an active `onHover` (status/error flashes get no
    /// bar). Pass nil to clear any bar from a previous show on a reused banner.
    func show(text: String,
              backgroundColor: NSColor = Style.defaultBackground,
              font: NSFont = Style.defaultFont(),
              hoverHint: String? = nil,
              hoverCountdown: TimeInterval? = nil) {
        // Each show() presents new content → re-arm hover and clear any leftover
        // dwell whitening (e.g. after a previous fire on a banner being reused).
        cancelHoverDwell()
        hoverFired = false
        // Drives the 30% min width (panelWidth) and the fixed-left chip layout.
        hasCountdown = hoverCountdown != nil
        if isVisible {
            updateText(text)
            updateBackgroundColor(backgroundColor)
            applyHint(hoverHint, fixedLeft: hasCountdown)
            applyHoverCountdown(hoverCountdown)
            return
        }
        for screen in screensProvider() {
            panels.append(buildPanel(on: screen,
                                     text: text,
                                     bg: backgroundColor,
                                     font: font))
        }
        for entry in panels {
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            for entry in panels { entry.panel.animator().alphaValue = Self.visibleAlpha }
        }
        applyHint(hoverHint, fixedLeft: hasCountdown)
        applyHoverCountdown(hoverCountdown)
    }

    func updateText(_ text: String) {
        for entry in panels {
            entry.label.stringValue = text
            resize(entry, to: panelWidth(for: text, font: entry.font, screen: entry.screen))
        }
        repositionHints()
    }

    /// Width that hugs `text` at `font`, floored at `minBoxWidth` and capped at
    /// `maxWidthFraction` of the screen — past the cap the label truncates.
    ///
    /// Measured via a throwaway `NSTextField.sizeToFit()` rather than
    /// `NSString.size(withAttributes:)`: the latter ignores font substitution
    /// for emoji, under-measuring strings like "⬆️ Pasted" so the real label
    /// clipped to "⬆️ Past⋯". The probe lays out exactly as the shown label.
    private func panelWidth(for text: String, font: NSFont, screen: NSScreen) -> CGFloat {
        let probe = NSTextField(labelWithString: text)
        probe.font = font
        probe.maximumNumberOfLines = 1
        probe.lineBreakMode = .byClipping
        probe.sizeToFit()
        let content = ceil(probe.frame.width) + Style.leftPadding + Style.rightPadding
        let maxWidth = screen.frame.width * Style.maxWidthFraction
        // Countdown banners get a 30%-screen floor so the fixed hint chip and
        // the progress bar to its right both fit; plain banners hug their text.
        let minWidth = hasCountdown
            ? max(Style.minBoxWidth, screen.frame.width * Style.countdownMinWidthFraction)
            : Style.minBoxWidth
        return min(max(content, minWidth), maxWidth)
    }

    /// Resize a panel (anchored bottom-left) and its label to `width` in place.
    private func resize(_ entry: PanelEntry, to width: CGFloat) {
        guard abs(entry.panel.frame.width - width) > 0.5 else { return }
        let f = entry.screen.frame
        entry.panel.setFrame(NSRect(x: f.minX, y: f.minY, width: width, height: Style.boxHeight),
                             display: true)
        entry.label.frame = NSRect(
            x: Style.leftPadding,
            y: (Style.boxHeight - Style.textRenderHeight) / 2,
            width: width - Style.leftPadding - Style.rightPadding,
            height: Style.textRenderHeight
        )
    }

    /// Update the gray-tint color over the glass. When `animated`, the
    /// transition runs as an explicit CABasicAnimation of duration `duration`.
    func updateBackgroundColor(_ color: NSColor,
                               animated: Bool = false,
                               duration: TimeInterval = 0.3) {
        let cg = color.cgColor
        for entry in panels {
            guard let layer = entry.tint.layer else { continue }
            if animated {
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = layer.backgroundColor
                anim.toValue = cg
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
                anim.fillMode = .forwards
                layer.add(anim, forKey: "tintColor")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = cg
            CATransaction.commit()
        }
    }

    func dismiss(animated: Bool = true) {
        guard isVisible else { return }
        cancelHoverDwell()
        clearHoverCountdown()
        let toRemove = panels
        panels.removeAll()
        let hints = hintPanels
        hintPanels.removeAll()
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                for entry in toRemove { entry.panel.animator().alphaValue = 0 }
                for hint in hints { hint.animator().alphaValue = 0 }
            }, completionHandler: {
                for entry in toRemove { entry.panel.orderOut(nil) }
                for hint in hints { hint.orderOut(nil) }
            })
        } else {
            for entry in toRemove { entry.panel.orderOut(nil) }
            for hint in hints { hint.orderOut(nil) }
        }
    }

    // MARK: - Outcome-flavored dismissals
    //
    // Every interactive banner ends one of two ways, and the exit animation
    // tells the user *which*:
    //   • dismissRisingFade — they ACCEPTED / COMMITTED a proposed action
    //     (confirm "send to notes", or let a paste stand). The pill lifts up
    //     and fades, as if the content floated off into the notes.
    //   • dismissShatter — they CANCELLED an action that had already happened
    //     (hover-to-undo a paste). The pill breaks like glass and the shards
    //     spray outward, falling and fading — the action is visibly destroyed.

    /// Dismiss by floating the pill (and any hint) straight up while fading to
    /// transparent over ~1s. The "accepted / committed" gesture.
    func dismissRisingFade() {
        guard isVisible else { return }
        cancelHoverDwell()
        clearHoverCountdown()
        let toRemove = panels
        panels.removeAll()
        let hints = hintPanels
        hintPanels.removeAll()
        let rise: CGFloat = 140
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for entry in toRemove {
                var f = entry.panel.frame
                f.origin.y += rise
                entry.panel.animator().setFrame(f, display: true)
                entry.panel.animator().alphaValue = 0
            }
            for hint in hints {
                var f = hint.frame
                f.origin.y += rise
                hint.animator().setFrame(f, display: true)
                hint.animator().alphaValue = 0
            }
        }, completionHandler: {
            for entry in toRemove { entry.panel.orderOut(nil) }
            for hint in hints { hint.orderOut(nil) }
        })
    }

    /// Dismiss by shattering the pill like glass. The pill (and hint) vanish
    /// instantly and a fullscreen overlay sprays glass shards outward from an
    /// impact point — each spinning and falling under gravity as it fades. The
    /// "cancel a done action" gesture.
    func dismissShatter() {
        guard isVisible else { return }
        cancelHoverDwell()
        clearHoverCountdown()
        let toRemove = panels
        panels.removeAll()
        let hints = hintPanels
        hintPanels.removeAll()
        for hint in hints { hint.orderOut(nil) }
        for entry in toRemove {
            spawnShatter(pillFrameScreen: entry.panel.frame, on: entry.screen)
            entry.panel.orderOut(nil)
        }
    }

    /// Build a transparent fullscreen panel over `screen` and fan glass shards
    /// out of the pill's footprint. Fullscreen (not pill-sized) so shards can
    /// fly past the pill's tiny bounds before fading. Auto-removed once the
    /// longest shard animation finishes.
    private func spawnShatter(pillFrameScreen: NSRect, on screen: NSScreen) {
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        panel.contentView = content
        guard let host = content.layer else { return }

        // Pill rect in panel-local coords (panel frame == screen frame).
        let pill = NSRect(x: pillFrameScreen.minX - screen.frame.minX,
                          y: pillFrameScreen.minY - screen.frame.minY,
                          width: pillFrameScreen.width,
                          height: pillFrameScreen.height)

        // Impact point, biased toward the pill center: shards fan out from here.
        let impact = CGPoint(x: pill.midX + CGFloat.random(in: -0.18...0.18) * pill.width,
                             y: pill.midY + CGFloat.random(in: -0.12...0.12) * pill.height)

        let count = min(22, max(10, Int(pill.width / 34)))
        let rim = perimeterPoints(pill, count: count)
        let fill = NSColor(srgbRed: 0.86, green: 0.94, blue: 1.0, alpha: 0.16).cgColor
        let stroke = NSColor(white: 1.0, alpha: 0.66).cgColor

        var maxDur: TimeInterval = 0
        for i in 0..<rim.count {
            let a = rim[i]
            let b = rim[(i + 1) % rim.count]
            let bbox = boundingBox([impact, a, b]).insetBy(dx: -1, dy: -1)

            let shard = CAShapeLayer()
            shard.frame = bbox
            let path = CGMutablePath()
            path.move(to: CGPoint(x: impact.x - bbox.minX, y: impact.y - bbox.minY))
            path.addLine(to: CGPoint(x: a.x - bbox.minX, y: a.y - bbox.minY))
            path.addLine(to: CGPoint(x: b.x - bbox.minX, y: b.y - bbox.minY))
            path.closeSubpath()
            shard.path = path
            shard.fillColor = fill
            shard.strokeColor = stroke
            shard.lineWidth = 0.8
            shard.lineJoin = .miter
            host.addSublayer(shard)

            // Velocity: outward from the impact (centroid direction) + a downward
            // gravity bias (down = −y in this bottom-left-origin layer space).
            let centroid = CGPoint(x: (impact.x + a.x + b.x) / 3,
                                   y: (impact.y + a.y + b.y) / 3)
            var dx = centroid.x - impact.x
            var dy = centroid.y - impact.y
            let len = max(1, hypot(dx, dy))
            let speed = CGFloat.random(in: 70...240)
            dx = dx / len * speed + CGFloat.random(in: -25...25)
            dy = dy / len * speed - CGFloat.random(in: 30...130)
            let from = CGPoint(x: bbox.midX, y: bbox.midY)
            let to = CGPoint(x: from.x + dx, y: from.y + dy)
            let dur = TimeInterval(CGFloat.random(in: 0.6...0.85))
            maxDur = max(maxDur, dur)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = from
            move.toValue = to
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.random(in: -2.4...2.4)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [move, spin, fade]
            group.duration = dur
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            shard.opacity = 0
            shard.add(group, forKey: "shatter")
        }

        // A quick white pop at the impact point to read as the "crack".
        let flash = CALayer()
        let fs: CGFloat = 26
        flash.frame = NSRect(x: impact.x - fs / 2, y: impact.y - fs / 2, width: fs, height: fs)
        flash.cornerRadius = fs / 2
        flash.backgroundColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        host.addSublayer(flash)
        let fScale = CABasicAnimation(keyPath: "transform.scale")
        fScale.fromValue = 0.3
        fScale.toValue = 5.0
        let fFade = CABasicAnimation(keyPath: "opacity")
        fFade.fromValue = 0.9
        fFade.toValue = 0
        let fGroup = CAAnimationGroup()
        fGroup.animations = [fScale, fFade]
        fGroup.duration = 0.3
        fGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fGroup.fillMode = .forwards
        fGroup.isRemovedOnCompletion = false
        flash.opacity = 0
        flash.add(fGroup, forKey: "flash")

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        shatterPanels.append(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + maxDur + 0.1) { [weak self] in
            panel.orderOut(nil)
            self?.shatterPanels.removeAll { $0 === panel }
        }
    }

    /// `count` points spaced evenly around the rectangle's perimeter, starting at
    /// the bottom-left and walking counter-clockwise. Used as the outer vertices
    /// of the shard fan.
    private func perimeterPoints(_ rect: CGRect, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let w = rect.width, h = rect.height
        let perim = 2 * (w + h)
        var pts: [CGPoint] = []
        for i in 0..<count {
            var d = perim * CGFloat(i) / CGFloat(count)
            if d < w { pts.append(CGPoint(x: rect.minX + d, y: rect.minY)); continue }
            d -= w
            if d < h { pts.append(CGPoint(x: rect.maxX, y: rect.minY + d)); continue }
            d -= h
            if d < w { pts.append(CGPoint(x: rect.maxX - d, y: rect.maxY)); continue }
            d -= w
            pts.append(CGPoint(x: rect.minX, y: rect.maxY - d))
        }
        return pts
    }

    private func boundingBox(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    fileprivate func startHoverDwell() {
        // Only arm the dwell when hovering actually does something — error
        // flashes (onHover == nil) must not whiten or fire.
        guard hoverable, onHover != nil, !hoverFired, hoverDwellTimer == nil else { return }
        hoverDwellCount = 0
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDwellInterval, repeats: true) { [weak self] _ in
            self?.tickHoverDwell()
        }
    }

    fileprivate func cancelHoverDwell() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
        if hoverDwellCount > 0 {
            hoverDwellCount = 0
            applyWhitenProgress(0)
        }
    }

    private func tickHoverDwell() {
        guard !hoverFired else { cancelHoverDwell(); return }
        if isMouseInsideAnyPanel() {
            hoverDwellCount += 1
            let progress = min(1.0, CGFloat(hoverDwellCount) / CGFloat(Self.hoverDwellRequiredSamples))
            applyWhitenProgress(progress)
            if hoverDwellCount >= Self.hoverDwellRequiredSamples {
                hoverDwellTimer?.invalidate()
                hoverDwellTimer = nil
                fireHover()
            }
        } else if hoverDwellCount > 0 {
            hoverDwellCount = 0
            applyWhitenProgress(0)
        }
    }

    /// Animate the per-panel "whitening" overlay to `alpha`. Linear over
    /// one dwell-tick interval so the ramp feels continuous as the user
    /// holds the cursor in place.
    private func applyWhitenProgress(_ alpha: CGFloat) {
        let cg = NSColor.white.withAlphaComponent(alpha).cgColor
        for entry in panels {
            guard let layer = entry.whitenTint.layer else { continue }
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.backgroundColor
            anim.toValue = cg
            anim.duration = Self.hoverDwellInterval
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(anim, forKey: "whiten")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = cg
            CATransaction.commit()
        }
    }

    private func isMouseInsideAnyPanel() -> Bool {
        let pos = NSEvent.mouseLocation
        for entry in panels where entry.panel.frame.contains(pos) {
            return true
        }
        return false
    }

    private func fireHover() {
        guard !hoverFired else { return }
        hoverFired = true
        clearHint()
        onHover?()
    }

    /// (Re)build the "Hover to …" hint panels. Tears down any existing ones,
    /// then — only when the banner is hoverable, has an active `onHover`, and
    /// `hint` is non-empty — fades a small label in to the right of each pill,
    /// glued to its bottom edge. Built off the live pill frames (not the screen
    /// list) so the hint hugs the pill's actual right edge as it resizes.
    private func applyHint(_ hint: String?, fixedLeft: Bool) {
        clearHint()
        guard hoverable, onHover != nil, let hint = hint, !hint.isEmpty else { return }
        hintFixedLeft = fixedLeft
        for entry in panels {
            let panel = buildHintPanel(pillFrame: entry.panel.frame, text: hint)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            hintPanels.append(panel)
        }
        repositionHints()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            for panel in hintPanels { panel.animator().alphaValue = 1.0 }
        }
    }

    /// Immediately remove all hint panels (no fade).
    func clearHint() {
        for panel in hintPanels { panel.orderOut(nil) }
        hintPanels.removeAll()
        hintFixedLeft = false
    }

    /// Re-place every hint chip after a pill move/resize, or on (re)show. With a
    /// countdown the chip is pinned to the pill's bottom-left corner (the bar
    /// then fills the region to its right); without one it sits just past the
    /// pill's right edge. No-op when no hint is showing.
    private func repositionHints() {
        guard hintPanels.count == panels.count else { return }
        for (entry, hint) in zip(panels, hintPanels) {
            let pill = entry.panel.frame
            var f = hint.frame
            f.origin.x = hintFixedLeft ? pill.minX : pill.maxX + Style.hintGap
            f.origin.y = pill.minY
            hint.setFrame(f, display: true)
        }
    }

    private func applyHoverCountdown(_ duration: TimeInterval?) {
        if let duration = duration {
            startHoverCountdown(duration: duration)
        } else {
            clearHoverCountdown()
        }
    }

    /// Begin filling the bottom-edge orange bar from left to right over
    /// `duration` seconds of *un-hovered* time. While the cursor sits inside
    /// the pill the bar freezes — the window can't expire out from under a
    /// hovering user, and they get unlimited time to dwell-confirm — and it
    /// resumes when the cursor leaves. Gated on the banner being hoverable with
    /// an active `onHover` (a non-actionable flash never sprouts a bar). Resets
    /// any in-flight countdown first, so a reused banner restarts cleanly.
    func startHoverCountdown(duration: TimeInterval) {
        clearHoverCountdown()
        guard hoverable, onHover != nil, duration > 0 else { return }
        countdownDuration = duration
        countdownElapsed = 0
        repositionHints()
        for (i, entry) in panels.enumerated() {
            entry.progressBar.isHidden = false
            setBar(entry.progressBar, x: barStartX(at: i), width: 0)
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: Self.countdownTick, repeats: true) { [weak self] _ in
            self?.tickCountdown()
        }
    }

    private func tickCountdown() {
        // The defining behavior: pause while the cursor is on the pill. Elapsed
        // time (and therefore the bar) only advances when the user is away.
        if !isMouseInsideAnyPanel() {
            countdownElapsed += Self.countdownTick
        }
        let progress = countdownDuration > 0 ? min(1.0, countdownElapsed / countdownDuration) : 1.0
        for (i, entry) in panels.enumerated() {
            let startX = barStartX(at: i)
            let track = max(0, entry.panel.frame.width - startX)
            setBar(entry.progressBar, x: startX, width: CGFloat(progress) * track)
        }
        if countdownElapsed >= countdownDuration {
            countdownTimer?.invalidate(); countdownTimer = nil
            onHoverCountdownExpired?()
        }
    }

    /// Left edge (in pill-content coordinates) where the progress bar begins:
    /// just past the fixed hint chip (its width + a gap) so the bar fills the
    /// region to the right of the text. Falls back to 0 (full width) when the
    /// chip isn't fixed-left or no hint is showing.
    private func barStartX(at index: Int) -> CGFloat {
        guard hintFixedLeft, index < hintPanels.count else { return 0 }
        return hintPanels[index].frame.width + Style.hintGap
    }

    /// Position the bar at `x` with `width`, implicit animation disabled. At the
    /// 20 fps tick the steps are imperceptible, and an implicit ~0.25s animation
    /// would lag the freeze the instant the cursor lands on the pill.
    private func setBar(_ bar: NSView, x: CGFloat, width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = NSRect(x: x, y: 0, width: max(0, width), height: Style.progressBarHeight)
        CATransaction.commit()
    }

    /// Stop the countdown and hide the bar on every panel. Called on each
    /// show() (so a reused banner never shows a stale bar), on dismiss(), and
    /// by callers once the window closes another way (e.g. a countdown overlay
    /// reaching 0).
    func clearHoverCountdown() {
        countdownTimer?.invalidate(); countdownTimer = nil
        countdownElapsed = 0
        for entry in panels {
            setBar(entry.progressBar, x: 0, width: 0)
            entry.progressBar.isHidden = true
        }
    }

    private func buildHintPanel(pillFrame: NSRect, text: String) -> NSPanel {
        let font = Style.hintFont()
        let probe = NSTextField(labelWithString: text)
        probe.font = font
        probe.maximumNumberOfLines = 1
        probe.lineBreakMode = .byClipping
        probe.sizeToFit()
        let width = ceil(probe.frame.width) + Style.hintHPadding * 2

        // To the right of the pill, glued to its (and the screen's) bottom edge.
        let rect = NSRect(x: pillFrame.maxX + Style.hintGap,
                          y: pillFrame.minY,
                          width: width,
                          height: Style.hintHeight)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Style.hintBackground.cgColor
        content.layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: text)
        label.font = font
        // Same color as the hover-countdown progress bar.
        label.textColor = Style.progressBarColor
        label.alignment = .left
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.frame = NSRect(x: Style.hintHPadding,
                             y: (Style.hintHeight - Style.hintTextHeight) / 2,
                             width: width - Style.hintHPadding * 2,
                             height: Style.hintTextHeight)
        content.addSubview(label)

        panel.contentView = content
        return panel
    }

    private func buildPanel(on screen: NSScreen,
                            text: String,
                            bg: NSColor,
                            font: NSFont) -> PanelEntry {
        let frame = screen.frame
        let width = panelWidth(for: text, font: font, screen: screen)
        let rect = NSRect(x: frame.minX, y: frame.minY, width: width, height: Style.boxHeight)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = !hoverable

        let content: NSView
        if hoverable {
            let hover = HoverView(frame: NSRect(origin: .zero, size: rect.size))
            hover.banner = self
            content = hover
        } else {
            content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        }
        content.wantsLayer = true

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        content.addSubview(effect)

        let tint = NSView(frame: content.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.cgColor
        content.addSubview(tint)

        let whitenTint = NSView(frame: content.bounds)
        whitenTint.autoresizingMask = [.width, .height]
        whitenTint.wantsLayer = true
        whitenTint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0).cgColor
        content.addSubview(whitenTint)

        let textWidth = width - Style.leftPadding - Style.rightPadding
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = Style.textColor
        label.alignment = .left
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: Style.leftPadding,
            y: (Style.boxHeight - Style.textRenderHeight) / 2,
            width: textWidth,
            height: Style.textRenderHeight
        )
        label.autoresizingMask = [.width]
        content.addSubview(label)

        // Topmost so it stays visible over the glass, tint, text, and the
        // dwell whitening. Width is driven manually by the hover countdown;
        // no autoresizing so a panel resize never stretches it on its own.
        let progressBar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Style.progressBarHeight))
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = Style.progressBarColor.cgColor
        progressBar.autoresizingMask = []
        progressBar.isHidden = true
        content.addSubview(progressBar)

        panel.contentView = content
        return PanelEntry(panel: panel, tint: tint, whitenTint: whitenTint,
                          progressBar: progressBar, label: label,
                          font: font, screen: screen)
    }
}

private final class HoverView: NSView {
    weak var banner: BottomLeftBanner?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with _: NSEvent) {
        banner?.startHoverDwell()
    }

    override func mouseExited(with _: NSEvent) {
        banner?.cancelHoverDwell()
    }
}
