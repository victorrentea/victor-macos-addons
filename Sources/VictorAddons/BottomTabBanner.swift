import Cocoa

/// A **bottom-center tab header**: a pill with rounded *top* corners that sits
/// flush on the screen's bottom edge, sneaks up from below, holds for a few
/// seconds and falls back down off screen.
///
/// The third bottom-edge primitive in the app, and deliberately not a variant of
/// the other two:
///   • `BottomLeftBanner` is the *corner* pill — left-anchored, entering with a
///     horizontal wipe, persistent, dismissed by hovering it. It is the surface
///     for things Victor must act on (send / undo / acknowledge).
///   • `JoinLinkBanner` is the standing, room-wide join-instructions strip.
///   • **This** is the transient *announcement*: it names who just did something
///     and then gets out of the way on its own. Nothing to hover, nothing to
///     dismiss, no decision attached — which is exactly why it may sit in the
///     middle, where the eye already is, instead of hiding in a corner.
///
/// **Why the window never moves.** The tab slides *inside* a fixed panel whose
/// frame is exactly the tab's resting rectangle, and the panel's content view
/// clips it. A window that walks below its screen's bottom edge is not gone — on
/// a multi-display arrangement where another monitor sits under (or above) this
/// one, those pixels are drawn on the neighbour. `PillPlacement` documents the
/// same bug biting the sinking exit of `BottomLeftBanner`. Here the rule is
/// simpler because the motion is only ever vertical and only ever downward-out:
/// the window is nailed to the screen, the tab moves within it, and not one
/// pixel can land on another display.
final class BottomTabBanner {

    enum Style {
        /// Tall enough to read across a room from a projector, short enough that
        /// it never covers the bottom line of a slide.
        static let tabHeight: CGFloat = 76
        /// Only the top corners are rounded — the bottom edge IS the screen edge,
        /// which is what makes it read as a tab rather than a floating pill.
        static let cornerRadius: CGFloat = 18
        static let fontSize: CGFloat = 40
        static let horizontalPadding: CGFloat = 34
        /// Keeps a one-word tab from looking like a stub.
        static let minWidth: CGFloat = 220
        /// A runaway list of names must not span the whole screen.
        static let maxWidthFraction: CGFloat = 0.6

        static let textColor: NSColor = .white
        static func defaultFont() -> NSFont { NSFont.boldSystemFont(ofSize: fontSize) }

        /// Final window opacity — slightly see-through, like the other banners,
        /// so it lies *on* the slide rather than punching a hole in it.
        static let visibleAlpha: CGFloat = 0.92

        // MARK: Motion
        /// Rising is quicker than falling: the arrival is the information, the
        /// departure is just tidying up.
        static let riseDuration: TimeInterval = 0.32
        static let fallDuration: TimeInterval = 0.45
        /// How long the tab stays fully up before it leaves on its own.
        static let holdDuration: TimeInterval = 3.0
        static let frameInterval: TimeInterval = 1.0 / 60.0
    }

    // MARK: - Pure geometry & timing
    //
    // Everything that decides *where* and *how far* is a static pure function so
    // it can be unit-tested headlessly — the rendering below is then only
    // plumbing, which is the part a screenshot check covers.

    /// The tab's width for a measured `textWidth`: hug the text with padding on
    /// both sides, never narrower than `minWidth`, never wider than
    /// `maxWidthFraction` of the screen.
    static func tabWidth(textWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let hugging = ceil(textWidth) + 2 * Style.horizontalPadding
        let capped = min(hugging, screenWidth * Style.maxWidthFraction)
        return max(Style.minWidth, capped)
    }

    /// Left edge of a `width`-wide tab centred on a screen spanning
    /// `[screenMinX, screenMinX + screenWidth)`. Rounded so the glass does not
    /// land on a half pixel and blur the text.
    static func originX(tabWidth width: CGFloat, screenMinX: CGFloat, screenWidth: CGFloat) -> CGFloat {
        screenMinX + ((screenWidth - width) / 2).rounded()
    }

