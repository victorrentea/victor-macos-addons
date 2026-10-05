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
    static let returnAfter: TimeInterval = 3

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
/// - the **presenter**, segmented by Vision and keyed on the GPU, a third of the
///   screen wide (4:3), bottom-right, mirrored.
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
    // A third of the width, landscape 4:3 (Victor, 2026-10-05, drawing the box over a
    // capture): the first cut, a quarter wide and portrait 3:4, stood too tall.
    private static let faceWidthRatio: CGFloat = 1.0 / 3.0
    private static let faceAspect: CGFloat = 4.0 / 3.0
    private static let fade: TimeInterval = 0.3

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
    private let desktopLayer = CALayer()
    private let faceLayer = CALayer()
    private let silhouetteMask = CALayer()
    private var retinaFrame = CGRect.zero
    private var faceSize = CGSize.zero

    private var session: AVCaptureSession?
    private var stream: SCStream?
    private let screenQueue = DispatchQueue(label: "VirtualDesktop.screen", qos: .userInteractive)
    private let cameraQueue = DispatchQueue(label: "VirtualDesktop.camera", qos: .userInteractive)
    private lazy var ciContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
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
        let faceWidth = (CGFloat(width) * Self.faceWidthRatio).rounded()
        faceSize = CGSize(width: faceWidth, height: (faceWidth / Self.faceAspect).rounded())
        renderSize = faceSize
        corners = VirtualDesktopCornerPolicy()
        overlayInfo("🪞 VirtualDesktop: screen \(display.displayID) \(width)x\(height), presenter \(Int(faceWidth))x\(Int(faceSize.height))")

        waitForScreen(display.displayID) { [weak self] screen in
            guard let self, self.display === display else { return }
            self.buildScreenWindow(on: screen)
            self.buildSilhouette()
            self.startCamera()
            self.startDesktopCapture(source: retina.displayID, width: width, height: height)
            self.hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkPointer() }
        }
    }

    private func stop() {
        guard display != nil else { return }
        hoverTimer?.invalidate(); hoverTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
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
        let panel = NSPanel(contentRect: faceFrame(.right, in: retinaFrame),
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

        let view = NSView(frame: NSRect(origin: .zero, size: faceSize))
        view.wantsLayer = true
        let shadow = CALayer()
        shadow.frame = view.bounds
        shadow.backgroundColor = NSColor.black.cgColor
        // 20 %: enough to know where the face is, faint enough to read through (was 50 %).
        shadow.opacity = 0.2
        // The keyed face's alpha *is* the silhouette: no second render.
        silhouetteMask.frame = view.bounds
        silhouetteMask.contentsGravity = .resizeAspect
        silhouetteMask.actions = Self.noAnimation
        shadow.mask = silhouetteMask
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
        button.setFrameOrigin(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        button.orderFrontRegardless()
        buttonPanel = button

        excludedWindowIDs = [CGWindowID(panel.windowNumber), CGWindowID(button.windowNumber)]
        onExclusionsChanged?()
    }

    private func faceFrame(_ corner: VirtualDesktopCornerPolicy.Corner, in screen: CGRect) -> CGRect {
        let x = corner == .right ? screen.maxX - faceSize.width : screen.minX
        return CGRect(x: x, y: screen.minY, width: faceSize.width, height: faceSize.height)
    }

    // MARK: - Pointer → corner

    private static let buttonSize: CGFloat = 44

    private func checkPointer() {
        guard let panel = silhouettePanel else { return }
        let mouse = NSEvent.mouseLocation
        let onButton = (buttonPanel.map { $0.alphaValue > 0 && $0.frame.contains(mouse) }) ?? false
        let onShadow = onButton || shadowAlpha(at: mouse, in: panel.frame) > 0.5
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
        guard let button = buttonPanel, let panel = silhouettePanel else { return }
        if show {
            let local = buttonCentre(in: panel.frame.size)
            button.setFrameOrigin(NSPoint(x: panel.frame.minX + local.x - Self.buttonSize / 2,
                                          y: panel.frame.minY + local.y - Self.buttonSize / 2))
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
        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fade
            panel.animator().alphaValue = 0
            fadeFace(to: 0)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            panel.setFrame(self.faceFrame(corner, in: self.retinaFrame), display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.faceLayer.frame = self.faceFrame(corner, in: screenBounds)
            CATransaction.commit()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fade
                panel.animator().alphaValue = 1
                self.fadeFace(to: 1)
            }
        })
        overlayInfo("🪞 VirtualDesktop: presenter → \(corner)")
    }

    private func fadeFace(to opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = faceLayer.presentation()?.opacity ?? faceLayer.opacity
        fade.toValue = opacity
        fade.duration = Self.fade
        faceLayer.opacity = opacity
        faceLayer.add(fade, forKey: "fade")
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
        // The Elgato runs at 60 fps; segmenting every frame would double the cost for nothing.
        let now = sampleBuffer.presentationTimeStamp
        guard CMTimeGetSeconds(now - lastFace) >= 0.95 / Double(Self.fps) else { return }
        lastFace = now
        let size = renderSize
        guard let camera = sampleBuffer.imageBuffer, size != .zero else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: camera, options: [:])
        guard (try? handler.perform([segmentation])) != nil,
              let mask = segmentation.results?.first?.pixelBuffer else { return }

        // Centre crop to the presenter's aspect, mirrored, scaled to the layer.
        let image = CIImage(cvPixelBuffer: camera)
        let full = image.extent
        let cropWidth = min(full.width, full.height * Self.faceAspect)
        let crop = CGRect(x: full.midX - cropWidth / 2, y: 0, width: cropWidth, height: full.height)
        let scale = size.height / full.height
        let place = CGAffineTransform(translationX: -crop.minX, y: 0)
            .concatenating(CGAffineTransform(scaleX: -scale, y: scale))
            .concatenating(CGAffineTransform(translationX: size.width, y: 0))

        var maskImage = CIImage(cvPixelBuffer: mask)
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: full.width / maskImage.extent.width,
                                                                y: full.height / maskImage.extent.height))
        let keyed = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: maskImage,
        ]).cropped(to: crop).transformed(by: place)

        guard let out = nextFaceBuffer(size) else { return }
        ciContext.render(keyed, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        guard let surface = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.display != nil else { return }
            self.faceLayer.contents = surface
            self.silhouetteMask.contents = surface
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
                let silhouette = content.windows.filter { excluded.contains($0.windowID) }
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
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
                stream.startCapture { error in
                    if let error { overlayError("🪞 VirtualDesktop: capture failed: \(error.localizedDescription)") }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.desktopLayer.contents = surface
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        overlayError("🪞 VirtualDesktop: stream stopped: \(error.localizedDescription)")
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
