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
    /// Which way the pill slides *slightly* while the cursor dwells on it, on
    /// top of the whitening — a directional hint for what hovering will do:
    ///   • `.up`   — hovering CONFIRMS / commits an offered action (e.g. "Send
    ///     prompt to notes?"); the pill drifts up, previewing the rising-fade exit.
    ///   • `.down` — hovering CANCELS an already-done action or dismisses the
    ///     banner (undo a paste, snooze a warning); the pill drifts down,
    ///     previewing the sinking exit.
    ///   • `.none` — no directional nudge (default; whitening only).
    /// The offset ramps with the dwell progress and springs back when the cursor
    /// leaves, mirroring the whitening.
    enum HoverNudge { case none, up, down }

    enum Style {
        // Bottom-left overlay geometry, scaled ×1.5 from the original (font +
        // box) for presentation visibility.
        static let fontSize: CGFloat = 54
        static let leftPadding: CGFloat = 30
        static let rightPadding: CGFloat = 18
        static let textRenderHeight: CGFloat = 75
        /// Lower bound so a single glyph (e.g. a lone emoji) never collapses to
        /// a sliver. The box hugs the text above this and caps at `maxWidthFraction`.
        static let minBoxWidth: CGFloat = 120
        /// Hard cap as a fraction of the screen width — past this the text
        /// truncates with an ellipsis instead of the box growing further.
        static let maxWidthFraction: CGFloat = 0.5
        /// Minimum box width (as a fraction of the screen width) for banners
        /// that show a hover-countdown bar, so there's always room for the
        /// fixed hint chip on the left plus the bar filling to the right edge.
        /// Only applied when a countdown is present; well under `maxWidthFraction`.
        static let countdownMinWidthFraction: CGFloat = 0.30
        // Pill height, snug around the centered main text so its bottom sits
        // flush on the screen's bottom edge with no dead strip below (the old
        // hint text + progress bar that used to fill that strip are gone).
        static let boxHeight: CGFloat = 90
        /// No extra tint by default — the NSVisualEffectView glass handles
        /// the gray-translucent look on its own. Callers that need a
        /// specific color (e.g. countdown red) pass their own NSColor.
        static let defaultBackground: NSColor = .clear
        static let textColor: NSColor = .white
        static func defaultFont() -> NSFont {
            NSFont.boldSystemFont(ofSize: fontSize)
        }

        // MARK: Send/cancel arrow — a double-chevron floating in the transparent
        // gutter just OUTSIDE the pill's right edge, vertically centered. It
        // replaces the old "Hover to …" hint text. Two stacked arrowheads pointing
        // UP mean "hover to send / confirm" (nudge `.up`), DOWN means "hover to
        // cancel / put away" (nudge `.down`). Orange, to match the progressive
        // border. It continuously marches in its pointing direction as a hint.
        static let arrowChevronWidth: CGFloat = 26
        static let arrowChevronHeight: CGFloat = 10
        static let arrowChevronGap: CGFloat = 6
        static let arrowLineWidth: CGFloat = 4
        static let arrowColor: NSColor = .systemOrange
        /// Gap between the pill's right edge and the arrow, and trailing padding
        /// after the arrow. Together with the chevron width they define the width
        /// of the transparent gutter the panel gains on the right to hold the arrow.
        static let arrowGap: CGFloat = 14
        static let arrowTrailing: CGFloat = 12
        static var arrowGutter: CGFloat { arrowGap + arrowChevronWidth + arrowTrailing }
        /// The arrow continuously slides this far in its pointing direction, fades
        /// out, then resets and re-slides — a looping "swipe up/down" hint.
        static let arrowSlideDistance: CGFloat = 16
        static let arrowSlideDuration: TimeInterval = 1.1

        // MARK: Progressive border — an orange outline drawn *in lockstep* with
        // the hover countdown. From the bottom-left corner two strokes grow at
        // equal speed — one UP the left edge then across the top, one RIGHT along
        // the bottom then up the right edge — meeting at the top-right corner
        // exactly when the countdown completes (both paths have equal length w+h,
        // so the shared progress reaches the corner from both sides together).
        // 2× the original thickness for presence.
        static let borderWidth: CGFloat = 4
        static let borderColor: NSColor = .systemOrange

        // MARK: Hover nudge — how far (points) the pill drifts up/down at full
        // dwell. Deliberately small: a subtle directional cue, not a jump.
        static let hoverNudgeDistance: CGFloat = 10
    }

    // MARK: - Theme
    //
    // The pill's glass (NSVisualEffectView `.hudWindow`) renders *dark* in the
    // OS dark theme and *light* in the light theme automatically — but the text
    // and the hover feedback were hardcoded for the dark look (white text, a
    // white "whitening" hover overlay). On a light-mode Mac that left white text
    // on a near-white pill — barely readable. `Palette` resolves the parts that
    // must flip with the OS theme so the banner reads well in both.
    private struct Palette {
        /// Main label color: white on the dark pill, near-black on the light one.
        let text: NSColor
        /// Base color the hover-dwell overlay ramps up: white *lightens* the dark
        /// pill, black *darkens* the light one (whitening a light pill is invisible).
        let hoverTintBase: NSColor
    }

    /// Whether the OS is currently in dark mode, read from the app's effective
    /// appearance (which tracks the system Appearance setting for our
    /// nil-appearance panels). Recomputed on each `show()` so a theme switch
    /// between two banners is honored.
    private static func isDarkNow() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// A caller-tinted pill (e.g. the red silent-transcription warning) supplies
    /// its own strong background color; treat only a (near-)transparent tint as
    /// "glass only", the case that must follow the OS theme.
    private static func isGlassOnly(_ bg: NSColor) -> Bool {
        let alpha = bg.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        return alpha < 0.05
    }

    private static func palette(isDark: Bool, glassOnly: Bool) -> Palette {
        // A colored pill defines its own look — white text + a white hover
        // highlight read on the current red in either OS theme, so only the
        // glass-only pill flips with the theme.
        guard glassOnly, !isDark else {
            return Palette(text: Style.textColor, hoverTintBase: .white)
        }
        // Light OS theme, glass-only pill: dark text, and hover *darkens*.
        return Palette(text: NSColor(calibratedWhite: 0.12, alpha: 1),
                       hoverTintBase: .black)
    }

    private let screensProvider: () -> [NSScreen]
    private let hoverable: Bool

    private struct PanelEntry {
        let panel: NSPanel
        /// The visible glass "pill" (left region of the panel). The panel itself
        /// is wider by `Style.arrowGutter` when an arrow shows, so the arrow can
        /// float in the transparent gutter to the pill's right. Glass width =
        /// `pill.frame.width`; panel width = pill + gutter.
        let pill: NSView
        let tint: NSView
        /// White overlay above the tint that ramps up during the hover
        /// dwell. Alpha 0 at rest, alpha 1 the instant `onHover` fires.
        let whitenTint: NSView
        /// Double-chevron in the top-right corner cueing the hover action
        /// direction (up = send/confirm, down = cancel). Hidden at rest.
        let arrow: CAShapeLayer
        /// Two orange stroke layers forming the progressive border, both
        /// starting at the bottom-left corner. `borderUp` runs up the left edge
        /// then across the top; `borderRight` runs along the bottom then up the
        /// right edge. Their `strokeEnd` tracks the countdown progress, so they
        /// meet at the top-right corner when the bar fills. Hidden at rest.
        let borderUp: CAShapeLayer
        let borderRight: CAShapeLayer
        let label: NSTextField
        /// Kept so `updateText` can re-measure and resize the box to hug the
        /// new text (still capped at `maxWidthFraction` of this screen).
        let font: NSFont
        let screen: NSScreen
    }
    private var panels: [PanelEntry] = []

    /// Fires once per `show()` after the cursor has *dwelled* inside the
    /// banner for at least `hoverDwellRequiredSamples × hoverDwellInterval`
    /// (0.5s by default). Cursor merely happening to be in the corner when
    /// the banner appears never fires this — NSTrackingArea only kicks in
    /// on a fresh entry, and even then the user must hold the cursor in
    /// place. Only meaningful when `hoverable: true`.
    var onHover: (() -> Void)?
    private var hoverFired = false

    private static let hoverDwellInterval: TimeInterval = 0.1
    // Hold-to-confirm dwell: 2.0s (was 1.0s) — +1s so a confirm is deliberate.
    private static let hoverDwellRequiredSamples = 20
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

    /// True when the pill is "glass only" (no strong caller tint) — i.e. the
    /// light/dark ("black/white") themed pill. In that case hovering does NOT
    /// tint the background at all; the up/down nudge alone is the feedback.
    /// A caller-colored pill (e.g. the red warning) still gets the hover tint.
    private var glassOnly = false

    /// Direction the pill drifts while the cursor dwells on it (see `HoverNudge`).
    /// Set per `show()`; `.none` disables the nudge (whitening only).
    private var hoverNudge: HoverNudge = .none

    /// Whether the send/cancel arrow shows for the current presentation — only on
    /// an actionable countdown banner with a nudge direction. Drives both the
    /// arrow itself and the extra gutter width the panel reserves on the right.
    private var arrowVisible: Bool {
        hoverable && onHover != nil && hasCountdown && hoverNudge != .none
    }

    /// Base color the hover-dwell overlay ramps up (see `Palette.hoverTintBase`).
    /// Resolved from the OS theme on each `show()`: white to lighten a dark pill,
    /// black to darken a light one.
    private var hoverTintBase: NSColor = .white

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
    /// `hoverCountdown`, when non-nil, drives the progressive orange border that
    /// grows around the pill over that many seconds, visualizing how long the
    /// banner can still be hovered to act. It only appears when the banner is
    /// hoverable with an active `onHover` (status/error flashes get none). Pass
    /// nil to clear any border from a previous show on a reused banner.
    ///
    /// `hoverNudge` also selects the top-right send/cancel arrow: `.up` shows an
    /// upward double-chevron (hover to send/confirm), `.down` a downward one
    /// (hover to cancel/put away), `.none` no arrow.
    func show(text: String,
              backgroundColor: NSColor = Style.defaultBackground,
              font: NSFont = Style.defaultFont(),
              hoverCountdown: TimeInterval? = nil,
              hoverNudge: HoverNudge = .none) {
        // Each show() presents new content → re-arm hover and clear any leftover
        // dwell whitening (e.g. after a previous fire on a banner being reused).
        cancelHoverDwell()
        hoverFired = false
        // Drives the 30% min width (panelWidth).
        hasCountdown = hoverCountdown != nil
        // Direction the pill drifts on dwell (up = confirm, down = cancel).
        self.hoverNudge = hoverNudge
        // A glass-only (light/dark themed) pill gets NO hover background tint —
        // only the nudge; a caller-colored pill still tints on hover.
        glassOnly = Self.isGlassOnly(backgroundColor)
        // Resolve the OS-theme palette for this presentation: a glass-only pill
        // flips (dark text on the light Mac theme), a colored pill keeps its look.
        let palette = Self.palette(isDark: Self.isDarkNow(), glassOnly: glassOnly)
        applyPalette(palette)
        if isVisible {
            updateText(text)
            updateBackgroundColor(backgroundColor)
            applyArrow(hoverNudge)
            applyHoverCountdown(hoverCountdown)
            return
        }
        for screen in screensProvider() {
            panels.append(buildPanel(on: screen,
                                     text: text,
                                     bg: backgroundColor,
                                     font: font,
                                     palette: palette))
        }
        for entry in panels {
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            for entry in panels { entry.panel.animator().alphaValue = Self.visibleAlpha }
        }
        applyArrow(hoverNudge)
        applyHoverCountdown(hoverCountdown)
    }

    /// Apply the resolved OS-theme `palette` to every panel: the main label color
    /// and the hover-tint base. Called from `show()` on both the fresh-build path
    /// (via `buildPanel`) and the reuse path (an already-visible banner re-shown
    /// after the user toggled the system theme picks up the new colors).
    private func applyPalette(_ palette: Palette) {
        hoverTintBase = palette.hoverTintBase
        for entry in panels {
            entry.label.textColor = palette.text
        }
    }

    func updateText(_ text: String) {
        for entry in panels {
            entry.label.stringValue = text
            resize(entry, to: panelWidth(for: text, font: entry.font, screen: entry.screen))
        }
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

    /// Resize a panel (anchored bottom-left) to hold a glass pill of `pillWidth`,
    /// in place. The panel gains `arrowGutter` on the right when an arrow shows so
    /// the arrow floats just outside the pill.
    private func resize(_ entry: PanelEntry, to pillWidth: CGFloat) {
        let panelWidth = pillWidth + (arrowVisible ? Style.arrowGutter : 0)
        guard abs(entry.panel.frame.width - panelWidth) > 0.5 else { return }
        let f = entry.screen.frame
        entry.panel.setFrame(NSRect(x: f.minX, y: f.minY, width: panelWidth, height: Style.boxHeight),
                             display: true)
        // The glass pill occupies the left region; its subviews autoresize with it.
        entry.pill.frame = NSRect(x: 0, y: 0, width: pillWidth, height: Style.boxHeight)
        entry.label.frame = Self.mainLabelFrame(pillWidth: pillWidth, font: entry.font)
        // Border host autoresizes within the pill, but its stroke paths are
        // absolute — rebuild them (and the gutter arrow) for the new width.
        updateBorderPaths(entry)
        updateArrowPath(entry)
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
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                for entry in toRemove { entry.panel.animator().alphaValue = 0 }
            }, completionHandler: {
                for entry in toRemove { entry.panel.orderOut(nil) }
            })
        } else {
            for entry in toRemove { entry.panel.orderOut(nil) }
        }
    }

    // MARK: - Outcome-flavored dismissals
    //
    // Every interactive banner ends one of two ways, and the exit animation
    // tells the user *which* — the direction matches the gesture:
    //   • dismissRisingFade — they ACCEPTED / COMMITTED a proposed action
    //     (confirm "send to notes", or let a paste stand). The pill lifts UP
    //     and fades, as if the content floated off into the notes.
    //   • dismissSinking — they CANCELLED an action that had already happened
    //     (hover-to-undo a paste). The pill slides straight DOWN off the bottom
    //     of the screen, as if rolled back / "put away" — the opposite of the
    //     rising "accept", so the motion alone reads as "undone".

    /// Dismiss by floating the pill (and any hint) straight up while fading to
    /// transparent over ~1s. The "accepted / committed" gesture.
    func dismissRisingFade() {
        guard isVisible else { return }
        cancelHoverDwell()
        clearHoverCountdown()
        let toRemove = panels
        panels.removeAll()
        let rise: CGFloat = 140
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for entry in toRemove {
                // Rise: the pill's ONLY *window-level* animation — matching the
                // flash-free `dismissSinking`. Animating the window's `alphaValue`
                // in the SAME group as its frame ran two window animations on two
                // different drivers that could desync for a frame, presenting the
                // window once at its final (raised) position at full opacity — a
                // "flash toward the top-left". Fade the CONTENT VIEW instead, so the
                // window itself only ever animates its frame (smoothly, like the
                // sink), and the fade rides along on the content layer.
                var f = entry.panel.frame
                f.origin.y += rise
                entry.panel.animator().setFrame(f, display: true)
                entry.panel.contentView?.animator().alphaValue = 0
            }
        }, completionHandler: {
            for entry in toRemove { entry.panel.orderOut(nil) }
        })
    }

    /// Dismiss by sliding the pill (and any hint) straight DOWN off the bottom
    /// of the screen — the "cancelled / rolled back" gesture, the mirror image of
    /// `dismissRisingFade`'s lift. The pill is anchored at the screen's bottom
    /// edge, so dropping it by a bit more than its own height carries it fully
    /// out of view; the downward motion alone reads as "undone — put back". No
    /// fade: it simply leaves the screen (accelerating with `.easeIn`, like
    /// being pulled back down), then the off-screen panels are torn down.
    func dismissSinking() {
        guard isVisible else { return }
        cancelHoverDwell()
        clearHoverCountdown()
        let toRemove = panels
        panels.removeAll()
        // The pill is anchored at the screen's bottom edge, so one drop distance —
        // a bit past the pill's height — carries it (and its in-pill band) fully
        // off-screen.
        let sink: CGFloat = Style.boxHeight + 60
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.7
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for entry in toRemove {
                var f = entry.panel.frame
                f.origin.y -= sink
                entry.panel.animator().setFrame(f, display: true)
            }
        }, completionHandler: {
            for entry in toRemove { entry.panel.orderOut(nil) }
        })
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
            applyDwellProgress(0)
        }
    }

    private func tickHoverDwell() {
        guard !hoverFired else { cancelHoverDwell(); return }
        if isMouseInsideAnyPanel() {
            hoverDwellCount += 1
            let progress = min(1.0, CGFloat(hoverDwellCount) / CGFloat(Self.hoverDwellRequiredSamples))
            applyDwellProgress(progress)
            if hoverDwellCount >= Self.hoverDwellRequiredSamples {
                hoverDwellTimer?.invalidate()
                hoverDwellTimer = nil
                fireHover()
            }
        } else if hoverDwellCount > 0 {
            hoverDwellCount = 0
            applyDwellProgress(0)
        }
    }

    /// Reflect the dwell `progress` (0…1) on every panel: ramp the "whitening"
    /// overlay and slide the pill slightly in the nudge direction. Both animate
    /// linearly over one dwell-tick interval so the effect feels continuous as
    /// the user holds the cursor in place, and both return to rest at progress 0.
    private func applyDwellProgress(_ progress: CGFloat) {
        applyWhitenProgress(progress)
        applyNudgeProgress(progress)
    }

    private func applyWhitenProgress(_ alpha: CGFloat) {
        // A glass-only (light/dark "black/white" themed) pill must NOT change its
        // background on hover — the up/down nudge alone is the feedback. Only a
        // caller-colored pill (e.g. the red warning) tints on hover.
        guard !glassOnly else { return }
        // `hoverTintBase` is white on the dark pill (lighten) and black on the
        // light one (darken) — whitening a light pill would be invisible.
        let cg = hoverTintBase.withAlphaComponent(alpha).cgColor
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

    /// Slide the pill (with its in-pill band) `progress × hoverNudgeDistance`
    /// points up (`.up`) or down (`.down`) from the resting bottom-left position —
    /// a subtle preview of which exit hovering triggers. No-op for `.none`. The
    /// resting y is always the screen's bottom edge, so progress 0 restores it
    /// exactly; the dismiss animations read the current (nudged) frame, so a
    /// fired hover continues smoothly into the rising/sinking exit.
    private func applyNudgeProgress(_ progress: CGFloat) {
        guard hoverNudge != .none else { return }
        let dir: CGFloat = hoverNudge == .up ? 1 : -1
        let dy = dir * Style.hoverNudgeDistance * progress
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.hoverDwellInterval
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            for entry in panels {
                var f = entry.panel.frame
                f.origin.y = entry.screen.frame.minY + dy
                entry.panel.animator().setFrame(f, display: true)
            }
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
        clearArrow()
        onHover?()
    }

    /// Show the top-right send/cancel double-chevron on every pill (up for
    /// `.up`/send, down for `.down`/cancel), or hide it (`.none`). Only on an
    /// actionable countdown banner — it replaces the old send/cancel hint label,
    /// which only those banners had. A persistent, label-free pill (e.g. the
    /// projected red silent-transcription warning) gets no arrow.
    private func applyArrow(_ nudge: HoverNudge) {
        clearArrow()
        guard hoverable, onHover != nil, hasCountdown, nudge != .none else { return }
        for entry in panels {
            entry.arrow.path = Self.arrowPath(pillWidth: entry.pill.frame.width, up: nudge == .up)
            entry.arrow.isHidden = false
            Self.startArrowMarch(entry.arrow, up: nudge == .up)
        }
    }

    /// Hide the arrow on every pill and stop its marching animation.
    private func clearArrow() {
        for entry in panels {
            entry.arrow.isHidden = true
            entry.arrow.removeAnimation(forKey: "march")
        }
    }

    /// Loop the arrow "marching" in its pointing direction: it slides
    /// `arrowSlideDistance` up (`up`) or down while fading out, then snaps back
    /// (invisibly, at opacity 0) and re-slides — repeated forever as a directional
    /// swipe hint. Translation + fade run as one grouped, infinitely repeating
    /// animation so the reset never flashes.
    private static func startArrowMarch(_ layer: CAShapeLayer, up: Bool) {
        let dir: CGFloat = up ? 1 : -1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 0
        slide.toValue = dir * Style.arrowSlideDistance
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]   // fade in, hold, fade out
        fade.keyTimes = [0.0, 0.2, 0.6, 1.0]
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Style.arrowSlideDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "march")
    }

    /// Rebuild the arrow path for a pill's current width (its X is pinned to the
    /// right edge), so a resize keeps it in the top-right corner. No-op while the
    /// arrow is hidden.
    private func updateArrowPath(_ entry: PanelEntry) {
        guard !entry.arrow.isHidden else { return }
        let up = hoverNudge == .up
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.arrow.path = Self.arrowPath(pillWidth: entry.pill.frame.width, up: up)
        CATransaction.commit()
    }

    /// The double-chevron path in the transparent gutter just to the right of the
    /// pill, vertically centered: two stacked arrowheads pointing up (`up`) or
    /// down. Built in the panel's (y-up) coordinates; `pillWidth` is the glass
    /// width, so the arrow starts `arrowGap` past the pill's right edge.
    private static func arrowPath(pillWidth: CGFloat, up: Bool) -> CGPath {
        let cw = Style.arrowChevronWidth
        let ch = Style.arrowChevronHeight
        let cg = Style.arrowChevronGap
        let xL = pillWidth + Style.arrowGap
        let xR = xL + cw
        let xMid = (xL + xR) / 2
        // Top of the two-chevron group, placed so the group is centered vertically.
        let groupH = 2 * ch + cg
        let yTop = (Style.boxHeight + groupH) / 2
        let path = CGMutablePath()
        for i in 0..<2 {                          // 0 = top chevron, 1 = bottom
            let bandTop = yTop - CGFloat(i) * (ch + cg)
            if up {                               // apex at the band top, arms down
                path.move(to: CGPoint(x: xL, y: bandTop - ch))
                path.addLine(to: CGPoint(x: xMid, y: bandTop))
                path.addLine(to: CGPoint(x: xR, y: bandTop - ch))
            } else {                              // arms at the band top, apex down
                path.move(to: CGPoint(x: xL, y: bandTop))
                path.addLine(to: CGPoint(x: xMid, y: bandTop - ch))
                path.addLine(to: CGPoint(x: xR, y: bandTop))
            }
        }
        return path
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
        for entry in panels {
            entry.borderUp.isHidden = false
            entry.borderRight.isHidden = false
            updateBorderPaths(entry)
            setBorderProgress(entry, 0)
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: Self.countdownTick, repeats: true) { [weak self] _ in
            self?.tickCountdown()
        }
    }

    private func tickCountdown() {
        // The defining behavior: pause while the cursor is on the pill. Elapsed
        // time (and therefore the border) only advances when the user is away.
        if !isMouseInsideAnyPanel() {
            countdownElapsed += Self.countdownTick
        }
        let progress = countdownDuration > 0 ? min(1.0, countdownElapsed / countdownDuration) : 1.0
        for entry in panels {
            // Both border strokes reach the top-right corner exactly as the
            // countdown completes.
            setBorderProgress(entry, CGFloat(progress))
        }
        if countdownElapsed >= countdownDuration {
            countdownTimer?.invalidate(); countdownTimer = nil
            onHoverCountdownExpired?()
        }
    }

    /// The two equal-length border paths for a pill of `width` × `height`, both
    /// starting at the bottom-left corner (inset by half the stroke so the 2px
    /// line stays inside the pill):
    ///   • `up`    — up the left edge, then across the top to the top-right corner.
    ///   • `right` — along the bottom edge, then up the right edge to the same corner.
    /// Both have length (width - 2·inset) + (height - 2·inset), so a shared
    /// `strokeEnd` (the countdown progress) draws equal arc-length on each and
    /// they converge at the top-right corner together.
    private static func borderPaths(width w: CGFloat, height h: CGFloat) -> (up: CGPath, right: CGPath) {
        let inset = Style.borderWidth / 2
        let left = inset, right = w - inset, bottom = inset, top = h - inset
        let up = CGMutablePath()
        up.move(to: CGPoint(x: left, y: bottom))
        up.addLine(to: CGPoint(x: left, y: top))
        up.addLine(to: CGPoint(x: right, y: top))
        let rightP = CGMutablePath()
        rightP.move(to: CGPoint(x: left, y: bottom))
        rightP.addLine(to: CGPoint(x: right, y: bottom))
        rightP.addLine(to: CGPoint(x: right, y: top))
        return (up, rightP)
    }

    /// A hidden, unfilled orange stroke layer for one border path, starting at
    /// `strokeEnd = 0` (nothing drawn until the countdown advances it).
    private static func makeBorderLayer(path: CGPath) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = Style.borderColor.cgColor
        layer.lineWidth = Style.borderWidth
        layer.lineJoin = .miter
        layer.lineCap = .butt
        layer.strokeEnd = 0
        layer.isHidden = true
        return layer
    }

    /// Rebuild both border layers' paths for the panel's current width (called on
    /// countdown start and on resize, so an in-flight border tracks the new size).
    private func updateBorderPaths(_ entry: PanelEntry) {
        let (up, right) = Self.borderPaths(width: entry.pill.frame.width, height: Style.boxHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.borderUp.path = up
        entry.borderRight.path = right
        CATransaction.commit()
    }

    /// Reveal `p` (0…1) of both border strokes, without the implicit stroke
    /// animation, so the border freezes instantly with the bar when the cursor
    /// lands on the pill.
    private func setBorderProgress(_ entry: PanelEntry, _ p: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.borderUp.strokeEnd = p
        entry.borderRight.strokeEnd = p
        CATransaction.commit()
    }

    /// Stop the countdown and hide the progressive border on every panel. Called
    /// on each show() (so a reused banner never shows a stale border), on
    /// dismiss(), and by callers once the window closes another way (e.g. a
    /// countdown overlay reaching 0).
    func clearHoverCountdown() {
        countdownTimer?.invalidate(); countdownTimer = nil
        countdownElapsed = 0
        for entry in panels {
            setBorderProgress(entry, 0)
            entry.borderUp.isHidden = true
            entry.borderRight.isHidden = true
        }
    }


    private func buildPanel(on screen: NSScreen,
                            text: String,
                            bg: NSColor,
                            font: NSFont,
                            palette: Palette) -> PanelEntry {
        let frame = screen.frame
        let pillWidth = panelWidth(for: text, font: font, screen: screen)
        // The panel is wider than the glass pill by the arrow gutter (when an
        // arrow shows), so the arrow can float in the transparent space to the
        // pill's right. The glass/tint/border/label live in the `pill` subview.
        let panelWidthTotal = pillWidth + (arrowVisible ? Style.arrowGutter : 0)
        let rect = NSRect(x: frame.minX, y: frame.minY, width: panelWidthTotal, height: Style.boxHeight)
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

        // The visible glass pill: the left region of the panel. Everything but the
        // arrow lives inside it and autoresizes with it.
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: Style.boxHeight))
        pill.wantsLayer = true
        content.addSubview(pill)

        let effect = NSVisualEffectView(frame: pill.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        pill.addSubview(effect)

        let tint = NSView(frame: pill.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.cgColor
        pill.addSubview(tint)

        let whitenTint = NSView(frame: pill.bounds)
        whitenTint.autoresizingMask = [.width, .height]
        whitenTint.wantsLayer = true
        // Fully transparent at rest (the base color only matters once dwell
        // ramps its alpha up); `hoverTintBase` was set from the palette in show().
        whitenTint.layer?.backgroundColor = hoverTintBase.withAlphaComponent(0).cgColor
        pill.addSubview(whitenTint)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = palette.text
        label.alignment = .left
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = Self.mainLabelFrame(pillWidth: pillWidth, font: font)
        label.autoresizingMask = [.width]
        pill.addSubview(label)

        // Progressive border: a transparent overlay view (topmost in the pill so
        // the strokes sit above the glass/tint/label) hosting the two orange
        // stroke layers. The strokes' `path` is rebuilt on resize; their
        // `strokeEnd` tracks the countdown. `masksToBounds` stays off so the
        // stroke renders fully.
        let borderHost = NSView(frame: pill.bounds)
        borderHost.wantsLayer = true
        borderHost.autoresizingMask = [.width, .height]
        let (upPath, rightPath) = Self.borderPaths(width: pillWidth, height: Style.boxHeight)
        let borderUp = Self.makeBorderLayer(path: upPath)
        let borderRight = Self.makeBorderLayer(path: rightPath)
        borderHost.layer?.addSublayer(borderUp)
        borderHost.layer?.addSublayer(borderRight)
        pill.addSubview(borderHost)

        // Send/cancel arrow: a sublayer of the full-width content (NOT the pill),
        // so it draws in the transparent gutter to the pill's right. Its path is
        // set/animated by applyArrow once the nudge direction is known.
        let arrow = Self.makeArrowLayer()
        arrow.path = Self.arrowPath(pillWidth: pillWidth, up: hoverNudge == .up)
        content.layer?.addSublayer(arrow)

        panel.contentView = content
        return PanelEntry(panel: panel, pill: pill, tint: tint, whitenTint: whitenTint,
                          arrow: arrow,
                          borderUp: borderUp, borderRight: borderRight,
                          label: label,
                          font: font, screen: screen)
    }

    /// A hidden, orange double-chevron stroke layer for the top-right arrow. Its
    /// `path` is set by `applyArrow`/`updateArrowPath` once the nudge direction
    /// and pill width are known. A subtle dark shadow keeps it legible on any
    /// backdrop showing through the translucent glass.
    private static func makeArrowLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = Style.arrowColor.cgColor
        layer.lineWidth = Style.arrowLineWidth
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = 1.5
        layer.shadowOpacity = 0.6
        layer.shadowOffset = .zero
        layer.isHidden = true
        return layer
    }

    /// Main-text frame: left-aligned, vertically centered in the **whole** pill.
    /// The label height is the text's own line height (not a fixed slab), so the
    /// single-line text — which AppKit draws from the top of the field — fills the
    /// field exactly and therefore sits centered in the box. We take the max of the
    /// given font's line height and the emoji font's (emoji is taller), so an
    /// emoji-bearing line neither clips nor throws off the centering. Shared by
    /// build + resize.
    private static func mainLabelFrame(pillWidth: CGFloat, font: NSFont) -> NSRect {
        let lm = NSLayoutManager()
        var h = lm.defaultLineHeight(for: font)
        if let emoji = NSFont(name: "AppleColorEmoji", size: font.pointSize) {
            h = max(h, lm.defaultLineHeight(for: emoji))
        }
        h = ceil(h)
        return NSRect(
            x: Style.leftPadding,
            y: (Style.boxHeight - h) / 2,
            width: pillWidth - Style.leftPadding - Style.rightPadding,
            height: h)
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
