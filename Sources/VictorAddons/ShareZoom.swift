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
        var filter: SCContentFilter?
        /// Whether the filter really excludes our panel. If it does not, the stream
        /// would film its own output; the filter is rebuilt once the panel is on screen.
        var excludesOwnWindow = false

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
            view.layer?.addSublayer(image)
            view.layer?.addSublayer(cursor)
            panel.contentView = view
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

    private var framesShown = 0
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var lastStartupMs = 0
    private let frameQueue = DispatchQueue(label: "ShareZoom.frames", qos: .userInteractive)

    var isActive: Bool { active != nil }

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
    }

    // MARK: - Gesture

    /// One ⌥⇧+scroll event, already reversed (`ScrollReversal`). Main thread.
    func scroll(delta: Double, continuous: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let under = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        pinnedFocus = nil
        if let active, active.displayID != under.displayID {
            // Moving the zoom to another display keeps the factor it had.
            let keep = target
            deactivate()
            target = keep
        }
        target = ShareZoomPolicy.step(target, delta: delta, continuous: continuous)
        if target > 1, active == nil { activate(on: under) }
    }

    /// `/test/share-zoom`: set the factor directly, optionally pinning the focus point.
    func testSet(factor: CGFloat, focus: CGPoint?) -> String {
        let point = focus ?? NSEvent.mouseLocation
        if factor <= 1 {
            deactivate()
        } else if let under = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            if let active, active.displayID != under.displayID { deactivate() }
            target = min(factor, ShareZoomPolicy.maxFactor)
            pinnedFocus = focus
            if active == nil { activate(on: under) }
        }
        return snapshotJSON()
    }

    func snapshotJSON() -> String {
        let frame = active?.frame ?? .zero
        let rect = active?.image.contentsRect ?? .zero
        let prepared = stages.values
            .map { "\"\($0.name)\":\($0.filter != nil && $0.excludesOwnWindow)" }
            .joined(separator: ",")
        return """
        {"active":\(isActive),"visible":\(visible),"target":\(String(format: "%.3f", target)),\
        "current":\(String(format: "%.3f", current)),"framesShown":\(framesShown),\
        "screen":"\(active?.name ?? "")",\
        "screenFrame":[\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))],\
        "contentsRect":[\(String(format: "%.4f,%.4f,%.4f,%.4f", rect.minX, rect.minY, rect.width, rect.height))],\
        "cursorFrame":[\(Int(active?.cursor.frame.width ?? 0)),\(Int(active?.cursor.frame.height ?? 0))],\
        "streaming":\(stream != nil),"cursorHidden":\(cursorHidden),"hideDepth":\(hideDepth),"prepared":{\(prepared)},\
        "startupMs":\(lastStartupMs)}
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
                    s.excludesOwnWindow = !own.isEmpty
                    s.filter = SCContentFilter(display: display, excludingWindows: own)
                }
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
        tickCount = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        lingerStop?.cancel()
        lingerStop = nil

        // Follow the magnifier's own "Smooth images" switch, so this looks like the
        // zoom Victor already knows (it is off on this Mac: crisp pixels).
        let smooth = UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "closeViewSmoothImages") ?? true
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
        }
        lingerStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    private func startStream(on s: Stage) {
        guard let filter = s.filter else { return }
        let config = SCStreamConfiguration()
        config.width = Int(s.frame.width * s.scale)
        config.height = Int(s.frame.height * s.scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
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
    /// and remember its hot spot.
    private func refreshCursorImage(_ s: Stage) {
        guard let sys = NSCursor.currentSystem,
              let cg = sys.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        s.cursor.contents = cg
        cursorSize = sys.image.size
        hotSpot = sys.hotSpot
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.image.contentsRect = ShareZoomPolicy.contentsRect(origin: origin, factor: current, screenSize: size)
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
            if tickCount % 6 == 1 { refreshCursorImage(s) }
            let at = ShareZoomPolicy.cursorPoint(pointer: p, origin: origin, factor: current)
            // `hotSpot` is measured from the image's top-left; the layer's y grows up.
            let b = cursorSize
            s.cursor.frame = CGRect(x: at.x - hotSpot.x * current,
                                    y: at.y - (b.height - hotSpot.y) * current,
                                    width: b.width * current, height: b.height * current)
            s.cursor.isHidden = false
        } else {
            // On another display the real cursor is the one to follow.
            restoreCursor()
            s.cursor.isHidden = true
        }
        CATransaction.commit()
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream, let s = self.streamStage else { return }
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
