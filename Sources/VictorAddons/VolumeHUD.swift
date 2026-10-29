import AppKit
import CoreAudio
import CoreGraphics

/// 🔊 The pre-Tahoe volume HUD, back at the bottom centre of the screen. macOS 26 moved
/// the volume indicator to a small pill in the top-right corner, which Victor could
/// barely see (2026-10-29: *"abia îl văd în colțul sus"*).
///
/// **How: the volume keys never reach macOS.** Reverse-engineered from
/// [volumeHUD](https://github.com/dannystewart/volumeHUD) (MIT): an HID tap on
/// `NX_SYSDEFINED` (type 14) events, subtype 8 (aux control buttons), takes the
/// volume-up / volume-down / mute key-downs, **swallows** them, moves the default output's
/// volume itself and draws its own HUD. The system never sees the key, so its corner
/// pill never shows. There is no public way to hide that pill and still let the key through.
///
/// **When the output has no volume we can set** (HDMI to the room TV, some aggregates),
/// the key goes through untouched, and macOS shows its own "can't change" indicator.
///
/// Steps are 1/16, the macOS default; ⌥⇧ gives 1/64, as it always did. Changes made
/// elsewhere (the menu bar slider, a headset's buttons) show no HUD. A CoreAudio
/// listener would also catch `CoreAudioManager` ducking the output for every dictation.
///
/// Off with `defaults write ro.victorrentea.macos-addons VolumeHUDEnabled -bool NO`
/// plus a restart. Test hook: `GET /test/volume-hud?level=0.5&muted=0`.
final class VolumeHUD {

    static let enabledKey = "VolumeHUDEnabled"

    private var tapPort: CFMachPort?
    /// The last target this class set and what the device read back; some devices
    /// round 1/16 to their own hardware steps, and continuing from the read-back would
    /// get stuck on them. Touched only on the tap thread.
    private var lastSet: (device: AudioDeviceID, wanted: Float, readBack: Float)?
    private var panel: VolumeHUDPanel?
    private var hideWork: DispatchWorkItem?

    func start() {
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        guard stored ?? true else {
            overlayInfo("🔊 Volume HUD off (\(Self.enabledKey) = NO)")
            return
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << VolumeKeyPolicy.systemDefinedType),
            callback: { _, type, event, userInfo in
                let me = Unmanaged<VolumeHUD>.fromOpaque(userInfo!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            overlayError("VolumeHUD: could not create HID tap — check Accessibility")
            return
        }
        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "VolumeHUD"
        thread.start()
        overlayInfo("🔊 Volume HUD on: volume keys taken over, HUD at the bottom centre")
    }

    // MARK: - Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == VolumeKeyPolicy.systemDefinedType,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              let key = VolumeKeyPolicy.key(subtype: Int(ns.subtype.rawValue), data1: ns.data1)
        else { return Unmanaged.passUnretained(event) }

        // The key-up of a key whose key-down we swallowed: macOS does nothing with it alone.
        guard key.isDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags.union(CGEventSource.flagsState(.combinedSessionState))
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        guard let shown = apply(key.kind, fine: fine) else {
            return Unmanaged.passUnretained(event)   // let macOS deal with it
        }
        DispatchQueue.main.async { [weak self] in self?.show(level: shown.level, muted: shown.muted) }
        return nil
    }

    /// Moves the default output; nil when it has no volume we can set.
    private func apply(_ kind: VolumeKeyPolicy.Kind, fine: Bool) -> (level: Float, muted: Bool)? {
        guard let device = SystemOutputVolume.defaultOutputDevice(),
              let current = SystemOutputVolume.get(device: device) else { return nil }
        let muted = SystemOutputVolume.isMuted(device: device) ?? false

        if kind == .mute {
            // A device with no mute switch is muted by macOS at volume 0; leave that to macOS.
            guard SystemOutputVolume.setMuted(!muted, device: device) else { return nil }
            return (VolumeKeyPolicy.quantize(current, steps: 16), !muted)
        }

        let base: Float
        if let last = lastSet, last.device == device, abs(last.readBack - current) <= 0.001 {
            base = last.wanted
        } else {
            base = current
        }
        let wanted = VolumeKeyPolicy.next(from: base, up: kind == .up, fine: fine)
        guard SystemOutputVolume.set(wanted, device: device) else { lastSet = nil; return nil }
        lastSet = (device, wanted, SystemOutputVolume.get(device: device) ?? wanted)

        // macOS mutes at 0 and unmutes on the way back up; so does this.
        let shouldMute = wanted <= 0.001
        if shouldMute != muted { SystemOutputVolume.setMuted(shouldMute, device: device) }
        return (wanted, shouldMute || (muted && SystemOutputVolume.isMuted(device: device) == true))
    }

