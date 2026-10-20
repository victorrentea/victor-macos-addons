import AppKit
import ScreenCaptureKit

/// 🔦 Scroll on the glass → the box grows towards the middle of the screen
/// (Victor, 2026-10-20: *"the part that I have allowed to be visible should zoom
/// in towards the center of the screen. To the maximum zoom in, that should fit
/// 80% of the screen … the things around it should be still blurred"*).
///
/// The arithmetic, with no screen or stream in sight. `progress` runs from 0 (the
/// box where it was drawn, unmagnified) to 1 (centred, as big as fits in 80% of
/// the screen's width *and* height).
enum GlassSpotlightZoom {
    /// At full zoom the box takes at most this much of the screen, either way.
    static let fill: CGFloat = 0.8
    /// Wheel notches from the drawn box to full zoom (`ShareZoomPolicy.notches`
    /// counts them, so both zooms turn the same way under the same wheel).
    static let notchesToFull: CGFloat = 10

    /// How many times bigger the box is at full zoom. Never under 1: a box that
    /// already covers more than 80% only slides to the middle.
    static func maxScale(box: CGRect, screen: CGRect) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 1 }
        return max(1, min(fill * screen.width / box.width, fill * screen.height / box.height))
    }

    static func scale(box: CGRect, screen: CGRect, progress: CGFloat) -> CGFloat {
        1 + (maxScale(box: box, screen: screen) - 1) * progress
    }

    /// Where the box is drawn at `progress`: its centre slides from its own to the
    /// screen's while it grows, so it is already centred when it reaches full size.
    static func frame(box: CGRect, screen: CGRect, progress: CGFloat) -> CGRect {
        let s = scale(box: box, screen: screen, progress: progress)
        let center = self.center(box: box, screen: screen, progress: progress)
        return CGRect(x: center.x - box.width * s / 2, y: center.y - box.height * s / 2,
                      width: box.width * s, height: box.height * s)
    }

    static func center(box: CGRect, screen: CGRect, progress: CGFloat) -> CGPoint {
        CGPoint(x: box.midX + (screen.midX - box.midX) * progress,
                y: box.midY + (screen.midY - box.midY) * progress)
    }

    /// The next target after one scroll event of `notches` (positive = closer).
    static func step(_ progress: CGFloat, notches: CGFloat) -> CGFloat {
        min(1, max(0, progress + notches / notchesToFull))
    }

    /// One frame of easing towards `target`, at 60 Hz: a wheel moves in notches,
    /// the picture should not.
    static func ease(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        let next = current + (target - current) * 0.2
        return abs(target - next) < 0.002 ? target : next
    }

    /// What the stream films: the box plus its feather, on its own screen — the
    /// feather is filmed too so that, unmagnified, the picture lies exactly over
    /// what the cut-out showed and the switch from one to the other is invisible.
    static func capture(box: CGRect, feather: CGFloat, screen: CGRect) -> CGRect {
        box.insetBy(dx: -feather, dy: -feather).intersection(screen).integral.intersection(screen)
    }

    /// Whether a bare scroll at `point` is the zoom's. Any one coordinate system,
    /// as long as all three agree (the tap passes CG). Unzoomed, only on the glass
    /// — the box scrolls the app under it, as it always did; zoomed, anywhere on
    /// that screen, since the box is under glass by then.
    static func takesScroll(at point: CGPoint, screen: CGRect?, hole: CGRect?, zoomed: Bool) -> Bool {
        guard let screen, screen.contains(point) else { return false }
        if zoomed { return true }
        guard let hole else { return false }
        return !hole.contains(point)
    }
}

/// The live picture of the box while it is zoomed: a ScreenCaptureKit stream of
/// just the box (plus feather), drawn by `layer`. Every window of this app is left
/// out of it — the glass first of all, or it would film itself — and so are Victor
/// Effects' (drawn above everything anyway, they would show twice; see
/// `ShareZoom.isEffectsWindow`).
///
/// Main thread, except the frame callback.
final class GlassSpotlightLens: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The picture, bounds = the filmed rect in points. The caller places it.
    let layer = CALayer()
    /// The first frame is on the layer.
    var onLive: (() -> Void)?
    /// The stream could not start, or stopped by itself.
    var onFailed: ((String) -> Void)?
    private(set) var framesShown = 0

    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "GlassSpotlightLens.frames", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingSurface: IOSurface?
    /// Frame-queue only: the stream frames are presented for.
    private var liveStream: SCStream?
    private lazy var echo = EchoGate(queue: frameQueue) { [weak self] surface in
        self?.present(surface, from: self?.liveStream)
    }
    /// Bumped at every start and stop, so a listing that comes back late finds it
    /// is no longer wanted.
    private var generation = 0

    override init() {
        super.init()
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "transform": NSNull(), "hidden": NSNull(), "anchorPoint": NSNull()]
    }

    var isRunning: Bool { stream != nil }

    /// Film `rect` (global Cocoa points) of `screen`.
    func start(filming rect: CGRect, on screen: NSScreen) {
        stop()
        generation += 1
        let mine = generation
        framesShown = 0
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        // The magnifier's own "Smooth images" switch, as `ShareZoom` follows it.
        let smooth = UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "closeViewSmoothImages") ?? true
        layer.magnificationFilter = smooth ? .linear : .nearest
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine else { return }
                guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    self.onFailed?("no shareable content: \(error?.localizedDescription ?? "display gone")")
                    return
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let excluded = content.windows.filter {
                    $0.owningApplication?.processID == pid || ShareZoom.isEffectsWindow($0)
                }
                let config = SCStreamConfiguration()
                // Display-local, top-left origin.
                config.sourceRect = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                                           width: rect.width, height: rect.height)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 5
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded),
                                      configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                } catch {
                    self.onFailed?("addStreamOutput failed: \(error)")
                    return
                }
                self.stream = stream
                self.frameQueue.async { self.echo.reset(); self.liveStream = stream }
                stream.startCapture { [weak self] error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        guard let self, self.stream === stream else { return }
                        self.stop()
                        self.onFailed?("startCapture failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func stop() {
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
        frameQueue.async { self.liveStream = nil }
        layer.contents = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        // The magnified box repaints the display it films: an unchanged frame is
        // skipped, or showing it would summon the next one (`EchoGate`).
        echo.offer(pixelBuffer, surface)
    }

    /// One hop to main at a time, newest frame wins — `ShareZoom.present`'s reasoning.
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
            guard let surface = latest, let stream, self.stream === stream else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = surface
            CATransaction.commit()
            self.framesShown += 1
            if self.framesShown == 1 { self.onLive?() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
            self.onFailed?("stream stopped: \(error.localizedDescription)")
        }
    }
}
