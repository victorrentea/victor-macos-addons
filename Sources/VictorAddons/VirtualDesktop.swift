import AppKit
import AVFoundation
import CGVirtualDisplayShim
import CoreImage
import ScreenCaptureKit
import Vision

enum VirtualDesktopSettings {
    static let enabledKey = "VirtualDesktop.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let autoStartKey = "VirtualDesktop.autoStart"

    /// Whether Zoom/Teams starting switches it on (`VirtualDesktopAutoSwitch`). On by
    /// default, as it has been since 2026-10-05; a checkbox since 2026-10-15, when its
    /// cost made Victor want it only on purpose. The last meeting app quitting still
    /// switches it off either way.
    static var autoStart: Bool {
        get { UserDefaults.standard.object(forKey: autoStartKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoStartKey) }
    }
}

/// Turns 🪞 Virtual Desktop on when Zoom or Teams starts and off when the last of
/// them quits — edge-triggered, so the menu tick overrides it until the next edge.
final class VirtualDesktopAutoSwitch {
    static let meetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2"]

    static func isMeetingApp(_ bundleID: String?) -> Bool {
        bundleID.map(meetingApps.contains) ?? false
    }

    /// Called on the main queue with the new state, and once at `start()`.
    var onChange: ((Bool) -> Void)?
    private var running = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard Self.isMeetingApp(app?.bundleIdentifier) else { return }
                self?.evaluate(force: false)
            })
        }
        evaluate(force: true)
    }

    private func evaluate(force: Bool) {
        let now = NSWorkspace.shared.runningApplications.contains {
            Self.isMeetingApp($0.bundleIdentifier) && !$0.isTerminated
        }
        guard force || now != running else { return }
        running = now
        overlayInfo("🪞 VirtualDesktop: meeting app \(now ? "running" : "gone") → \(now ? "on" : "off")")
        onChange?(now)
    }
}

/// Which corner the presenter sits in, and when Victor is offered to move it.
/// Pure, so the timing is tested without a camera.
///
/// - The pointer resting **on the shadow itself** (not merely inside its rectangle)
///   for **3 s** raises a ← button on the shadow (`offering`); it goes away as soon
///   as the pointer leaves the shadow. Nothing moves on its own: Victor clicks it
///   (`chooseLeft`). An automatic move after 4 s (the first cut) jumped while he
///   was merely reading under his face.
/// - Once left, the pointer **away from the bottom-right rectangle for 3 s**
///   brings it home.
struct VirtualDesktopCornerPolicy {
    enum Corner: Equatable { case right, left }

    static let offerAfter: TimeInterval = 3
    /// 15 s, not 3: the face kept coming back while Victor was still working in that
    /// corner, between two glances elsewhere.
    static let returnAfter: TimeInterval = 15

    private(set) var corner: Corner = .right
    private(set) var offering = false
    private var restingSince: TimeInterval?
    private var awaySince: TimeInterval?

    /// `onShadow`: the pointer is over the silhouette's opaque pixels (or the button).
    /// `inHome`: the pointer is inside the bottom-right rectangle the clip occupies.
    mutating func update(onShadow: Bool, inHome: Bool, now: TimeInterval) {
        switch corner {
        case .right:
            awaySince = nil
            guard onShadow else { restingSince = nil; offering = false; return }
            let since = restingSince ?? now
            restingSince = since
            if now - since >= Self.offerAfter { offering = true }
        case .left:
            restingSince = nil
            offering = false
            guard !inHome else { awaySince = nil; return }
            let since = awaySince ?? now
            awaySince = since
            if now - since >= Self.returnAfter { corner = .right; awaySince = nil }
        }
    }

    /// The ← button was clicked.
    mutating func chooseLeft() {
        guard corner == .right else { return }
        corner = .left
        offering = false
        restingSince = nil
        awaySince = nil
    }
}

/// Where 🪞's invisible screen sits in the arrangement: **last on the right**, past the
/// rightmost physical screen, top edges aligned — whichever side the ASUS is on. macOS
/// drops a new screen wherever it likes (it landed in the ASUS's place, 2026-10-09), and
/// `DisplayArrangementManager` never moves it (it filters it out), so the pointer and
/// windows could wander onto a screen nobody looks at between the two real ones.
enum VirtualDesktopPlacement {
    /// `nil` when `virtual` is already there.
    static func origin(virtual: CGRect, physical: [CGRect]) -> CGPoint? {
        guard let last = physical.max(by: { $0.maxX < $1.maxX }) else { return nil }
        let target = CGPoint(x: last.maxX, y: last.minY)
        return virtual.origin == target ? nil : target
    }
}

