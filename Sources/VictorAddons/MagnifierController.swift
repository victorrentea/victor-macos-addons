import AppKit
import ScreenCaptureKit
import CoreGraphics

class MagnifierController: NSObject {

    // MARK: - Tuning constants
    private static let minZoom: Double = 1.0
    private static let maxZoom: Double = 15.0
    private static let zoomMultiplier: Double = 0.15
    private static let maxZoomStep: Double = 0.5
    private static let panSpeedPixelsPerSec: Double = 600.0
    private static let edgeThresholdPoints: Double = 80.0
    static let streamFPS: CMTimeScale = 30

    // MARK: - Screen geometry (buffer pixels = physical Retina pixels)
    private let screen: NSScreen
    let bufferW: CGFloat
    let bufferH: CGFloat

    // MARK: - State
    enum State { case inactive, starting, active, stopping }
    private(set) var state: State = .inactive
    private(set) var zoomFactor: Double = 1.0
    var viewportOrigin: CGPoint = .zero

    // MARK: - UI
    let panel: NSPanel
    let contentLayer: CALayer

    // MARK: - Stream / timers
    var stream: SCStream?
    private var panTimer: Timer?
    private var lastPanTime: Date = .now
    var firstFrameReceived = false

    // MARK: - Init

    init(screen: NSScreen) {
        self.screen = screen
        let scale = screen.backingScaleFactor
        self.bufferW = screen.frame.width * scale
        self.bufferH = screen.frame.height * scale

        let p = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = false
        p.alphaValue = 0

        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.backgroundColor = NSColor.black.cgColor

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        p.contentView = view

        self.panel = p
        self.contentLayer = layer
        super.init()
    }

    // MARK: - Public API

    func adjustZoom(scrollDelta: Double) {
        DispatchQueue.main.async { [weak self] in self?.handleZoom(scrollDelta) }
    }

    // MARK: - Zoom state machine

    private func handleZoom(_ delta: Double) {
        let step = max(-Self.maxZoomStep, min(Self.maxZoomStep, -delta * Self.zoomMultiplier))
        let newZoom = max(Self.minZoom, min(Self.maxZoom, zoomFactor + step))

        switch state {
        case .inactive:
            guard newZoom > 1.0 else { return }
            zoomFactor = newZoom
            activate()
        case .active, .starting:
            if newZoom <= 1.0 {
                deactivate()
            } else {
                zoomFactor = newZoom
                clampViewport()
                updateContentsRect()
            }
        case .stopping:
            break
        }
    }

    func activate() {
        guard state == .inactive else { return }
        state = .starting
        firstFrameReceived = false

        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        viewportOrigin = CGPoint(x: (bufferW - vw) / 2, y: (bufferH - vh) / 2)

        panel.orderFrontRegardless()
        panel.alphaValue = 0
        startStream()
    }

    func deactivate() {
        guard state == .active || state == .starting else { return }
        state = .stopping
        zoomFactor = 1.0
        panTimer?.invalidate()
        panTimer = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
        let s = stream
        stream = nil
        if let s { Task { try? await s.stopCapture() } }
        state = .inactive
    }

    // MARK: - Viewport helpers

    func clampViewport() {
        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        viewportOrigin.x = max(0, min(bufferW - vw, viewportOrigin.x))
        viewportOrigin.y = max(0, min(bufferH - vh, viewportOrigin.y))
    }

    func updateContentsRect() {
        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        let nx = viewportOrigin.x / bufferW
        let ny = 1.0 - (viewportOrigin.y + vh) / bufferH
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contentsRect = CGRect(x: nx, y: ny, width: vw / bufferW, height: vh / bufferH)
        CATransaction.commit()
    }

    // MARK: - Pan timer

    func startPanTimer() {
        lastPanTime = .now
        panTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.panTick()
        }
    }

    private func panTick() {
        guard state == .active else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastPanTime)
        lastPanTime = now

        let cursor = NSEvent.mouseLocation
        let scale = screen.backingScaleFactor
        let relX = cursor.x - screen.frame.minX
        let relY = cursor.y - screen.frame.minY

        let cx = relX * scale
        let cy = (screen.frame.height - relY) * scale

        let threshold = CGFloat(Self.edgeThresholdPoints) * scale
        let speed = CGFloat(Self.panSpeedPixelsPerSec) * scale * CGFloat(dt)

        func frac(_ dist: CGFloat) -> CGFloat { max(0, (threshold - dist) / threshold) }

        let dxRight = frac(bufferW - cx) - frac(cx)
        let dyDown  = frac(bufferH - cy) - frac(cy)

        viewportOrigin.x += speed * dxRight
        viewportOrigin.y += speed * dyDown

        clampViewport()
        updateContentsRect()
    }

    // MARK: - Stream placeholder (replaced in Task 4)

    private func startStream() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.state == .starting else { return }
            self.state = .active
            self.panel.alphaValue = 1.0
            self.startPanTimer()
        }
    }
}
