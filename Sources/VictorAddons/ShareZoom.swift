import AppKit
import ScreenCaptureKit

/// 🔎 ⌥⇧+scroll — a full-screen zoom that a Zoom screen share **carries**.
///
/// macOS's own magnifier (⌥+scroll) is applied at scanout, after the frame every
/// capture client reads, so the people on the call see the plain desktop while the
/// room sees it magnified (`docs/displays-projector.md` has the measurements). Zoom's
/// unfiltered capture mode works around that, but not in every meeting and not with
/// every client. This does the magnification **inside a window**: the display is
/// captured live through ScreenCaptureKit, *minus this window*, and drawn back
/// enlarged over the whole screen. An ordinary window is exactly what a share shows,
/// so the far end sees what the room sees — the 🔍 Pink Panther glass (tile #6 in
/// `victor-effects`) made the same trade, at 4 fps and inside a lens.
///
/// - **Input is never touched.** The window is click-through and the pointer is the
///   fixed point of the magnification (`ShareZoomPolicy.sourceRect`), so whatever is
///   drawn under the cursor is what a click really hits.
/// - **The cursor is not magnified.** The hardware cursor is drawn above every window;
///   the stream is configured without it so it does not appear twice.
/// - **One display at a time** — the one under the pointer when the zoom starts.
///   ⌥⇧+scroll on another display moves the zoom there.
/// - Scrolling back down to 1× takes the window away and stops the stream; while it
///   runs macOS shows its screen-recording indicator in the menu bar.
///
/// Main thread only, except the frame callback, which hops to main.
final class ShareZoom: NSObject, SCStreamOutput, SCStreamDelegate {

    private var window: NSWindow?
    private var imageLayer: CALayer?
    private var stream: SCStream?
    private var screen: NSScreen?
    private var tick: Timer?
    private var target: CGFloat = 1
    private var current: CGFloat = 1
    /// A focus point pinned by `/test/share-zoom?x=&y=` (global Cocoa points),
    /// so the zoom can be exercised on the right-hand screen without the mouse.
    private var pinnedFocus: CGPoint?
    /// Bumped on every start/stop, so a capture that comes up after its zoom was
    /// already cancelled tears itself down instead of resurrecting it.
    private var generation = 0
    private var framesShown = 0
    private let frameQueue = DispatchQueue(label: "ShareZoom.frames", qos: .userInteractive)

    var isActive: Bool { window != nil }