/// 🪞 Virtual Desktop — Victor cut out of his background, over the desktop, on an
/// **invisible screen** that Teams or Zoom shares like any other.
///
/// Zoom's own presenter layouts vanished in 7.1.9 and Teams never had them; a
/// virtual camera needs a signed system extension. A *virtual display* needs
/// neither: the private `CGVirtualDisplay` (what DeskPad and BetterDisplay use)
/// gives a screen nobody looks at, and this fills it with
///
/// - the **Retina, live**, through ScreenCaptureKit — every window on it, including
///   🔎 `ShareZoom`'s magnified picture, minus the silhouette below;
/// - the **presenter**, segmented by Vision and keyed on the GPU, the whole camera
///   frame (16:9), 35 % of the screen high, bottom-right, mirrored.
///
/// On the Retina itself the presenter shows only as a **20 % black silhouette**, so
/// Victor sees where his face covers the slides without watching himself. It sits
/// above `ShareZoom` and is excluded from both captures. Pointer resting on it 3 s ⇒
/// a ← button on the head, visible only to Victor, moves the face bottom-left
/// (`VirtualDesktopCornerPolicy`).
///
/// **Cost** (measured 2026-10-05, Zoom closed, two on/off alternations):
/// WindowServer +~3 % (45–48 → 48–49 %); the segmentation itself ~27 % of one core
/// at 30 fps `.balanced`, ~150 MB.
///
/// The frames never touch the CPU: the desktop's IOSurface goes straight into a
/// layer, and the keyed face is rendered by Core Image into a pooled IOSurface that
/// both the face layer and the silhouette's mask display.
final class VirtualDesktop: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// `CGDisplayVendorNumber` of our screen, so `DisplayArrangementManager` can
    /// tell it from a venue projector.
    static let vendorID: UInt32 = 0xF00D

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    private static let fps: Int32 = 30

    /// What `/test/virtual-desktop` can change live, to measure the cost of each part
    /// without a restart (a restart recreates the screen and drops a call's share).
    /// Read on the camera queue under `tuneLock`.
    ///
    /// The defaults are the measured ones (2026-10-15, `docs/displays-projector.md`):
    /// `.balanced` takes 33 ms a face and never held 30 fps (~24), so 24 is asked for —
    /// Victor's pick after a 60/30/15/10 side-by-side ("prefer thirty, or twenty-four";
    /// 15 was visibly choppy) — and the desktop is mirrored at 30.
    /// `.fast` (13 ms, 19 %) was tried and **rejected**: even with its mask blurred it
    /// keyed the microphone in as "person" and let a patch of background through.
    struct Tune {
        var faceFPS: Double = 24
        var quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
        var cameraWidth = 1280
        var silhouette = true
        var ciFormat8 = false
        /// Frames per second of the Retina capture shown on the screen.
        var deskFPS: Int32 = 30
        /// Gaussian blur radius (camera pixels) on the upscaled mask; 0 = none.
        var smooth: Double = 0
        /// Film the Retina minus the silhouette and its ← (true), or the whole display.
        var exclude = true
        /// Width of the inner glow in face pixels (Gaussian σ); 0 = none.
        var glowSigma: Double = 5
        /// The glow's opacity on screen (white over the slide), now that the 20 % is
        /// the shadow's own and no longer the whole panel's.
        var glowAlpha: Double = 0.4
        var maskSize = CGSize.zero
    }
    private let tuneLock = NSLock()
    private var tune = Tune()
    private var output: AVCaptureVideoDataOutput?
    /// Per-face timings since the last report (camera queue, under `tuneLock`).
    private var statFaces = 0, statSegMs = 0.0, statRenderMs = 0.0, statSince = CFAbsoluteTimeGetCurrent()
    // The **whole camera frame**, uncropped, 16:9 like the Elgato's 720p output, and
    // 35 % of the screen height — 10 % lower than the 4:3 cut before it (a third of
    // the width, 4:3, which itself replaced a quarter-wide portrait 3:4). Victor,
    // 2026-10-05: "o vreau integrală, exact cum o văd pe cameră".
    private static let faceHeightRatio: CGFloat = 0.35
    private static let faceAspect: CGFloat = 16.0 / 9.0
    /// The corner-to-corner slide. Opacity is gone after the first 12 % of the way and
    /// back only over the last 12 %, so the face seems to vanish, cross unseen and
    /// arrive (Victor, 2026-10-05).
    private static let slide: TimeInterval = 0.8
    private static let slideFade: Double = 0.12

    /// Fired when the silhouette's window appears or goes, so `ShareZoom` stops
    /// (or resumes) filming it.
    var onExclusionsChanged: (() -> Void)?
    /// The silhouette's window, for `ShareZoom`'s filter. Empty while off.
    private(set) var excludedWindowIDs: [CGWindowID] = []

    var isRunning: Bool { display != nil }

    private var display: CGVirtualDisplay?
    private var screenWindow: NSWindow?
    private var silhouettePanel: NSPanel?
    /// The ← offered on the shadow (`VirtualDesktopCornerPolicy.offering`). Always on
    /// screen at alpha 0 while hidden, so both captures can exclude it by id.
    private var buttonPanel: NSPanel?
    /// The keyed face last shown (main thread): its alpha is the shadow, read for the
    /// pointer test and to find the head.
    private var shownFace: CVPixelBuffer?
    /// Keeps the glow's buffer out of the pool while it is on screen.
    private var shownGlow: CVPixelBuffer?
    private let desktopLayer = CALayer()
    private let faceLayer = CALayer()
    private let silhouetteMask = CALayer()
    /// The silhouette's contour, glowing **inward** only (Victor, 2026-10-15: on a
    /// black slide a 20 % black shadow is invisible; "no halo around my own head").
    /// White, strongest just inside the edge, gone deep inside and outside — rendered
    /// with the face (`glowSigma`), shown as a sublayer of the shadow so it slides too.
    private let glowLayer = CALayer()
    /// The 20 % shadow, inside a panel spanning the Retina's bottom strip so it can
    /// slide corner to corner like the face does.
    private let shadowLayer = CALayer()
    private var retinaFrame = CGRect.zero
    private var faceSize = CGSize.zero

    private var session: AVCaptureSession?
    private var stream: SCStream?
    /// What `startDesktopCapture` was last called with, so a dead stream can be reborn.
    private var captureSource: (display: CGDirectDisplayID, width: Int, height: Int)?
    /// Streams that died since the last complete frame (main thread) — the backoff.
    private var captureFailures = 0
    private let screenQueue = DispatchQueue(label: "VirtualDesktop.screen", qos: .userInteractive)
    /// Screen-queue only.
    private lazy var deskEcho = EchoGate(queue: screenQueue) { [weak self] surface in self?.presentDesk(surface) }
    private let cameraQueue = DispatchQueue(label: "VirtualDesktop.camera", qos: .userInteractive)
    private lazy var ciContext = Self.makeContext(format8: false)

    private static func makeContext(format8: Bool) -> CIContext {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if format8 { options[.workingFormat] = CIFormat.RGBA8 }
        return CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: options)
    }
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var facePool: CVPixelBufferPool?
    /// Camera-queue copy of `faceSize`.
    private var renderSize = CGSize.zero
    private var lastFace = CMTime.zero

    private var corners = VirtualDesktopCornerPolicy()
    private var hoverTimer: Timer?
    private var screensObserver: NSObjectProtocol?
    private var parkDebounce: DispatchWorkItem?

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard display == nil else { return }
        guard let retina = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
            overlayError("🪞 VirtualDesktop: no built-in display"); return
        }
        retinaFrame = retina.frame
        let width = Int(retina.frame.width), height = Int(retina.frame.height)
        guard let display = makeDisplay(width: width, height: height) else { return }
        self.display = display
        let faceHeight = (CGFloat(height) * Self.faceHeightRatio).rounded()
        faceSize = CGSize(width: (faceHeight * Self.faceAspect).rounded(), height: faceHeight)
        renderSize = faceSize
        corners = VirtualDesktopCornerPolicy()
        overlayInfo("🪞 VirtualDesktop: screen \(display.displayID) \(width)x\(height), presenter \(Int(faceSize.width))x\(Int(faceSize.height))")

        waitForScreen(display.displayID) { [weak self] screen in
            guard let self, self.display === display else { return }
            self.parkLast()
            self.screensObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.scheduleParkLast() }
            self.buildScreenWindow(on: screen)
            self.buildSilhouette()
            self.startCamera()
            self.captureSource = (retina.displayID, width, height)
            self.captureFailures = 0
            self.startDesktopCapture(source: retina.displayID, width: width, height: height)
            self.hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkPointer() }
        }
    }

    private func stop() {
        guard display != nil else { return }
        hoverTimer?.invalidate(); hoverTimer = nil
        screensObserver.map(NotificationCenter.default.removeObserver); screensObserver = nil
        parkDebounce?.cancel(); parkDebounce = nil
        stream?.stopCapture { _ in }
        stream = nil
        captureSource = nil
        let session = self.session
        self.session = nil
        cameraQueue.async { session?.stopRunning() }
        screenWindow?.orderOut(nil); screenWindow = nil
        silhouettePanel?.orderOut(nil); silhouettePanel = nil
        buttonPanel?.orderOut(nil); buttonPanel = nil
        shownFace = nil
        excludedWindowIDs = []
        onExclusionsChanged?()
        facePool = nil
        display = nil  // the screen disappears with the object
        overlayInfo("🪞 VirtualDesktop: off")
    }

    private func makeDisplay(width: Int, height: Int) -> CGVirtualDisplay? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "🪞 Virtual Desktop"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(width: 340, height: 220)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 1
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            overlayError("🪞 VirtualDesktop: CGVirtualDisplay refused"); return nil
        }
        let settings = CGVirtualDisplaySettings()
        // 1x: Teams/Zoom downscale a Retina share anyway, and half the pixels is half
        // of everything after this point.
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: Double(Self.fps))]
        guard display.apply(settings) else { overlayError("🪞 VirtualDesktop: applySettings failed"); return nil }
        return display
    }

    /// After any rearrangement, once it has settled: `DisplayArrangementManager` waits
    /// 1.2 s, then places the origins 0.6 s later and checks them 1.5 s after that.
    private func scheduleParkLast() {
        parkDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.parkLast() }
        parkDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Moves only this screen; the physical ones are `DisplayArrangementManager`'s.
    private func parkLast() {
        guard let id = display?.displayID else { return }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let physical = physicalDisplayIDs(ids.prefix(Int(count))).map(CGDisplayBounds)
        guard let origin = VirtualDesktopPlacement.origin(virtual: CGDisplayBounds(id), physical: physical) else { return }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return }
        CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        overlayInfo("🪞 VirtualDesktop: screen parked last at \(Int(origin.x)),\(Int(origin.y)) (\(result == .success ? "ok" : "failed \(result.rawValue)"))")
    }

    private func waitForScreen(_ id: CGDirectDisplayID, attempt: Int = 0, then: @escaping (NSScreen) -> Void) {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) { return then(screen) }
        guard attempt < 50 else { overlayError("🪞 VirtualDesktop: screen \(id) never appeared"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForScreen(id, attempt: attempt + 1, then: then)
        }
    }

    // MARK: - Windows

    private static let noAnimation: [String: CAAction] = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]

    private func buildScreenWindow(on screen: NSScreen) {
        // contentRect is relative to `screen`: passing screen.frame put the first
        // prototype's window on the Retina.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .black

        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        window.contentView?.layer = root
        window.contentView?.wantsLayer = true

        desktopLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        desktopLayer.contentsGravity = .resizeAspect
        desktopLayer.actions = Self.noAnimation
        root.addSublayer(desktopLayer)

        faceLayer.frame = faceFrame(.right, in: CGRect(origin: .zero, size: screen.frame.size))
        faceLayer.contentsGravity = .resizeAspect
        faceLayer.actions = Self.noAnimation
        root.addSublayer(faceLayer)

        window.orderFrontRegardless()
        screenWindow = window
    }

    /// The presenter's 20 % shadow on the Retina — what Victor sees instead of himself.
    private func buildSilhouette() {
        let strip = CGRect(x: retinaFrame.minX, y: retinaFrame.minY, width: retinaFrame.width, height: faceSize.height)
        let panel = NSPanel(contentRect: strip,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above 🔎 ShareZoom (.screenSaver): the shadow marks where the face is on the
        // *shared* picture, which does not zoom.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: strip.size))
        view.wantsLayer = true
        let shadow = shadowLayer
        shadow.frame = faceFrame(.right, in: view.bounds)
        shadow.actions = Self.noAnimation
        // 20 %: enough to know where the face is, faint enough to read through (was 50 %).
        // In the colour, not the panel's alpha, so the glow above it can be brighter;
        // the slide still animates this layer's opacity 1→0→1.
        shadow.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        // The keyed face's alpha *is* the silhouette: no second render.
        silhouetteMask.frame = shadow.bounds
        silhouetteMask.contentsGravity = .resizeAspect
        silhouetteMask.actions = Self.noAnimation
        shadow.mask = silhouetteMask
        glowLayer.frame = shadow.bounds
        glowLayer.contentsGravity = .resizeAspect
        glowLayer.actions = Self.noAnimation
        glowLayer.opacity = Float(tune.glowAlpha)
        shadow.addSublayer(glowLayer)
        view.layer?.addSublayer(shadow)
        panel.contentView = view
        panel.orderFrontRegardless()
        silhouettePanel = panel

        let button = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        button.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        button.isOpaque = false
        button.backgroundColor = .clear
        button.hasShadow = false
        button.hidesOnDeactivate = false
        button.isReleasedWhenClosed = false
        button.collectionBehavior = panel.collectionBehavior
        button.contentView = ArrowButtonView(frame: NSRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize)) { [weak self] in
            self?.leftClicked()
        }
        button.alphaValue = 0
        button.ignoresMouseEvents = true
        button.setFrameOrigin(NSPoint(x: shadowFrame.midX, y: shadowFrame.midY))
        button.orderFrontRegardless()
        buttonPanel = button

        excludedWindowIDs = [CGWindowID(panel.windowNumber), CGWindowID(button.windowNumber)]
        onExclusionsChanged?()
    }

    /// The shadow's rectangle in global points (its final position, mid-slide too).
    private var shadowFrame: CGRect {
        guard let panel = silhouettePanel else { return .zero }
        return shadowLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    private func faceFrame(_ corner: VirtualDesktopCornerPolicy.Corner, in screen: CGRect) -> CGRect {
        let x = corner == .right ? screen.maxX - faceSize.width : screen.minX
        return CGRect(x: x, y: screen.minY, width: faceSize.width, height: faceSize.height)
    }

    // MARK: - Pointer → corner

    private static let buttonSize: CGFloat = 44

    private func checkPointer() {
        guard silhouettePanel != nil else { return }
        let mouse = NSEvent.mouseLocation
        let onButton = (buttonPanel.map { $0.alphaValue > 0 && $0.frame.contains(mouse) }) ?? false
        let onShadow = onButton || shadowAlpha(at: mouse, in: shadowFrame) > 0.5
        let inHome = faceFrame(.right, in: retinaFrame).contains(mouse)
        let wasOffering = corners.offering
        let before = corners.corner
        corners.update(onShadow: onShadow, inHome: inHome, now: CFAbsoluteTimeGetCurrent())
        if corners.offering != wasOffering { showButton(corners.offering) }
        if corners.corner != before { move(to: corners.corner) }
    }

    private func leftClicked() {
        corners.chooseLeft()
        showButton(false)
        move(to: corners.corner)
    }

    private func showButton(_ show: Bool) {
        guard let button = buttonPanel else { return }
        if show {
            let frame = shadowFrame
            let local = buttonCentre(in: frame.size)
            button.setFrameOrigin(NSPoint(x: frame.minX + local.x - Self.buttonSize / 2,
                                          y: frame.minY + local.y - Self.buttonSize / 2))
        }
        button.ignoresMouseEvents = !show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = show ? 1 : 0
        }
    }

    /// Alpha of the shadow under a global point, 0…1; 0 outside the panel.
    private func shadowAlpha(at point: NSPoint, in frame: CGRect) -> CGFloat {
        guard frame.contains(point), let face = shownFace else { return 0 }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return Self.alpha(of: face, x: local.x * CGFloat(CVPixelBufferGetWidth(face)) / frame.width,
                          row: (frame.height - local.y) * CGFloat(CVPixelBufferGetHeight(face)) / frame.height)
    }

    /// Where the ← goes, in panel points (origin bottom-left): on the head when the
    /// whole button fits on the shadow there, otherwise the clip's centre.
    private func buttonCentre(in size: CGSize) -> CGPoint {
        let fallback = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let face = shownFace else { return fallback }
        let width = CVPixelBufferGetWidth(face), height = CVPixelBufferGetHeight(face)
        // Top of the head: the first row with a few opaque pixels.
        var top: Int?
        for row in stride(from: 0, to: height, by: 2) {
            var opaque = 0
            for x in stride(from: 0, to: width, by: 2) where Self.alpha(of: face, x: CGFloat(x), row: CGFloat(row)) > 0.5 {
                opaque += 1
            }
            if opaque >= 4 { top = row; break }
        }
        guard let top else { return fallback }
        // The head's centre column, over the band just below its top.
        var xs: [Int] = []
        for row in stride(from: top, to: min(height, top + height / 8), by: 2) {
            for x in stride(from: 0, to: width, by: 2) where Self.alpha(of: face, x: CGFloat(x), row: CGFloat(row)) > 0.5 {
                xs.append(x)
            }
        }
        guard !xs.isEmpty else { return fallback }
        let cx = CGFloat(xs.reduce(0, +)) / CGFloat(xs.count)
        let cRow = CGFloat(top) + CGFloat(height) * 0.18
        let r = Self.buttonSize / 2 * CGFloat(width) / size.width
        let fits = [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r)].allSatisfy {
            Self.alpha(of: face, x: cx + $0.0, row: cRow + $0.1) > 0.5
        }
        guard fits else { return fallback }
        return CGPoint(x: cx * size.width / CGFloat(width), y: size.height - cRow * size.height / CGFloat(height))
    }

    /// Alpha of one BGRA pixel, 0…1 (0 out of bounds).
    private static func alpha(of buffer: CVPixelBuffer, x: CGFloat, row: CGFloat) -> CGFloat {
        let ix = Int(x), iy = Int(row)
        guard ix >= 0, iy >= 0, ix < CVPixelBufferGetWidth(buffer), iy < CVPixelBufferGetHeight(buffer) else { return 0 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let byte = base.load(fromByteOffset: iy * CVPixelBufferGetBytesPerRow(buffer) + ix * 4 + 3, as: UInt8.self)
        return CGFloat(byte) / 255
    }

    private func move(to corner: VirtualDesktopCornerPolicy.Corner) {
        guard let screen = screenWindow, let panel = silhouettePanel else { return }
        Self.slide(faceLayer, to: faceFrame(corner, in: CGRect(origin: .zero, size: screen.frame.size)))
        Self.slide(shadowLayer, to: faceFrame(corner, in: CGRect(origin: .zero, size: panel.frame.size)))
        overlayInfo("🪞 VirtualDesktop: presenter → \(corner)")
    }

    /// Glide `layer` to `frame`, invisible for all but the first and last 12 % of the way.
    private static func slide(_ layer: CALayer, to frame: CGRect) {
        let from = layer.presentation()?.position ?? layer.position
        let to = CGPoint(x: frame.midX, y: frame.midY)
        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: from)
        travel.toValue = NSValue(point: to)
        // Linear, so 12 % of the time is 12 % of the way.
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0, 0, 1]
        fade.keyTimes = [0, NSNumber(value: slideFade), NSNumber(value: 1 - slideFade), 1]
        let group = CAAnimationGroup()
        group.animations = [travel, fade]
        group.duration = Self.slide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.opacity = 1
        CATransaction.commit()
        layer.add(group, forKey: "slide")
    }

    // MARK: - Camera → Vision mask → keyed, mirrored IOSurface

    private func startCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else { overlayError("🪞 VirtualDesktop: camera access denied"); return }
            self.cameraQueue.async { self.configureCamera() }
        }
    }

    private func configureCamera() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external, .builtInWideAngleCamera] } else { types = [.externalUnknown, .builtInWideAngleCamera] }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        // The Elgato is the camera on the tripod; the FaceTime one looks up from the lid.
        guard let device = devices.first(where: { $0.localizedName.contains("Facecam") }) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            overlayError("🪞 VirtualDesktop: no camera"); return
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Scaled by the output, not the device: Zoom/Teams keep the camera's full format.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720]
        output.setSampleBufferDelegate(self, queue: cameraQueue)
        self.output = output

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        // Re-pin the format the camera already runs in, so a call's feed is untouched.
        if (try? device.lockForConfiguration()) != nil {
            device.activeFormat = device.activeFormat
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async {
            guard self.display != nil else { session.stopRunning(); return }
            self.session = session
        }
        overlayInfo("🪞 VirtualDesktop: camera \(device.localizedName)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool { renderFace(sampleBuffer) }
    }

    private func renderFace(_ sampleBuffer: CMSampleBuffer) {
        tuneLock.lock(); let tune = self.tune; tuneLock.unlock()
        // The Elgato runs at 60 fps; segmenting every frame would double the cost for nothing.
        let now = sampleBuffer.presentationTimeStamp
        guard CMTimeGetSeconds(now - lastFace) >= 0.95 / tune.faceFPS else { return }
        lastFace = now
        let size = renderSize
        guard let camera = sampleBuffer.imageBuffer, size != .zero else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        if segmentation.qualityLevel != tune.quality { segmentation.qualityLevel = tune.quality }
        let handler = VNImageRequestHandler(cvPixelBuffer: camera, options: [:])
        guard (try? handler.perform([segmentation])) != nil,
              let mask = segmentation.results?.first?.pixelBuffer else { return }
        let t1 = CFAbsoluteTimeGetCurrent()

        // The whole frame (the aspect matches the camera's, so the crop is a no-op),
        // mirrored, scaled to the layer.
        let image = CIImage(cvPixelBuffer: camera)
        let full = image.extent
        let cropWidth = min(full.width, full.height * Self.faceAspect)
        let crop = CGRect(x: full.midX - cropWidth / 2, y: 0, width: cropWidth, height: full.height)
        let scale = size.height / full.height
        let place = CGAffineTransform(translationX: -crop.minX, y: 0)
            .concatenating(CGAffineTransform(scaleX: -scale, y: scale))
            .concatenating(CGAffineTransform(translationX: size.width, y: 0))

        var maskImage = CIImage(cvPixelBuffer: mask)
        let maskExtent = maskImage.extent.size
        if tune.smooth > 0 { maskImage = maskImage.samplingLinear() }
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: full.width / maskImage.extent.width,
                                                                y: full.height / maskImage.extent.height))
        if tune.smooth > 0 {
            maskImage = maskImage.clampedToExtent()
                .applyingGaussianBlur(sigma: tune.smooth)
                .cropped(to: full)
        }
        let keyed = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: maskImage,
        ]).cropped(to: crop).transformed(by: place)

        guard let out = nextFaceBuffer(size) else { return }
        let bounds = CGRect(origin: .zero, size: size)
        ciContext.render(keyed, to: out, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Inner glow: white where the shape is, minus a blurred copy of it — high
        // just inside the edge, zero deep inside (blur ≈ 1) and outside (no shape).
        var glow: CVPixelBuffer?
        if tune.silhouette, tune.glowSigma > 0, let buffer = nextFaceBuffer(size) {
            let white = CIImage(color: .white).cropped(to: bounds)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: keyed,
                ])
            // Clamped left, right and bottom (the frame's edge there is not the body's),
            // transparent above the top: a head cut by the frame glows along the cut too.
            let pad = tune.glowSigma * 4
            let open = CGRect(x: bounds.minX - pad, y: bounds.minY - pad,
                              width: bounds.width + 2 * pad, height: bounds.height + pad)
            let blurred = white.clampedToExtent().cropped(to: open)
                .applyingGaussianBlur(sigma: tune.glowSigma).cropped(to: bounds)
            let edge = white.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: blurred])
            ciContext.render(edge, to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            glow = buffer
        }
        let glowSurface = glow.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
        let t2 = CFAbsoluteTimeGetCurrent()
        tuneLock.lock()
        statFaces += 1; statSegMs += (t1 - t0) * 1000; statRenderMs += (t2 - t1) * 1000
        self.tune.maskSize = maskExtent
        tuneLock.unlock()
        guard let surface = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.display != nil else { return }
            self.faceLayer.contents = surface
            if tune.silhouette {
                self.silhouetteMask.contents = surface
                self.glowLayer.contents = glowSurface
                self.glowLayer.opacity = Float(tune.glowAlpha)
                self.shownGlow = glow
            }
            self.shownFace = out
        }
    }

    private func nextFaceBuffer(_ size: CGSize) -> CVPixelBuffer? {
        if facePool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attributes as CFDictionary, &facePool)
        }
        guard let pool = facePool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    // MARK: - /test/virtual-desktop

    /// Apply whichever knobs are given, then report. Main thread.
    func testTune(_ q: [String: String]) -> String {
        if let on = q["on"] { setEnabled(on == "1") }
        tuneLock.lock()
        var t = tune
        if let v = q["fps"].flatMap(Double.init), v > 0 { t.faceFPS = v }
        switch q["quality"] {
        case "fast": t.quality = .fast
        case "balanced": t.quality = .balanced
        case "accurate": t.quality = .accurate
        default: break
        }
        if let v = q["silhouette"] { t.silhouette = v == "1" }
        if let v = q["ci"] { t.ciFormat8 = v == "8" }
        if let v = q["cam"].flatMap(Int.init), v >= 320 { t.cameraWidth = v }
        if let v = q["desk"].flatMap(Int32.init), v > 0 { t.deskFPS = v }
        if let v = q["smooth"].flatMap(Double.init), v >= 0 { t.smooth = v }
        if let v = q["exclude"] { t.exclude = v == "1" }
        if let v = q["glow"].flatMap(Double.init), v >= 0 { t.glowSigma = v }
        if let v = q["glowAlpha"].flatMap(Double.init), (0...1).contains(v) { t.glowAlpha = v }
        let excludeChanged = t.exclude != tune.exclude
        let deskChanged = t.deskFPS != tune.deskFPS
        let formatChanged = t.ciFormat8 != tune.ciFormat8
        let camChanged = t.cameraWidth != tune.cameraWidth
        tune = t
        let secs = CFAbsoluteTimeGetCurrent() - statSince
        let faces = statFaces
        let stats = faces == 0 ? "\"facesPerSec\":0" : String(format: "\"facesPerSec\":%.1f,\"segMs\":%.1f,\"renderMs\":%.1f",
                                                                Double(faces) / secs, statSegMs / Double(faces), statRenderMs / Double(faces))
        statFaces = 0; statSegMs = 0; statRenderMs = 0; statSince = CFAbsoluteTimeGetCurrent()
        tuneLock.unlock()
        if formatChanged { cameraQueue.async { self.ciContext = Self.makeContext(format8: t.ciFormat8) } }
        if camChanged, let output {
            let w = t.cameraWidth, h = t.cameraWidth * 9 / 16
            cameraQueue.async {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h]
            }
        }
        if deskChanged || excludeChanged, let source = captureSource {
            stream?.stopCapture { _ in }
            stream = nil
            startDesktopCapture(source: source.display, width: source.width, height: source.height)
        }
        silhouettePanel?.alphaValue = t.silhouette ? 1 : 0
        if t.silhouette { silhouettePanel?.orderFrontRegardless() } else { silhouettePanel?.orderOut(nil) }
        let quality = t.quality == .fast ? "fast" : t.quality == .accurate ? "accurate" : "balanced"
        return "{\"on\":\(isRunning),\"fps\":\(t.faceFPS),\"quality\":\"\(quality)\",\"cam\":\(t.cameraWidth),\"silhouette\":\(t.silhouette),\"ci\":\(t.ciFormat8 ? 8 : 16),\"desk\":\(t.deskFPS),\"smooth\":\(t.smooth),\"exclude\":\(t.exclude),\"glow\":\(t.glowSigma),\"glowAlpha\":\(t.glowAlpha),\"deskFrames\":\(screenQueue.sync { deskEcho.json }),\"mask\":\"\(Int(t.maskSize.width))x\(Int(t.maskSize.height))\",\(stats)}"
    }

    // MARK: - Retina → IOSurface straight into a layer

    private func startDesktopCapture(source: CGDirectDisplayID, width: Int, height: Int, attempt: Int = 0) {
        // onScreenWindowsOnly: false — the ← button sits at alpha 0 until offered.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.display != nil else { return }
                let excluded = Set(self.excludedWindowIDs)
                // The display list and the silhouette's window lag right after the
                // virtual screen appears.
                guard let content,
                      let retina = content.displays.first(where: { $0.displayID == source }),
                      excluded.isSubset(of: Set(content.windows.map(\.windowID))) || attempt >= 10 else {
                    if attempt < 10 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.startDesktopCapture(source: source, width: width, height: height, attempt: attempt + 1)
                        }
                    } else {
                        overlayError("🪞 VirtualDesktop: Retina not shareable: \(error?.localizedDescription ?? "-")")
                    }
                    return
                }
                // Exclude the silhouette and its ← only, not the whole app: 🔎 ShareZoom, the
                // banners and the break overlay belong in the picture.
                self.tuneLock.lock(); let exclude = self.tune.exclude; self.tuneLock.unlock()
                let silhouette = exclude ? content.windows.filter { excluded.contains($0.windowID) } : []
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                self.tuneLock.lock(); let deskFPS = self.tune.deskFPS; self.tuneLock.unlock()
                config.minimumFrameInterval = CMTime(value: 1, timescale: deskFPS)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.queueDepth = 4
                let stream = SCStream(filter: SCContentFilter(display: retina, excludingWindows: silhouette),
                                      configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.screenQueue)
                } catch {
                    overlayError("🪞 VirtualDesktop: \(error.localizedDescription)"); return
                }
                stream.startCapture { [weak self] error in
                    if let error { self?.captureDied(stream, "capture failed: \(error.localizedDescription)") }
                }
                self.stream = stream
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        // The silhouette repainting at 15 fps damages the Retina, so the stream sends
        // a frame each time — identical, since the silhouette is excluded. Showing it
        // would recompose the 🪞 screen and hand the call a new frame for nothing.
        deskEcho.offer(pixelBuffer, surface)
    }

    private func presentDesk(_ surface: IOSurface) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream != nil else { return }
            self.desktopLayer.contents = surface
            self.captureFailures = 0
        }
    }

    /// Backoff before re-filming the Retina after the n-th death in a row: 1, 2, 4… s, at most 30.
    static func captureRestartDelay(afterFailures n: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, n - 1))))
    }

    /// The stream dies on its own — 2026-10-05 17:20, mid-training, "application
    /// connection being interrupted" (replayd) — and the invisible screen kept its
    /// last frame: the call watched a frozen Gmail while the Retina moved on. So a
    /// dead stream is always restarted, with a backoff, for as long as we are on.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureDied(stream, "stream stopped: \(error.localizedDescription)")
    }

    private func captureDied(_ stream: SCStream, _ reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.captureFailures += 1
            let delay = Self.captureRestartDelay(afterFailures: self.captureFailures)
            overlayError("🪞 VirtualDesktop: \(reason) → restart in \(Int(delay)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.display != nil, self.stream == nil,
                      let source = self.captureSource else { return }
                self.startDesktopCapture(source: source.display, width: source.width, height: source.height)
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// The ← on the shadow: a dark disc with a white arrow, clickable without
/// activating Victor Addons (the panel is non-activating, the view takes first mouse).
private final class ArrowButtonView: NSView {
    private let action: () -> Void

    init(frame: NSRect, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let arrow = NSAttributedString(string: "←", attributes: [
            .font: NSFont.systemFont(ofSize: bounds.height * 0.55, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = arrow.size()
        arrow.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
