import AppKit
import ScreenCaptureKit

/// 🔎 ⌥⇧+scroll — a full-screen zoom that a Zoom screen share **carries**.
///
/// macOS's own magnifier (⌥+scroll) is applied at scanout, after the frame every
/// capture client reads, so the people on the call see the plain desktop while the
/// room sees it magnified (`docs/displays-projector.md` has the measurements). This
/// does the magnification **inside a window**: the display is captured live through
/// ScreenCaptureKit, *minus this window*, and drawn back enlarged over the whole
/// screen. An ordinary window is exactly what a share shows, so the far end sees what
/// the room sees — the 🔍 Pink Panther glass (tile #6 in `victor-effects`) made the
/// same trade, at 4 fps and inside a lens.
///
/// - **It behaves like the system magnifier in edge-panning mode**: the picture stays
///   put while the pointer moves inside it and pans only when the pointer pushes an
///   edge (`ShareZoomPolicy.pan`); zooming is about the pointer.
/// - **Input is never remapped.** The window is click-through; the hardware cursor is
///   hidden and a magnified copy of it is drawn where its desktop point appears on the
///   glass, so a click lands on what the drawn cursor is over. The drawn cursor is in
///   the window, so the share carries it too.
/// - **One display at a time** — the one under the pointer when the zoom starts.
///   ⌥⇧+scroll on another display moves the zoom there.
///
/// **Startup cost** (measured 2026-10-01, ~195 ms in the first build): ~100 ms asking
/// ScreenCaptureKit for its window list, ~95 ms until the stream's first frame. The
/// first half is paid ahead of time — one `Stage` per display, panel and filter built
/// a few seconds after launch — and the stream **lingers 10 s** after a zoom-out, so
/// zooming straight back in is instant.
///
/// Main thread only, except the frame callback, which hops to main.
final class ShareZoom: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Everything one display needs, built before it is needed.
    private final class Stage {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
        let name: String
        let panel: NSPanel
        let image = CALayer()
        let cursor = CALayer()
        /// 🔍 in the top-right corner while zoomed, so anyone looking — the room or
        /// the call — can tell this is our zoom and not the system one (Victor,
        /// 2026-10-15). Never magnified: it sits over the picture, not in it.
        let badge = CALayer()
        /// A ⊕/⊖ magnifier riding at the drawn cursor's lower right, like a tooltip —
        /// the corner one is out of sight when the eyes are on the pointer (Victor,
        /// 2026-10-17). Since 2026-10-26 only while the zoom changes: it shows which
        /// way the wheel just turned and is gone `tipLinger` after the last notch.
        /// Constant size, never magnified.
        let tip = CALayer()
        static let tipSide: CGFloat = 40
        let tipIn: CGImage?
        let tipOut: CGImage?
        var filter: SCContentFilter?
        /// Whether the filter really excludes our panel. If it does not, the stream
        /// would film its own output; the filter is rebuilt once the panel is on screen.
        var excludesOwnWindow = false
        /// Victor Effects' windows the filter leaves out (see `isEffectsWindow`).
        var excludedEffects: Set<CGWindowID> = []
        /// Effects windows a listing was already asked about. One that ScreenCaptureKit
        /// never lists would otherwise re-run the listing 8× a second for the whole zoom.
        var askedAbout: Set<CGWindowID> = []

        init(screen: NSScreen, displayID: CGDirectDisplayID) {
            self.displayID = displayID
            frame = screen.frame
            scale = screen.backingScaleFactor
            name = screen.localizedName
            panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            // Above the menu bar, the Dock and pop-up menus: everything the stream
            // captures has to end up *under* its own magnified picture.
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let noAnimation: [String: CAAction] = ["contents": NSNull(), "contentsRect": NSNull(),
                                                   "bounds": NSNull(), "position": NSNull(),
                                                   "hidden": NSNull()]
            image.frame = view.bounds
            image.contentsGravity = .resize
            image.actions = noAnimation
            cursor.contentsGravity = .resize
            cursor.magnificationFilter = .linear
            cursor.actions = noAnimation
            cursor.isHidden = true
            let side: CGFloat = 104, margin: CGFloat = 16  // 26 pt was too small to notice (Victor, 2026-10-15)
            badge.frame = CGRect(x: screen.frame.width - side - margin, y: screen.frame.height - side - margin,
                                 width: side, height: side)
            badge.contents = Self.emojiImage("🔍", side: side, scale: screen.backingScaleFactor)
            badge.contentsGravity = .resizeAspect
            badge.opacity = 0.5
            badge.actions = noAnimation
            tip.frame = CGRect(x: 0, y: 0, width: Self.tipSide, height: Self.tipSide)
            tipIn = Self.symbolImage("plus.magnifyingglass", side: Self.tipSide, scale: screen.backingScaleFactor)
            tipOut = Self.symbolImage("minus.magnifyingglass", side: Self.tipSide, scale: screen.backingScaleFactor)
            tip.contents = tipIn
            tip.contentsGravity = .resizeAspect
            tip.opacity = 0.9
            tip.actions = noAnimation
            tip.isHidden = true
            view.layer?.addSublayer(image)
            view.layer?.addSublayer(badge)
            view.layer?.addSublayer(cursor)
            view.layer?.addSublayer(tip)
            panel.contentView = view
        }

        /// An SF Symbol in white on a dark disc, so it reads over any picture.
        static func symbolImage(_ name: String, side: CGFloat, scale: CGFloat) -> CGImage? {
            let px = Int(side * scale)
            let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config),
                  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let size = symbol.size
            symbol.draw(in: CGRect(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2,
                                   width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }

        static func emojiImage(_ emoji: String, side: CGFloat, scale: CGFloat) -> CGImage? {
            let px = Int(side * scale)
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(px) * 0.8)])
            let size = text.size()
            text.draw(at: CGPoint(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
    }

    private var stages: [CGDirectDisplayID: Stage] = [:]
    /// The stage on screen right now.
    private var active: Stage?
    /// The stage the stream is feeding — the active one, or the last one while it lingers.
    private var streamStage: Stage?
    private var stream: SCStream?
    private var lingerStop: DispatchWorkItem?
    private static let linger: TimeInterval = 10

    private var tick: Timer?
    private var tickCount = 0
    private var target: CGFloat = 1
    private var current: CGFloat = 1
    /// Origin of the visible slice, in the active screen's own points.
    private var origin = CGPoint.zero
    /// The first frame has landed and the panel is showing.
    private var visible = false
    /// How many hides are outstanding (see `hideCursor`).
    private var hideDepth = 0
    private var cursorHidden: Bool { hideDepth > 0 }
    /// Until when the hide is re-asserted, after the pointer touched a screen edge.
    private var reassertUntil: CFAbsoluteTime = 0
    /// Times the real cursor was found visible mid-zoom and hidden again, this zoom.
    /// ScreenBrush does it: entering its drawing mode it finds the cursor hidden and
    /// shows it (it imports `CGCursorIsVisible` + `CGDisplayShowCursor`), so the room
    /// saw its brush cursor beside the drawn one (Victor, 2026-10-26).
    private var rehides = 0
    private static let maxRehides = 200
    /// Which way the wheel last turned, and until when the ⊕/⊖ tip shows it.
    private var zoomingIn = true
    private var tipUntil: CFAbsoluteTime = 0
    private static let tipLinger: CFTimeInterval = 0.5
    private var hotSpot = CGPoint.zero
    /// The system cursor's own size, in points. Kept here and never read back from
    /// the layer: the layer's bounds are the *magnified* size after the first frame,
    /// and reading them back compounded the factor on every tick (k, k², k³…) until
    /// the next shape refresh reset it — the cursor pulsed small/big (2026-10-01).
    private var cursorSize = CGSize.zero
    /// A focus point pinned by `/test/share-zoom?x=&y=` (global Cocoa points), so the
    /// zoom can be exercised on the right-hand screen without taking the mouse. While
    /// pinned, the real cursor is left alone.
    private var pinnedFocus: CGPoint?

    /// The drawn cursor's last published position (global Cocoa points) and when.
    private var publishedCursor: CGPoint?
    private var publishedAt: CFAbsoluteTime = 0

    private var framesShown = 0
    /// Layer commits by `follow` since the zoom started — `/test/share-zoom` shows
    /// whether the zoom rests when nothing moves.
    private var commits = 0
    private struct Written: Equatable { var rect: CGRect; var cursor: CGRect?; var tipIn: Bool? }
    private var lastWritten: Written?
    /// Capture rate; `/test/share-zoom?fps=` changes it for the next stream. 30, not
    /// 60, since 2026-10-15: panning and the drawn cursor move by `contentsRect` and
    /// never wait for a frame, so only a *change on screen* reaches the zoom at 30 —
    /// and the Retina hands this stream ~57 identical frames/s while the 🪞 silhouette
    /// repaints, each one a composite WindowServer renders for nothing.
    private var captureFPS: Int32 = 30
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var lastStartupMs = 0
    private let frameQueue = DispatchQueue(label: "ShareZoom.frames", qos: .userInteractive)

    /// The newest frame not yet on the layer, handed from `frameQueue` to main. One
    /// hop to main at a time, whatever the frame rate: a hop per frame queued 60
    /// closures a second behind whatever main was doing, each pinning an IOSurface
    /// the stream wanted back — the picture fell behind the pointer (2026-10-15).
    private let pendingLock = NSLock()
    /// Frame-queue only.
    private lazy var echo = EchoGate(queue: frameQueue) { [weak self] surface in
        self?.present(surface, from: self?.liveStream)
    }
    /// The stream frames are presented for, readable on `frameQueue` (set there).
    private var liveStream: SCStream?
    private var pendingSurface: IOSurface?

    /// `NSCursor.currentSystem` is a synchronous WindowServer round trip: **8 ms
    /// median, 17 ms p90** measured on 2026-10-15 with WindowServer at ~95 % (four
    /// screens, Zoom sharing, 🪞 Virtual Desktop). Read on main 20×/s it ate a fifth
    /// of the main thread and stalled the 120 Hz easing — "laggy", "hung halfway".
    /// Read here instead, one at a time.
    private let cursorQueue = DispatchQueue(label: "ShareZoom.cursor", qos: .userInitiated)
    /// Accessibility → Display → Pointer size (`mouseDriverCursorSize`), read at each zoom start.
    private var pointerScale: CGFloat = 1
    private var cursorReadInFlight = false

    var isActive: Bool { active != nil }

    /// Windows another feature puts **above** this zoom, which the zoom must not film
    /// or they would show twice, once magnified: 🪞 `VirtualDesktop`'s silhouette.
    var alsoExcluded: () -> [CGWindowID] = { [] }

    /// **Every** window of Victor Effects. They all sit at `maximumWindow` ± 2, far
    /// above this zoom's `.screenSaver`, so each one is already drawn unmagnified
    /// over the zoomed picture — the effect at the size it has unzoomed. Filmed as
    /// well, it showed twice: once live on top, once magnified behind it (Victor,
    /// 2026-10-16: the 💀 skull boom "duplicated"). Until then only the 💬 subtitle
    /// window was left out, by title. Matched by bundle id, not name or window id:
    /// the effects app makes panels on demand (the green edge flash, a fresh one per
    /// flash), and a restart renumbers them all — `watchEffectsWindows` catches both.
    static let effectsBundleID = "ro.victorrentea.victor-effects"

    static func isEffectsWindow(_ w: SCWindow) -> Bool {
        w.owningApplication?.bundleIdentifier == effectsBundleID
    }

    /// Rebuild the filters after `alsoExcluded` changed. A live stream picks it up at once.
    func refreshExclusions() {
        prepareStages()
    }

    override init() {
        super.init()
        // A display plugged, unplugged or rearranged invalidates every frame and
        // stream size at once: drop it all and prepare again once things settle.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.deactivate()
            self.stopStream()
            self.stages.values.forEach { $0.panel.orderOut(nil) }
            self.stages = [:]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.prepareStages() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.prepareStages() }
        // A Victor Effects deploy between two zooms renumbers its windows: without a
        // fresh listing the next zoom would film them all again — the first demo after
        // every deploy. 2 s lets its overlay and caption panels come up first.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.effectsBundleID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.prepareStages() }
        }
    }

    // MARK: - Gesture

    /// One ⌥⇧+scroll event, already reversed (`ScrollReversal`). Main thread.
    func scroll(delta: Double, source: ShareZoomPolicy.Source) {
        let mouse = NSEvent.mouseLocation
        guard let under = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        pinnedFocus = nil
        if let active, active.displayID != under.displayID {
            // Moving the zoom to another display keeps the factor it had.
            let keep = target
            deactivate()
            target = keep
        }
        target = ShareZoomPolicy.step(target, delta: delta, source: source)
        let notches = ShareZoomPolicy.notches(delta: delta, source: source)
        if notches != 0 { flashTip(zoomingIn: notches > 0) }
        if target > 1, active == nil { activate(on: under) }
        // `follow` is what switches a finished zoom off, and it waits for the first
        // frame. A zoom scrolled back to 1× before any frame arrived would otherwise
        // stay armed — an invisible panel and a running stream nobody can end.
        if target <= 1, active != nil, !visible { deactivate() }
    }

    /// `/test/share-zoom`: set the factor directly, optionally pinning the focus point.
    func testSet(fps: Int32) {
        guard fps > 0, fps != captureFPS else { return }
        captureFPS = fps
        if active == nil { stopStream() }
    }

    func testSet(factor: CGFloat, focus: CGPoint?) -> String {
        let point = focus ?? NSEvent.mouseLocation
        if factor <= 1 {
            deactivate()
        } else if let under = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            if let active, active.displayID != under.displayID { deactivate() }
            let next = min(factor, ShareZoomPolicy.maxFactor)
            if next != target { flashTip(zoomingIn: next > target) }
            target = next
            pinnedFocus = focus
            if active == nil { activate(on: under) }
        }
        return snapshotJSON()
    }

    /// The ⊕/⊖ tip at the cursor, for `tipLinger` from now.
    private func flashTip(zoomingIn: Bool) {
        self.zoomingIn = zoomingIn
        tipUntil = CFAbsoluteTimeGetCurrent() + Self.tipLinger
    }

    /// 🔍 Back to 1× — the other `ZoomEngine` was just chosen.
    func end() {
        guard active != nil else { return }
        deactivate()
    }

    private func echoJSON() -> String {
        "\"echo\":" + frameQueue.sync { echo.json }
    }

    func snapshotJSON() -> String {
        let frame = active?.frame ?? .zero
        let rect = active?.image.contentsRect ?? .zero
        let prepared = stages.values
            .map { "\"\($0.name)\":\($0.filter != nil && $0.excludesOwnWindow)" }
            .joined(separator: ",")
        let effectsExcluded = stages.values
            .map { "\"\($0.name)\":\($0.excludedEffects.count)" }
            .joined(separator: ",")
        return """
        {"active":\(isActive),"visible":\(visible),"target":\(String(format: "%.3f", target)),\
        "current":\(String(format: "%.3f", current)),"framesShown":\(framesShown),\
        "screen":"\(active?.name ?? "")",\
        "screenFrame":[\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))],\
        "contentsRect":[\(String(format: "%.4f,%.4f,%.4f,%.4f", rect.minX, rect.minY, rect.width, rect.height))],\
        "cursorFrame":[\(Int(active?.cursor.frame.width ?? 0)),\(Int(active?.cursor.frame.height ?? 0))],\
        "streaming":\(stream != nil),"cursorHidden":\(cursorHidden),"hideDepth":\(hideDepth),"rehides":\(rehides),"prepared":{\(prepared)},\
        "effectsExcluded":{\(effectsExcluded)},"filterRefreshes":\(filterRefreshes),\
        "startupMs":\(lastStartupMs),\(echoJSON()),"commits":\(commits),"ticks":\(tickCount),"fps":\(captureFPS)}
        """
    }

    // MARK: - Stages

    private func stage(for screen: NSScreen) -> Stage {
        let id = screen.displayID
        if let s = stages[id] { return s }
        let s = Stage(screen: screen, displayID: id)
        stages[id] = s
        return s
    }

    /// Build every display's panel and filter now, while nobody is waiting.
    private func prepareStages() {
        refreshFilters(for: NSScreen.screens.map { stage(for: $0) }, then: nil)
    }

    /// One `SCShareableContent` round trip (~100 ms) for any number of stages.
    private func refreshFilters(for wanted: [Stage], then done: (() -> Void)?) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard let content else {
                    overlayError("🔎 ShareZoom: no shareable content: \(error?.localizedDescription ?? "nil")")
                    done?()
                    return
                }
                for s in wanted {
                    guard let display = content.displays.first(where: { $0.displayID == s.displayID }) else { continue }
                    // Exclude *this* panel only, not the whole app: the banners, the
                    // hands-off locks and the break overlay belong in the picture.
                    let own = content.windows.filter { $0.windowID == CGWindowID(s.panel.windowNumber) }
                    let above = Set(self.alsoExcluded())
                    let effects = content.windows.filter(Self.isEffectsWindow)
                    let others = content.windows.filter { above.contains($0.windowID) } + effects
                    s.excludesOwnWindow = !own.isEmpty
                    s.excludedEffects = Set(effects.map(\.windowID))
                    let filter = SCContentFilter(display: display, excludingWindows: own + others)
                    s.filter = filter
                    // A stream already running keeps the filter it started with: hand it
                    // the new one, or a window that appeared mid-zoom stays filmed.
                    if let stream = self.stream, self.streamStage === s, s.excludesOwnWindow {
                        stream.updateContentFilter(filter) { error in
                            guard let error else { return }
                            overlayError("🔎 ShareZoom: updateContentFilter failed: \(error.localizedDescription)")
                        }
                    }
                }
                self.filterRefreshes += 1
                done?()
            }
        }
    }

    // MARK: - Lifecycle

    private func activate(on screen: NSScreen) {
        let s = stage(for: screen)
        active = s
        current = 1
        origin = .zero
        visible = false
        framesShown = 0
        rehides = 0
        tickCount = 0
        commits = 0
        lastWritten = nil
        startedAt = CFAbsoluteTimeGetCurrent()
        lingerStop?.cancel()
        lingerStop = nil

        // Follow the magnifier's own "Smooth images" switch, so this looks like the
        // zoom Victor already knows (it is off on this Mac: crisp pixels).
        let universal = UserDefaults(suiteName: "com.apple.universalaccess")
        let smooth = universal?.bool(forKey: "closeViewSmoothImages") ?? true
        pointerScale = max(1, CGFloat(universal?.double(forKey: "mouseDriverCursorSize") ?? 1))
        s.image.magnificationFilter = smooth ? .linear : .nearest
        s.image.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        s.cursor.isHidden = true
        // Invisible until a frame is in it: a black screen for 100 ms would be worse
        // than a zoom that starts 100 ms late.
        s.panel.alphaValue = 0
        s.panel.orderFrontRegardless()
        startTick()

        if stream != nil, streamStage === s, s.image.contents != nil {
            // Still lingering from the last zoom: the picture is already live.
            show()
            return
        }
        stopStream()
        if s.filter != nil, s.excludesOwnWindow {
            startStream(on: s)
        } else {
            // Not prepared yet (or the panel was not listed while ordered out):
            // ask again now that it is on screen.
            refreshFilters(for: [s]) { [weak self] in
                guard let self, self.active === s else { return }
                guard s.excludesOwnWindow else {
                    overlayError("🔎 ShareZoom: own window not in shareable content — refused, it would film itself")
                    self.deactivate()
                    return
                }
                self.startStream(on: s)
            }
        }
    }

    /// The first frame is in: show the panel. The zoom animation starts from here,
    /// not from the gesture — eased while still invisible, it used to be over before
    /// anything was on screen and the zoom appeared as one jump.
    private func show() {
        guard let s = active, !visible else { return }
        visible = true
        s.panel.alphaValue = 1
        lastStartupMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        overlayInfo("🔎 ShareZoom: on \(s.name), visible after \(lastStartupMs) ms")
    }

    /// Back to 1× (or moving to another display): the panel goes, the stream lingers.
    private func deactivate() {
        tick?.invalidate()
        tick = nil
        publishCursor(nil)
        restoreCursor()
        active?.cursor.isHidden = true
        active?.panel.orderOut(nil)
        active = nil
        visible = false
        pinnedFocus = nil
        target = 1
        current = 1
        guard stream != nil else { return }
        lingerStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active == nil else { return }
            self.stopStream()
            // Re-list the windows for the next zoom: the filters are built ahead
            // of time, and a Victor Effects restart gives its caption window a
            // new id that a filter from before would no longer exclude.
            self.prepareStages()
        }
        lingerStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    private func startStream(on s: Stage) {
        guard let filter = s.filter else { return }
        let config = SCStreamConfiguration()
        config.width = Int(s.frame.width * s.scale)
        config.height = Int(s.frame.height * s.scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: captureFPS)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            overlayError("🔎 ShareZoom: addStreamOutput failed: \(error)")
            deactivate()
            return
        }
        self.stream = stream
        streamStage = s
        frameQueue.async { self.echo.reset(); self.liveStream = stream }
        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.stream === stream else { return }
                overlayError("🔎 ShareZoom: startCapture failed: \(error.localizedDescription)")
                self.stopStream()
                self.deactivate()
            }
        }
    }

    private func stopStream() {
        lingerStop?.cancel()
        lingerStop = nil
        stream?.stopCapture { _ in }
        stream = nil
        streamStage?.image.contents = nil
        streamStage = nil
    }

    // MARK: - Cursor

    /// Hides the real cursor, or — when it is already hidden — hides it **once more**.
    ///
    /// The Dock gives it back: with the Dock on the left and auto-hidden, the pointer
    /// touching the retina's left edge pops the Dock out and the real arrow reappears
    /// beside the drawn one (2026-10-01, Victor's screenshot, then reproduced with a
    /// ScreenCaptureKit `showsCursor` capture — `screencapture -C` is useless here, it
    /// draws the cursor even while it is hidden). So after any edge contact the hide is
    /// re-asserted a few times (`follow`). Every call is counted in `hideDepth` and
    /// `restoreCursor` undoes exactly that many: the counters are per connection, and
    /// an unbalanced extra hide would leave the arrow gone after the zoom.
    ///
    /// Both calls, as the 💓 heartbeat in victor-effects does: `CGDisplayHideCursor`
    /// alone was not enough either.
    private func hideCursor(again: Bool = false) {
        guard hideDepth == 0 || again else { return }
        Self.armBackgroundCursorHiding()
        NSCursor.hide()
        CGDisplayHideCursor(CGMainDisplayID())
        hideDepth += 1
    }

    /// Whether the cursor is on screen, for every process — not just this one's hide
    /// count (measured 2026-10-26: a probe saw another process's hide). Unavailable
    /// to Swift since macOS 26's SDK, so resolved via dlsym; ~0 ms a call.
    private static let cursorIsVisible: (() -> Bool)? = {
        typealias VisibleFn = @convention(c) () -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        let fn = unsafeBitCast(sym, to: VisibleFn.self)
        return { fn() != 0 }
    }()

    private func restoreCursor() {
        while hideDepth > 0 {
            NSCursor.unhide()
            CGDisplayShowCursor(CGMainDisplayID())
            hideDepth -= 1
        }
    }

    /// `CGDisplayHideCursor` works only while the calling app is frontmost unless the
    /// window server's private per-connection `SetsCursorInBackground` flag is set —
    /// same technique as `CropSelectionOverlay` in victor-mac-kit. Resolved via dlsym,
    /// so a macOS without it degrades to two cursors, not a crash. A process exit
    /// releases any hide with its connection.
    private static let backgroundCursorHidingArmed: Bool = {
        typealias DefaultConnFn = @convention(c) () -> Int32
        typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let connSym = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let propSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(connSym, to: DefaultConnFn.self)()
        _ = unsafeBitCast(propSym, to: SetPropFn.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        return true
    }()

    private static func armBackgroundCursorHiding() { _ = backgroundCursorHidingArmed }

    /// Copy the system cursor's current shape (arrow, I-beam, hand…) into the layer
    /// and remember its hot spot. Read off main (see `cursorQueue`), applied on main.
    private func refreshCursorImage(_ s: Stage) {
        guard !cursorReadInFlight else { return }
        cursorReadInFlight = true
        let scale = pointerScale
        cursorQueue.async { [weak self] in
            let sys = NSCursor.currentSystem
            // Ask for the size it will be drawn at (×4 headroom for the zoom), so the
            // best representation is picked and the magnified copy stays crisp.
            var proposed = CGRect(origin: .zero, size: CGSize(width: (sys?.image.size.width ?? 0) * scale * 4,
                                                              height: (sys?.image.size.height ?? 0) * scale * 4))
            let cg = sys?.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            // Accessibility's "Pointer size" enlarges the real cursor but not the
            // image handed out here: without it, the drawn cursor shrank to the bare
            // arrow the moment the zoom started (Victor, 2026-10-15; his is 2.43×).
            let size = (sys?.image.size ?? .zero).applying(CGAffineTransform(scaleX: scale, y: scale))
            let hot = (sys?.hotSpot ?? .zero).applying(CGAffineTransform(scaleX: scale, y: scale))
            DispatchQueue.main.async {
                guard let self else { return }
                self.cursorReadInFlight = false
                guard let cg, self.active === s else { return }
                // A fresh CGImage every read: compare the pixels, or the 10 Hz read
                // alone would recompose the Retina ten times a second.
                if size == self.cursorSize, hot == self.hotSpot,
                   let old = s.cursor.contents, CFGetTypeID(old as CFTypeRef) == CGImage.typeID,
                   (old as! CGImage).dataProvider?.data == cg.dataProvider?.data { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                s.cursor.contents = cg
                CATransaction.commit()
                self.cursorSize = size
                self.hotSpot = hot
            }
        }
    }

    // MARK: - Victor Effects' windows

    /// Ticks between two looks at Victor Effects' on-screen windows: 15 at 120 Hz,
    /// so a panel it opens mid-zoom is filmed for ~125 ms plus one listing (~100 ms)
    /// at most. The look is `CGWindowListCopyWindowInfo` — cheap, unlike the
    /// `SCShareableContent` round trip, which is paid only when the set changed.
    private static let effectsWatchEvery = 15
    private var filterRefreshes = 0
    private var effectsRefreshInFlight = false

    /// Victor Effects puts a window on screen that the filter does not leave out
    /// (the green edge flash makes a new one per flash; a restart renumbers them
    /// all): list again and hand the live stream the new filter.
    private func watchEffectsWindows(_ s: Stage) {
        guard !effectsRefreshInFlight,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.effectsBundleID)
                .first?.processIdentifier,
              let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return }
        let onScreen = info.compactMap { w -> CGWindowID? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return w[kCGWindowNumber as String] as? CGWindowID
        }
        let fresh = Set(onScreen).subtracting(s.excludedEffects).subtracting(s.askedAbout)
        guard !fresh.isEmpty else { return }
        s.askedAbout.formUnion(fresh)
        effectsRefreshInFlight = true
        refreshFilters(for: [s]) { [weak self] in self?.effectsRefreshInFlight = false }
    }

    // MARK: - Follow the pointer

    private func startTick() {
        tick?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func follow() {
        guard let s = active, visible else { return }
        tickCount += 1
        if tickCount % Self.effectsWatchEvery == 0 { watchEffectsWindows(s) }
        let previous = current
        current = ShareZoomPolicy.ease(current, toward: target)
        if ShareZoomPolicy.isOff(current: current, target: target) {
            deactivate()
            return
        }
        let size = s.frame.size
        let focus = pinnedFocus ?? NSEvent.mouseLocation
        let inside = NSMouseInRect(focus, s.frame, false)
        let p = CGPoint(x: min(max(focus.x - s.frame.minX, 0), size.width),
                        y: min(max(focus.y - s.frame.minY, 0), size.height))
        origin = ShareZoomPolicy.rezoom(origin: origin, from: previous, to: current, pointer: p, screenSize: size)
        origin = ShareZoomPolicy.pan(origin: origin, pointer: p, factor: current, screenSize: size)

        // Every layer write is a commit, and every commit makes WindowServer recompose
        // the whole Retina — which the stream then films again (it excludes a window,
        // so it renders a composite of its own). Written every tick, that was a
        // 120 Hz loop that never rested even with the pointer and the picture still
        // (the adversarial review of 2026-10-15). Only what changed is written now.
        let rect = ShareZoomPolicy.contentsRect(origin: origin, factor: current, screenSize: size)
        var cursorFrame: CGRect?
        if inside {
            let drawnAt = ShareZoomPolicy.cursorPoint(pointer: p, origin: origin, factor: current)
            publishCursor(CGPoint(x: s.frame.minX + drawnAt.x, y: s.frame.minY + drawnAt.y))
        } else {
            publishCursor(nil)
        }
        if inside, pinnedFocus == nil {
            hideCursor()
            // The edges are where the system UI lives (the auto-hidden Dock, the
            // menu bar, hot corners), and the Dock popping out — or the pointer
            // moving across its icons — shows the real cursor again. Re-hide at
            // 4 Hz while the pointer is within a Dock's width of any edge, and for
            // 2 s after it leaves.
            let now = CFAbsoluteTimeGetCurrent()
            let band: CGFloat = 100
            if focus.x <= s.frame.minX + band || focus.x >= s.frame.maxX - band
                || focus.y <= s.frame.minY + band || focus.y >= s.frame.maxY - band {
                reassertUntil = now + 2
            }
            if now < reassertUntil, tickCount % 30 == 0 { hideCursor(again: true) }
            // Anyone else may show it too — ScreenBrush does, on entering its drawing
            // mode. Looked at 20×/s, hidden again at once. Capped: every hide is
            // undone one by one at the end, and an app fighting back forever must not
            // pile up thousands of them.
            if tickCount % 6 == 3, rehides < Self.maxRehides, Self.cursorIsVisible?() == true {
                hideCursor(again: true)
                rehides += 1
                if rehides == 1 || rehides == Self.maxRehides {
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    overlayInfo("🔎 ShareZoom: the real cursor came back (front: \(front)) — hidden again ×\(rehides)")
                }
            }
            if tickCount % 12 == 1 { refreshCursorImage(s) }
            let at = ShareZoomPolicy.cursorPoint(pointer: p, origin: origin, factor: current)
            // `hotSpot` is measured from the image's top-left; the layer's y grows up.
            let b = cursorSize
            cursorFrame = CGRect(x: at.x - hotSpot.x * current,
                                 y: at.y - (b.height - hotSpot.y) * current,
                                 width: b.width * current, height: b.height * current)
        } else {
            // On another display the real cursor is the one to follow.
            restoreCursor()
        }
        // Compared with what was last written, not read back from the layers: a
        // CALayer's frame comes back from position/bounds and can differ by an ulp.
        let showTip = cursorFrame != nil && CFAbsoluteTimeGetCurrent() < tipUntil
        let written = Written(rect: rect, cursor: cursorFrame, tipIn: showTip ? zoomingIn : nil)
        guard written != lastWritten else { return }
        lastWritten = written
        commits += 1
        let cursorHidden = cursorFrame == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.image.contentsRect = rect
        if let cursorFrame {
            s.cursor.frame = cursorFrame
            s.tip.frame = Self.tipFrame(beside: cursorFrame, in: size)
        }
        s.cursor.isHidden = cursorHidden
        if let tipIn = written.tipIn { s.tip.contents = tipIn ? s.tipIn : s.tipOut }
        s.tip.isHidden = written.tipIn == nil
        CATransaction.commit()
    }

    /// Just off the drawn cursor's lower-right corner, flipped to the other side of
    /// it near the right or bottom edge so it never leaves the screen.
    static func tipFrame(beside cursor: CGRect, in screen: CGSize) -> CGRect {
        let side = Stage.tipSide, gap: CGFloat = 4
        var x = cursor.maxX + gap
        if x + side > screen.width { x = cursor.minX - gap - side }
        var y = cursor.minY - gap - side  // the layer's y grows up: below = smaller
        if y < 0 { y = cursor.maxY + gap }
        return CGRect(x: min(max(x, 0), screen.width - side), y: min(max(y, 0), screen.height - side),
                      width: side, height: side)
    }

    // MARK: - Telling victor-effects where the cursor is

    /// Where the room sees the cursor, for the effects drawn at it (`VisibleCursor` in
    /// victor-effects: the 💓 heartbeat's bulge, the 🔍 glass, the whip…). Those read
    /// the *real* pointer, which under this zoom is somewhere else on the glass as soon
    /// as the picture has panned. The effects window sits above this one (maximum window
    /// level), so they are drawn unmagnified over the zoomed picture and need nothing
    /// else — only this one point.
    ///
    /// A distributed notification, not HTTP: no reply is needed, it costs nothing when
    /// the effects app is down, and neither app waits for the other. ~30 Hz while the
    /// cursor moves, a 0.5 s keep-alive while it rests (the receiver treats 1.5 s of
    /// silence as "zoom gone" — a crash must not leave effects pinned to a dead point),
    /// and an empty one when the zoom ends or the pointer leaves the zoomed display.
    static let cursorNotification = Notification.Name("ro.victorrentea.share-zoom.cursor")

    private func publishCursor(_ point: CGPoint?) {
        let now = CFAbsoluteTimeGetCurrent()
        if let point {
            let moved = publishedCursor.map { hypot($0.x - point.x, $0.y - point.y) > 0.5 } ?? true
            let due = now - publishedAt >= (moved ? 1.0 / 30 : 0.5)
            guard due else { return }
            publishedCursor = point
            publishedAt = now
            DistributedNotificationCenter.default().postNotificationName(
                Self.cursorNotification, object: nil,
                userInfo: ["x": Double(point.x), "y": Double(point.y)], deliverImmediately: true)
        } else {
            guard publishedCursor != nil else { return }
            publishedCursor = nil
            publishedAt = now
            DistributedNotificationCenter.default().postNotificationName(
                Self.cursorNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        // Our own repaint damages the display we film: an unchanged frame is skipped,
        // or showing it would summon the next one (`EchoGate`).
        echo.offer(pixelBuffer, surface)
    }

    /// A frame worth showing, from `echo` on `frameQueue`: hand it to main.
    private func present(_ surface: IOSurface, from stream: SCStream?) {
        pendingLock.lock()
        let hopQueued = pendingSurface != nil
        pendingSurface = surface
        pendingLock.unlock()
        guard !hopQueued else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let latest = self.pendingSurface
            self.pendingSurface = nil
            self.pendingLock.unlock()
            guard let surface = latest, self.stream === stream, let s = self.streamStage else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            s.image.contents = surface
            CATransaction.commit()
            self.framesShown += 1
            if self.active === s { self.show() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            overlayError("🔎 ShareZoom: stream stopped: \(error.localizedDescription) → zoom off")
            self.stream = nil
            self.streamStage = nil
            self.deactivate()
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