    // MARK: - Main thread

    /// Shows the HUD at `level` (0…1), restarting its 1.5 s on screen. Also the test hook.
    func show(level: Float, muted: Bool) {
        let screen = Self.screenUnderPointer()
        let hud = panel ?? VolumeHUDPanel()
        panel = hud
        hud.update(level: level, muted: muted)
        hud.place(on: screen)
        hideWork?.cancel()
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        let work = DispatchWorkItem { [weak hud] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                hud?.animator().alphaValue = 0
            }, completionHandler: { hud?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func stateJSON() -> String {
        let level = SystemOutputVolume.get().map { String(format: "%.4f", $0) } ?? "null"
        let muted = SystemOutputVolume.isMuted().map { $0 ? "true" : "false" } ?? "null"
        let visible = (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0
        return "{\"tap\":\(tapPort != nil),\"level\":\(level),\"muted\":\(muted),\"visible\":\(visible),"
            + "\"frame\":\"\(panel.map { NSStringFromRect($0.frame) } ?? "")\"}"
    }

    private static func screenUnderPointer() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.physical.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main ?? AppDelegate.findRetinaScreen()
    }
}

/// The decisions, without a tap or a device.
enum VolumeKeyPolicy {

    /// `NX_SYSDEFINED`: media keys come as this event type, not as keyDown.
    static let systemDefinedType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    static let auxControlButtons = 8

    enum Kind { case up, down, mute }

    /// data1 = key code in the high 16 bits, state in bits 8–15 (0x0A down, 0x0B up).
    static func key(subtype: Int, data1: Int) -> (kind: Kind, isDown: Bool)? {
        guard subtype == auxControlButtons else { return nil }
        let kind: Kind
        switch (data1 & 0xFFFF_0000) >> 16 {
        case 0: kind = .up        // NX_KEYTYPE_SOUND_UP
        case 1: kind = .down      // NX_KEYTYPE_SOUND_DOWN
        case 7: kind = .mute      // NX_KEYTYPE_MUTE
        default: return nil
        }
        switch (data1 & 0xFF00) >> 8 {
        case 0x0A: return (kind, true)
        case 0x0B: return (kind, false)
        default: return nil
        }
    }

    static func quantize(_ v: Float, steps: Float) -> Float {
        min(1, max(0, (v * steps).rounded() / steps))
    }

    /// One step from `level`, snapped to the grid, so a volume set elsewhere to 0.53
    /// lands on 9/16 rather than drifting as 0.5925.
    static func next(from level: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        return quantize(level + (up ? 1 : -1) / steps, steps: steps)
    }

    /// The classic speaker glyph for a level.
    static func symbol(level: Float, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.08 { return "speaker.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// The 200 × 200 rounded square of macOS 10.x–15: speaker glyph and 16 blocks,
/// on dark frosted glass, 140 pt above the bottom edge.
final class VolumeHUDPanel: NSPanel {

    private static let side: CGFloat = 200
    private let icon = NSImageView()
    private let blocks = VolumeBlocksView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above a full-screen PowerPoint slide show, like the original.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]

        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        glass.material = .hudWindow
        glass.appearance = NSAppearance(named: .vibrantDark)
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        contentView = glass

        icon.frame = NSRect(x: 40, y: 72, width: 120, height: 100)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        glass.addSubview(icon)

        blocks.frame = NSRect(x: 20, y: 36, width: Self.side - 40, height: 8)
        glass.addSubview(blocks)
    }

    func update(level: Float, muted: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 80, weight: .medium)
        icon.image = NSImage(systemSymbolName: VolumeKeyPolicy.symbol(level: level, muted: muted),
                             accessibilityDescription: "volume")?.withSymbolConfiguration(config)
        blocks.level = muted ? 0 : CGFloat(level)
    }

    func place(on screen: NSScreen) {
        let f = screen.frame
        setFrameOrigin(NSPoint(x: f.midX - Self.side / 2, y: f.minY + 140))
    }
}

/// 16 blocks with 2 pt gaps; a block partly lit in quarters, for the ⌥⇧ 1/64 steps.
final class VolumeBlocksView: NSView {

    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let n = 16, gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            NSColor.white.withAlphaComponent(0.2).setFill()
            r.fill()
            let lit = min(1, max(0, level * CGFloat(n) - CGFloat(i)))
            let quarters = (lit * 4).rounded() / 4
            guard quarters > 0 else { continue }
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSRect(x: r.minX, y: r.minY, width: w * quarters, height: r.height).fill()
        }
    }
}