    /// Vertical offset of the tab inside its panel at `progress` ∈ [0, 1] of a
    /// transition, in points: `0` is fully up (resting, flush with the bottom
    /// edge), `-tabHeight` is fully hidden below it.
    ///
    /// Rising decelerates (easeOut) so the tab *arrives* rather than slams;
    /// falling accelerates (easeIn) so it drops away. Both curves are the plain
    /// quadratics already used by `BottomLeftBanner`'s exits.
    static func slideOffset(progress: Double, rising: Bool, height: CGFloat = Style.tabHeight) -> CGFloat {
        let p = min(1, max(0, progress))
        let eased = rising ? 1 - (1 - p) * (1 - p) : p * p
        let hiddenFraction = rising ? 1 - eased : eased
        return -height * CGFloat(hiddenFraction)
    }

    // MARK: - State

    private let screensProvider: () -> [NSScreen]

    private struct PanelEntry {
        let panel: NSPanel
        /// The visible tab, sliding vertically inside the (clipping) content view.
        let tab: NSView
        let tint: NSView
        let label: NSTextField
        let font: NSFont
        let screen: NSScreen
    }
    private var panels: [PanelEntry] = []

    /// Fires once the tab has fully left the screen and its panels are gone —
    /// whether it left on its own timer or via `dismiss()`. Lets the owner
    /// (e.g. `BellCard`) forget the state it was displaying.
    var onDismissed: (() -> Void)?

    private var motionTimer: Timer?
    private var holdTimer: Timer?

    init(screensProvider: @escaping () -> [NSScreen]) {
        self.screensProvider = screensProvider
    }

    var isVisible: Bool { !panels.isEmpty }

    // MARK: - Showing

    /// Show (or refresh) the tab with `text`, tinted `backgroundColor`, for
    /// `hold` seconds.
    ///
    /// Calling it while the tab is already up does **not** replay the entrance:
    /// the text is swapped, the tab re-measured and re-centred around the new
    /// text, and the hold timer restarted. That is what makes a second bell
    /// arriving mid-hold widen the same tab instead of making it flicker.
    func show(text: String,
              backgroundColor: NSColor,
              font: NSFont = Style.defaultFont(),
              hold: TimeInterval = Style.holdDuration) {
        if isVisible {
            updateText(text)
            updateTint(backgroundColor)
            startHold(hold)
            return
        }
        for screen in screensProvider() {
            panels.append(buildPanel(on: screen, text: text, bg: backgroundColor, font: font))
        }
        guard isVisible else { return }   // headless (no screens): nothing to animate
        for entry in panels {
            entry.panel.alphaValue = Style.visibleAlpha
            entry.panel.orderFrontRegardless()
        }
        animate(rising: true, duration: Style.riseDuration) { [weak self] in
            self?.startHold(hold)
        }
    }

    /// Swap the text, re-measuring so the tab hugs it and stays centred.
    func updateText(_ text: String) {
        for entry in panels {
            entry.label.stringValue = text
            let width = Self.tabWidth(textWidth: Self.measure(text, font: entry.font),
                                      screenWidth: entry.screen.frame.width)
            resize(entry, to: width)
        }
    }

    private func updateTint(_ color: NSColor) {
        for entry in panels {
            entry.tint.layer?.backgroundColor = color.cgColor
        }
    }