    override init() {
        super.init()
        // A display plugged, unplugged or rearranged invalidates the window frame
        // and the stream size at once; drop the zoom rather than draw a wrong picture.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            overlayInfo("🔎 ShareZoom: displays changed → zoom off")
            self.stop()
        }
    }

    // MARK: - Gesture

    /// One ⌥⇧+scroll event, already reversed (`ScrollReversal`). Main thread.
    func scroll(delta: Double, continuous: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let under = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        pinnedFocus = nil
        if isActive, let screen, screen != under {
            // Moving the zoom to another display keeps the factor it had.
            let keep = target
            stop()
            target = keep
        }
        target = ShareZoomPolicy.step(target, delta: delta, continuous: continuous)
        if target > 1, !isActive { start(on: under) }
    }

    /// `/test/share-zoom`: set the factor directly, optionally pinning the focus point.
    func testSet(factor: CGFloat, focus: CGPoint?) -> String {
        let point = focus ?? NSEvent.mouseLocation
        if factor <= 1 {
            target = 1
            if isActive { stop() }
        } else if let under = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            if isActive, let screen, screen != under { stop() }
            target = min(factor, ShareZoomPolicy.maxFactor)
            pinnedFocus = focus
            if !isActive { start(on: under) }
        }
        return snapshotJSON()
    }

    func snapshotJSON() -> String {
        let frame = screen?.frame ?? .zero
        let rect = imageLayer?.contentsRect ?? .zero
        return """
        {"active":\(isActive),"target":\(String(format: "%.3f", target)),\
        "current":\(String(format: "%.3f", current)),"framesShown":\(framesShown),\
        "screen":"\(screen?.localizedName ?? "")",\
        "screenFrame":[\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))],\
        "contentsRect":[\(String(format: "%.4f,%.4f,%.4f,%.4f", rect.minX, rect.minY, rect.width, rect.height))],\
        "windowNumber":\(window?.windowNumber ?? 0)}
        """
    }

    // MARK: - Lifecycle

    private func start(on screen: NSScreen) {
        generation += 1
        let gen = generation
        self.screen = screen
        current = 1
        framesShown = 0

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Invisible until the first frame lands: a black screen for 100 ms would be
        // worse than a zoom that starts 100 ms late.
        panel.alphaValue = 0

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let layer = CALayer()
        layer.frame = view.bounds
        layer.contentsGravity = .resize
        // Follow the magnifier's own "Smooth images" switch, so this looks like
        // the zoom Victor already knows (it is off on this Mac: crisp pixels).
        let smooth = UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "closeViewSmoothImages") ?? true
        layer.magnificationFilter = smooth ? .linear : .nearest
        layer.actions = ["contents": NSNull(), "contentsRect": NSNull(),
                         "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(layer)
        panel.contentView = view
        panel.orderFrontRegardless()

        window = panel
        imageLayer = layer
        startTick()

        let windowID = CGWindowID(panel.windowNumber)
        let displayID = screen.displayID
        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                               height: screen.frame.height * screen.backingScaleFactor)

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                guard let content,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    overlayError("🔎 ShareZoom: no shareable display \(displayID): \(error?.localizedDescription ?? "nil")")
                    self.stop()
                    return
                }
                // Exclude *this* window only, not the whole app: the banners, the
                // hands-off locks and the break overlay belong in the picture.
                let own = content.windows.filter { $0.windowID == windowID }
                if own.isEmpty { overlayError("🔎 ShareZoom: own window \(windowID) not in shareable content — the picture will recurse") }
                let filter = SCContentFilter(display: display, excludingWindows: own)
                let config = SCStreamConfiguration()
                config.width = Int(pixelSize.width)
                config.height = Int(pixelSize.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 5
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                } catch {
                    overlayError("🔎 ShareZoom: addStreamOutput failed: \(error)")
                    self.stop()
                    return
                }
                self.stream = stream
                stream.startCapture { error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        overlayError("🔎 ShareZoom: startCapture failed: \(error.localizedDescription)")
                        if self.generation == gen { self.stop() }
                    }
                }
                overlayInfo("🔎 ShareZoom: on \(self.screen?.localizedName ?? "?") (\(Int(pixelSize.width))×\(Int(pixelSize.height)) px)")
            }
        }
    }

    func stop() {
        generation += 1
        tick?.invalidate()
        tick = nil
        stream?.stopCapture { _ in }
        stream = nil
        window?.orderOut(nil)
        window = nil
        imageLayer = nil
        screen = nil
        pinnedFocus = nil
        target = 1
        current = 1
    }

    // MARK: - Follow the pointer

    private func startTick() {
        tick?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func follow() {
        guard let screen, let imageLayer else { return }
        current = ShareZoomPolicy.ease(current, toward: target)
        if ShareZoomPolicy.isOff(current: current, target: target) {
            overlayInfo("🔎 ShareZoom: back to 1× → off")
            stop()
            return
        }
        let focus = pinnedFocus ?? NSEvent.mouseLocation
        let local = CGPoint(x: focus.x - screen.frame.minX, y: focus.y - screen.frame.minY)
        let rect = ShareZoomPolicy.contentsRect(screenSize: screen.frame.size, pointer: local, factor: current)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsRect = rect
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
            guard let self, self.stream === stream, let layer = self.imageLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            self.framesShown += 1
            if self.framesShown == 1 { self.window?.alphaValue = 1 }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            overlayError("🔎 ShareZoom: stream stopped: \(error.localizedDescription) → zoom off")
            self.stop()
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