    /// Re-centre and re-width a live tab. The panel keeps its full-height frame
    /// pinned to the screen's bottom edge; only x and width change, so a resize
    /// mid-slide cannot knock the tab out of its vertical animation.
    private func resize(_ entry: PanelEntry, to width: CGFloat) {
        let f = entry.screen.frame
        let x = Self.originX(tabWidth: width, screenMinX: f.minX, screenWidth: f.width)
        let dy = entry.tab.frame.origin.y   // preserve the current slide position
        entry.panel.setFrame(NSRect(x: x, y: f.minY, width: width, height: Style.tabHeight),
                             display: true)
        entry.panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: Style.tabHeight)
        entry.tab.frame = NSRect(x: 0, y: dy, width: width, height: Style.tabHeight)
        entry.label.frame = Self.labelFrame(tabWidth: width, font: entry.font)
    }

    // MARK: - Dismissing

    /// Slide the tab down off the screen and tear the panels down. Safe to call
    /// when nothing is showing: it then just fires `onDismissed`, so an owner
    /// that mirrors the tab's state (`BellCard`'s caller list) ends up consistent
    /// whether or not anything was ever rendered — which is also what makes the
    /// state testable headlessly, where there are no screens to build panels on.
    func dismiss() {
        holdTimer?.invalidate(); holdTimer = nil
        guard isVisible else { teardown(); return }
        animate(rising: false, duration: Style.fallDuration) { [weak self] in
            self?.teardown()
        }
    }

    private func startHold(_ hold: TimeInterval) {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func teardown() {
        for entry in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        onDismissed?()
    }

    // MARK: - Motion

    /// Drive every panel's tab from wherever it is to the end of a `rising` or
    /// falling transition, at 60 fps on the common run-loop modes (so the slide
    /// does not freeze while a menu is open).
    private func animate(rising: Bool, duration: TimeInterval, completion: @escaping () -> Void) {
        motionTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: Style.frameInterval, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            let progress = min(1.0, Date().timeIntervalSince(start) / duration)
            let dy = Self.slideOffset(progress: progress, rising: rising)
            for entry in self.panels {
                entry.tab.frame.origin.y = dy
            }
            if progress >= 1.0 {
                tm.invalidate()
                self.motionTimer = nil
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
        timer.fire()   // place the tab at its start offset before the first frame
    }

    // MARK: - Building

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        let probe = NSTextField(labelWithString: text)
        probe.font = font
        probe.sizeToFit()
        return probe.frame.width
    }

    /// The label's rectangle inside a `tabWidth`-wide tab: full width minus the
    /// padding, vertically centred using the taller of the text and emoji line
    /// heights (the 🔔 is an emoji glyph and sets the line box).
    static func labelFrame(tabWidth: CGFloat, font: NSFont) -> NSRect {
        let lm = NSLayoutManager()
        var h = lm.defaultLineHeight(for: font)
        if let emoji = NSFont(name: "AppleColorEmoji", size: font.pointSize) {
            h = max(h, lm.defaultLineHeight(for: emoji))
        }
        h = ceil(h)
        return NSRect(x: Style.horizontalPadding,
                      y: (Style.tabHeight - h) / 2,
                      width: tabWidth - 2 * Style.horizontalPadding,
                      height: h)
    }

    private func buildPanel(on screen: NSScreen, text: String, bg: NSColor, font: NSFont) -> PanelEntry {
        let f = screen.frame
        let width = Self.tabWidth(textWidth: Self.measure(text, font: font), screenWidth: f.width)
        let rect = NSRect(x: Self.originX(tabWidth: width, screenMinX: f.minX, screenWidth: f.width),
                          y: f.minY,
                          width: width,
                          height: Style.tabHeight)

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
        // Purely informational: never eat a click meant for the slide behind it.
        panel.ignoresMouseEvents = true

        // The clipping frame the tab slides inside — this is what keeps the
        // motion from ever painting on a neighbouring display.
        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        content.layer?.masksToBounds = true

        // Start fully hidden below the edge; `animate(rising:)` brings it up.
        let tab = NSView(frame: NSRect(x: 0, y: -Style.tabHeight, width: width, height: Style.tabHeight))
        tab.wantsLayer = true
        tab.layer?.cornerRadius = Style.cornerRadius
        // Top corners only — in AppKit's unflipped layer geometry, MaxY is up.
        tab.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        tab.layer?.masksToBounds = true
        content.addSubview(tab)

        let effect = NSVisualEffectView(frame: tab.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        tab.addSubview(effect)

        let tint = NSView(frame: tab.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.cgColor
        tab.addSubview(tint)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = Style.textColor
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = Self.labelFrame(tabWidth: width, font: font)
        label.autoresizingMask = [.width]
        tab.addSubview(label)

        panel.contentView = content
        return PanelEntry(panel: panel, tab: tab, tint: tint, label: label, font: font, screen: screen)
    }
}
